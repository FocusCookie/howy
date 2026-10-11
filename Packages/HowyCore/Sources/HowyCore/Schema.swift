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

/// Version 2: `Todo` gains an optional `due` date. The live `Todo` model is this version.
/// Add a `HowySchemaV3` (and freeze a copy of `Todo` here) before changing `Todo` again.
enum HowySchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [Todo.self] }
}

enum HowyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HowySchemaV1.self, HowySchemaV2.self] }
    /// v1 → v2 adds an optional attribute: lightweight, existing todos get no due date.
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: HowySchemaV1.self, toVersion: HowySchemaV2.self)]
    }
}
