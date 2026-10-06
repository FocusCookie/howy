import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

public enum TodoStoreError: Error, Equatable, Sendable {
    /// The title was empty or whitespace only.
    case emptyTitle
    /// No todo with this id exists.
    case notFound(UUID)
    /// The App Group container could not be resolved (missing entitlement?).
    case appGroupUnavailable(String)
}

/// All reads and writes of todos. Main-actor bound because it owns a `ModelContext`.
///
/// Every successful write saves the context and then calls `didWrite`
/// (by default, for the shared store, `TodoStore.reloadWidgetTimelines`).
@MainActor
public final class TodoStore {
    /// Archived todos completed longer ago than this are purged.
    public static let archiveRetention: TimeInterval = 7 * 24 * 60 * 60
    /// File name of the SQLite store inside the App Group container.
    public static let storeFileName = "Howy.store"

    let modelContainer: ModelContainer
    public let context: ModelContext
    private let now: @Sendable () -> Date
    private let didWrite: (@MainActor () -> Void)?

    public init(
        modelContainer: ModelContainer,
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = nil
    ) {
        self.modelContainer = modelContainer
        self.context = modelContainer.mainContext
        self.now = now
        self.didWrite = didWrite
    }

    // MARK: Factories

    /// The on-disk store in the App Group container, shared by the app and the widget extension.
    public static func shared(
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = { TodoStore.reloadWidgetTimelines() }
    ) throws -> TodoStore {
        try TodoStore(modelContainer: makeContainer(url: sharedStoreURL()), now: now, didWrite: didWrite)
    }

    /// A store on a SQLite file at `url` (tests, tools).
    static func onDisk(
        url: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = nil
    ) throws -> TodoStore {
        try TodoStore(modelContainer: makeContainer(url: url), now: now, didWrite: didWrite)
    }

    /// The App Group store URL: `<group container>/Library/Application Support/Howy.store`.
    public static func sharedStoreURL() throws -> URL {
        guard let container = HowyAppGroup.containerURL else {
            throw TodoStoreError.appGroupUnavailable(HowyAppGroup.identifier)
        }
        let directory = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: storeFileName)
    }

    private static func makeContainer(url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Schema(versionedSchema: HowySchemaV1.self),
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: HowySchemaV1.self),
            migrationPlan: HowyMigrationPlan.self,
            configurations: configuration
        )
    }

    /// An in-memory store for tests and previews.
    public static func inMemory(
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = nil
    ) throws -> TodoStore {
        let schema = Schema(versionedSchema: HowySchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: HowyMigrationPlan.self, configurations: configuration)
        return TodoStore(modelContainer: container, now: now, didWrite: didWrite)
    }

    /// Asks WidgetKit to reload every Howy widget timeline.
    public static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: Writes

    @discardableResult
    public func add(title: String, note: String = "", quadrant: Quadrant) throws -> Todo {
        let title = try Self.validated(title)
        let todo = Todo(title: title, note: note, quadrant: quadrant, createdAt: now())
        context.insert(todo)
        try commit()
        return todo
    }

    /// Changes a todo. Moving it to another quadrant bumps `sortDate` so it shows on top there.
    public func update(id: UUID, title: String, note: String, quadrant: Quadrant) throws {
        let title = try Self.validated(title)
        let todo = try require(id)
        // An untouched edit is a no-op: don't write or reload widgets.
        guard todo.title != title || todo.note != note || todo.quadrant != quadrant else { return }
        todo.title = title
        todo.note = note
        if todo.quadrant != quadrant {
            todo.quadrant = quadrant
            todo.sortDate = now()
        }
        try commit()
    }

    /// Archives the todo. Completing an already archived todo keeps its original `completedAt`.
    public func complete(id: UUID) throws {
        let todo = try require(id)
        guard todo.completedAt == nil else { return } // no-op: don't write or reload widgets
        todo.completedAt = now()
        try commit()
    }

    /// Brings an archived todo back into its original quadrant, on top: `sortDate` is bumped so
    /// an undone tick doesn't vanish under "+N more". Restoring an open todo does nothing.
    public func restore(id: UUID) throws {
        let todo = try require(id)
        guard todo.completedAt != nil else { return }
        todo.completedAt = nil
        todo.sortDate = now()
        try commit()
    }

    /// Puts a quadrant's open todos in the given order (e.g. after a drag). Rewrites `sortDate`
    /// downwards from the newest one already there, so the order holds and a todo added later
    /// still lands on top. Open todos missing from `ids` keep their relative order after the
    /// listed ones; unknown ids are ignored.
    public func reorder(_ ids: [UUID], in quadrant: Quadrant) throws {
        let todos = try openTodos(in: quadrant)
        guard let newest = todos.first?.sortDate else { return }
        let byID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        var ordered = ids.compactMap { byID[$0] }
        let listed = Set(ordered.map(\.id))
        ordered += todos.filter { !listed.contains($0.id) }
        guard ordered.map(\.id) != todos.map(\.id) else { return } // unchanged: no write
        for (index, todo) in ordered.enumerated() {
            todo.sortDate = newest.addingTimeInterval(-Double(index) * 0.001)
        }
        try commit()
    }

    public func delete(id: UUID) throws {
        context.delete(try require(id))
        try commit()
    }

    /// Deletes archived todos completed more than 7 days before `now` (default: the injected clock).
    /// A todo completed exactly 7 days ago is kept. Returns the number removed.
    @discardableResult
    public func purgeArchive(now: Date? = nil) throws -> Int {
        let cutoff = (now ?? self.now()).addingTimeInterval(-Self.archiveRetention)
        let expired = try context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { todo in
            todo.completedAt.flatMap { $0 < cutoff } == true
        }))
        guard !expired.isEmpty else { return 0 }
        expired.forEach(context.delete)
        try commit()
        return expired.count
    }

    // MARK: Reads

    public func todo(id: UUID) throws -> Todo? {
        var descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Open todos in a quadrant, newest `sortDate` first.
    public func openTodos(in quadrant: Quadrant) throws -> [Todo] {
        let raw = quadrant.rawValue
        return try context.fetch(FetchDescriptor<Todo>(
            predicate: #Predicate { $0.completedAt == nil && $0.quadrantRaw == raw },
            sortBy: [SortDescriptor(\.sortDate, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]
        ))
    }

    /// All archived todos, most recently completed first.
    public func archivedTodos() throws -> [Todo] {
        try context.fetch(FetchDescriptor<Todo>(
            predicate: #Predicate { $0.completedAt != nil },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        ))
    }

    /// Open todos for every quadrant as value snapshots, newest first (input for `WidgetContentBuilder`).
    public func openSnapshots() throws -> [Quadrant: [TodoSnapshot]] {
        var result: [Quadrant: [TodoSnapshot]] = [:]
        for quadrant in Quadrant.allCases {
            result[quadrant] = try openTodos(in: quadrant).map(\.snapshot)
        }
        return result
    }

    // MARK: Helpers

    private static func validated(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TodoStoreError.emptyTitle }
        return trimmed
    }

    private func require(_ id: UUID) throws -> Todo {
        guard let todo = try todo(id: id) else { throw TodoStoreError.notFound(id) }
        return todo
    }

    private func commit() throws {
        try context.save()
        didWrite?()
    }
}
