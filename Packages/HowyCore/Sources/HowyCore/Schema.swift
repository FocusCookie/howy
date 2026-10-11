import Foundation
import SwiftData

/// Version 1 of the on-disk schema, frozen: the `Todo` model as it was before due dates. Never
/// change it; it is what lightweight migration reads old stores with.
enum HowySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Todo.self] }

    @Model
    final class Todo {
        @Attribute(.unique) var id: UUID
        var title: String
        var note: String
        var quadrantRaw: Int
        var createdAt: Date
        var sortDate: Date
        var completedAt: Date?

        init(id: UUID, title: String, note: String, quadrantRaw: Int, createdAt: Date, sortDate: Date, completedAt: Date?) {
            self.id = id
            self.title = title
            self.note = note
            self.quadrantRaw = quadrantRaw
            self.createdAt = createdAt
            self.sortDate = sortDate
            self.completedAt = completedAt
        }
    }
}

/// Version 2, frozen: `Todo` gains an optional `due` date. Never change it; it is what the
/// v2 → v3 migration reads old stores with.
enum HowySchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Todo.self] }

    @Model
    final class Todo {
        @Attribute(.unique) var id: UUID
        var title: String
        var note: String
        var quadrantRaw: Int
        var createdAt: Date
        var sortDate: Date
        var completedAt: Date?
        var due: Date?

        init(
            id: UUID, title: String, note: String, quadrant: Quadrant,
            createdAt: Date, sortDate: Date, completedAt: Date?, due: Date?
        ) {
            self.id = id
            self.title = title
            self.note = note
            self.quadrantRaw = quadrant.rawValue
            self.createdAt = createdAt
            self.sortDate = sortDate
            self.completedAt = completedAt
            self.due = due
        }
    }
}

/// Version 3, the live schema: CloudKit-ready `Todo` (no unique constraint, a default for every
/// attribute, `updatedAt`) and the append-only `TodoEvent` log.
/// Add a `HowySchemaV4` (and freeze copies of `Todo` and `TodoEvent` here) before changing
/// either model again.
enum HowySchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [Todo.self, TodoEvent.self] }
}

enum HowyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [HowySchemaV1.self, HowySchemaV2.self, HowySchemaV3.self]
    }

    static var stages: [MigrationStage] { [v1ToV2, v2ToV3] }

    /// v1 → v2 adds an optional attribute: lightweight, existing todos get no due date.
    static let v1ToV2 = MigrationStage.lightweight(fromVersion: HowySchemaV1.self, toVersion: HowySchemaV2.self)

    /// v2 → v3 drops the unique constraint, adds `updatedAt` (with a default) and the new
    /// `TodoEvent` model; the schema part is lightweight. `didMigrate` then backfills the
    /// history the store already knows: a `created` event at `createdAt` (with the quadrant)
    /// for every todo, a `completed` event at `completedAt` for every archived one, and sets
    /// `updatedAt` to `completedAt ?? sortDate`. The stage runs once, when the store's
    /// version is below v3; the backfill also does nothing if events already exist.
    static let v2ToV3 = MigrationStage.custom(
        fromVersion: HowySchemaV2.self,
        toVersion: HowySchemaV3.self,
        willMigrate: nil,
        didMigrate: { context in
            try backfillEvents(in: context)
        }
    )

    static func backfillEvents(in context: ModelContext) throws {
        guard try context.fetchCount(FetchDescriptor<TodoEvent>()) == 0 else { return }
        for todo in try context.fetch(FetchDescriptor<Todo>()) {
            context.insert(TodoEvent(todoID: todo.id, kind: .created, date: todo.createdAt, to: todo.quadrant))
            if let completedAt = todo.completedAt {
                context.insert(TodoEvent(todoID: todo.id, kind: .completed, date: completedAt))
            }
            todo.updatedAt = todo.completedAt ?? todo.sortDate
        }
        try context.save()
    }
}
