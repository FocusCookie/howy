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
/// Every successful write saves the context and then calls `didWrite` (by default, for the
/// shared store, `TodoStore.reloadWidgetTimelines` and `StoreChangeSignal.post`).
///
/// Every write that changes a todo stamps its `updatedAt` with the clock, and records what
/// happened as `TodoEvent`s in the same save (created, completed, reopened, moved, the due
/// date kinds, deleted). Title and note edits, reorders within a quadrant, and no-op writes
/// record nothing. Events are never removed.
@MainActor
public final class TodoStore {
    /// File name of the SQLite store inside the App Group container.
    public static let storeFileName = "Howy.store"

    let modelContainer: ModelContainer
    public let context: ModelContext
    /// The todos' attached files; `nil` for stores without attachments (most tests).
    public let attachments: AttachmentStore?
    private let now: @Sendable () -> Date
    private let didWrite: (@MainActor () -> Void)?

    public init(
        modelContainer: ModelContainer,
        attachments: AttachmentStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = nil
    ) {
        self.modelContainer = modelContainer
        self.attachments = attachments
        self.context = modelContainer.mainContext
        self.now = now
        self.didWrite = didWrite
    }

    // MARK: Factories

    /// The on-disk store in the App Group container, shared by the app and the widget extension.
    /// By default every write reloads the widgets and posts `StoreChangeSignal`.
    public static func shared(
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = {
            TodoStore.reloadWidgetTimelines()
            StoreChangeSignal.post()
        }
    ) throws -> TodoStore {
        try TodoStore(
            modelContainer: makeContainer(url: sharedStoreURL()), attachments: AttachmentStore.shared(),
            now: now, didWrite: didWrite
        )
    }

    /// A store on a SQLite file at `url` (tests, tools).
    static func onDisk(
        url: URL,
        attachments: AttachmentStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = nil
    ) throws -> TodoStore {
        try TodoStore(modelContainer: makeContainer(url: url), attachments: attachments, now: now, didWrite: didWrite)
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
            schema: Schema(versionedSchema: HowySchemaV3.self),
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: HowySchemaV3.self),
            migrationPlan: HowyMigrationPlan.self,
            configurations: configuration
        )
    }

    /// An in-memory store for tests and previews.
    public static func inMemory(
        attachments: AttachmentStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = nil
    ) throws -> TodoStore {
        let schema = Schema(versionedSchema: HowySchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: HowyMigrationPlan.self, configurations: configuration)
        return TodoStore(modelContainer: container, attachments: attachments, now: now, didWrite: didWrite)
    }

    /// Asks WidgetKit to reload every Howy widget timeline.
    public static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: Writes

    @discardableResult
    public func add(id: UUID = UUID(), title: String, note: String = "", quadrant: Quadrant, due: Date? = nil) throws -> Todo {
        let title = try Self.validated(title)
        let todo = Todo(id: id, title: title, note: note, quadrant: quadrant, createdAt: now(), due: due)
        context.insert(todo)
        record(.created, for: todo.id, at: todo.createdAt, to: quadrant, due: due)
        try commit()
        return todo
    }

    /// Inserts todos exactly as given, timestamps and `completedAt` included (import). Ids that
    /// already exist, or repeat within `records`, are skipped; existing todos are never changed.
    /// Each inserted todo gets a `created` event at its `createdAt` (and a `completed` one at its
    /// `completedAt` if archived); `updatedAt` is the clock's now.
    /// All of it is one write, so widgets reload once; nothing new writes nothing. Returns the
    /// ids inserted, in order.
    @discardableResult
    public func insert(_ records: [TodoRecord]) throws -> [UUID] {
        let validated = try records.map { record in
            var record = record
            record.title = try Self.validated(record.title)
            return record
        }
        var taken = try allIDs()
        var inserted: [UUID] = []
        let stamp = now()
        for record in validated where taken.insert(record.id).inserted {
            context.insert(Todo(
                id: record.id, title: record.title, note: record.note, quadrant: record.quadrant,
                createdAt: record.createdAt, sortDate: record.sortDate, completedAt: record.completedAt,
                due: record.due, updatedAt: stamp
            ))
            self.record(.created, for: record.id, at: record.createdAt, to: record.quadrant, due: record.due)
            if let completedAt = record.completedAt {
                self.record(.completed, for: record.id, at: completedAt)
            }
            inserted.append(record.id)
        }
        guard !inserted.isEmpty else { return [] }
        do {
            try commit()
        } catch {
            context.rollback()
            throw error
        }
        return inserted
    }

    /// Changes a todo, keeping its due date. Moving it to another quadrant bumps `sortDate` so it
    /// shows on top there.
    public func update(id: UUID, title: String, note: String, quadrant: Quadrant) throws {
        try update(id: id, title: title, note: note, quadrant: quadrant, due: try require(id).due)
    }

    /// Changes a todo, its due date included (`nil` removes it). Moving it to another quadrant
    /// bumps `sortDate` so it shows on top there.
    public func update(id: UUID, title: String, note: String, quadrant: Quadrant, due: Date?) throws {
        let title = try Self.validated(title)
        let todo = try require(id)
        // An untouched edit is a no-op: don't write or reload widgets.
        guard todo.title != title || todo.note != note || todo.quadrant != quadrant || todo.due != due else { return }
        todo.title = title
        todo.note = note
        changeDue(of: todo, to: due)
        moveOnTop(todo, to: quadrant)
        todo.updatedAt = now()
        try commit()
    }

    /// Sets (or with `nil` removes) a todo's due date. The same date again writes nothing.
    /// Due dates never change the quadrant or the order.
    public func setDue(id: UUID, to due: Date?) throws {
        try setDue(id: id, to: due, snoozed: false)
    }

    private func setDue(id: UUID, to due: Date?, snoozed: Bool) throws {
        let todo = try require(id)
        guard todo.due != due else { return }
        changeDue(of: todo, to: due, snoozed: snoozed)
        todo.updatedAt = now()
        try commit()
    }

    /// Removes a todo's due date.
    public func clearDue(id: UUID) throws {
        try setDue(id: id, to: nil)
    }

    /// Moves the due date to `interval` from now (the notification's "Snooze 1 h").
    public func snooze(id: UUID, by interval: TimeInterval) throws {
        try setDue(id: id, to: now().addingTimeInterval(interval), snoozed: true)
    }

    /// Moves the due date to `date` (the notification's "Tomorrow 9:00").
    public func snooze(id: UUID, until date: Date) throws {
        try setDue(id: id, to: date, snoozed: true)
    }

    /// Moves a todo to another quadrant (Browse's ⌘1–4 / move picker): like an edit-modal move
    /// in `update`, `sortDate` is bumped so it lands on top there. Returns the `sortDate` it had
    /// before, for `moveBack`. Moving to its own quadrant writes nothing.
    @discardableResult
    public func move(id: UUID, to quadrant: Quadrant) throws -> Date {
        let todo = try require(id)
        let previous = todo.sortDate
        guard todo.quadrant != quadrant else { return previous }
        moveOnTop(todo, to: quadrant)
        todo.updatedAt = now()
        try commit()
        return previous
    }

    /// Moves a todo to `index` of `quadrant`'s open todos (Overview drag and drop; a drop on the
    /// header is index 0). `index` counts the other todos there and is clamped to their count.
    /// The target's `sortDate`s are rewritten downwards from now, so the order holds and a todo
    /// added later still lands on top. Returns the `sortDate` the todo had before, for
    /// `moveBack` (⌘Z). Within its own quadrant this reorders; already there writes nothing.
    @discardableResult
    public func move(id: UUID, to quadrant: Quadrant, at index: Int) throws -> Date {
        let todo = try require(id)
        let previous = todo.sortDate
        let current = try openTodos(in: quadrant)
        var ordered = current.filter { $0.id != id }
        ordered.insert(todo, at: min(max(index, 0), ordered.count))
        guard ordered.map(\.id) != current.map(\.id) else { return previous } // already there
        recordMove(of: todo, to: quadrant)
        todo.quadrant = quadrant
        todo.updatedAt = now()
        let newest = max(now(), ordered.first(where: { $0.id != id })?.sortDate ?? .distantPast)
        for (position, item) in ordered.enumerated() {
            setSortDate(of: item, to: newest.addingTimeInterval(-Double(position) * 0.001))
        }
        try commit()
        return previous
    }

    /// Takes back a `move` (Browse's ⌘Z): the todo returns to `quadrant` with the `sortDate`
    /// `move` returned, so it is back at the position it had there.
    public func moveBack(id: UUID, to quadrant: Quadrant, sortDate: Date) throws {
        let todo = try require(id)
        guard todo.quadrant != quadrant || todo.sortDate != sortDate else { return }
        recordMove(of: todo, to: quadrant)
        todo.quadrant = quadrant
        todo.sortDate = sortDate
        todo.updatedAt = now()
        try commit()
    }

    /// Archives the todo. Completing an already archived todo keeps its original `completedAt`.
    /// The due date stays (its notification is cancelled by the next notification sync).
    public func complete(id: UUID) throws {
        let todo = try require(id)
        guard todo.completedAt == nil else { return } // no-op: don't write or reload widgets
        todo.completedAt = now()
        todo.updatedAt = now()
        record(.completed, for: id)
        try commit()
    }

    /// Brings an archived todo back into its original quadrant, on top: `sortDate` is bumped so
    /// an undone tick doesn't vanish under "+N more". With `onTop` false (Browse's ⌘Z, moments
    /// after the tick) `sortDate` is left alone, so the todo returns to the position it had.
    /// Restoring an open todo does nothing. The due date is kept.
    public func restore(id: UUID, onTop: Bool = true) throws {
        let todo = try require(id)
        guard todo.completedAt != nil else { return }
        todo.completedAt = nil
        if onTop { todo.sortDate = now() }
        todo.updatedAt = now()
        record(.reopened, for: id)
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
            setSortDate(of: todo, to: newest.addingTimeInterval(-Double(index) * 0.001))
        }
        try commit()
    }

    /// Deletes the todo and its attached files. Its events stay, plus a `deleted` one.
    public func delete(id: UUID) throws {
        let todo = try require(id)
        record(.deleted, for: id, from: todo.quadrant)
        context.delete(todo)
        try commit()
        attachments?.removeAll(for: id)
    }

    /// Makes `list` the todo's attachments (see `AttachmentStore.commit`); reloads widgets when
    /// that changed anything, since they show a paperclip.
    public func setAttachments(_ list: [TodoAttachment], for id: UUID) throws {
        guard let attachments else { return }
        if try attachments.commit(list, for: id) { didWrite?() }
    }

    /// Deletes archived todos (and their files) completed longer than `retention` before `now`
    /// (default: the injected clock). A todo completed exactly `retention` ago is kept. Returns the
    /// number removed. Their events stay, and the purge records none: the history ends at
    /// `completed`.
    @discardableResult
    public func purgeArchive(now: Date? = nil, retention: ArchiveRetention = .default) throws -> Int {
        let cutoff = (now ?? self.now()).addingTimeInterval(-retention.interval)
        let expired = try context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { todo in
            todo.completedAt.flatMap { $0 < cutoff } == true
        }))
        guard !expired.isEmpty else { return 0 }
        let ids = expired.map(\.id)
        expired.forEach(context.delete)
        try commit()
        ids.forEach { attachments?.removeAll(for: $0) }
        return ids.count
    }

    // MARK: Reads

    public func todo(id: UUID) throws -> Todo? {
        var descriptor = FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Every todo, open and archived, oldest `createdAt` first (export).
    public func allTodos() throws -> [Todo] {
        try context.fetch(FetchDescriptor<Todo>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    /// A todo's events, oldest first. Kept after the todo is deleted or purged.
    public func events(for todoID: UUID) throws -> [TodoEvent] {
        Self.chronological(try context.fetch(FetchDescriptor<TodoEvent>(
            predicate: #Predicate { $0.todoID == todoID },
            sortBy: [SortDescriptor(\.date)]
        )))
    }

    /// Every event of every todo, oldest first.
    public func allEvents() throws -> [TodoEvent] {
        Self.chronological(try context.fetch(FetchDescriptor<TodoEvent>(sortBy: [SortDescriptor(\.date)])))
    }

    /// Oldest first; events at the same moment (one save, or a fast clock) in `TodoEventKind`
    /// declaration order, so `created` comes before `completed` and the order is stable.
    private static func chronological(_ events: [TodoEvent]) -> [TodoEvent] {
        let rank = { (event: TodoEvent) in
            event.kind.flatMap { TodoEventKind.allCases.firstIndex(of: $0) } ?? TodoEventKind.allCases.count
        }
        return events.sorted { ($0.date, rank($0)) < ($1.date, rank($1)) }
    }

    /// The ids of all todos.
    func allIDs() throws -> Set<UUID> {
        var descriptor = FetchDescriptor<Todo>()
        descriptor.propertiesToFetch = [\.id]
        return Set(try context.fetch(descriptor).map(\.id))
    }

    /// The injected clock's time.
    var currentDate: Date { now() }

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
            result[quadrant] = try openTodos(in: quadrant).map(snapshot(of:))
        }
        return result
    }

    /// Open todos that have a due date, earliest due first (input for `NotificationPlan`).
    public func openDueSnapshots() throws -> [TodoSnapshot] {
        try context.fetch(FetchDescriptor<Todo>(
            predicate: #Predicate { $0.completedAt == nil && $0.due != nil },
            sortBy: [SortDescriptor(\.createdAt)]
        ))
        .map(snapshot(of:))
        .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// A todo as a value, with its attachment count.
    public func snapshot(of todo: Todo) -> TodoSnapshot {
        var snapshot = todo.snapshot
        snapshot.attachmentCount = attachments?.attachments(for: todo.id).count ?? 0
        return snapshot
    }

    /// A todo's committed attachments, in order.
    public func attachmentList(for id: UUID) -> [TodoAttachment] {
        attachments?.attachments(for: id) ?? []
    }

    // MARK: Helpers

    private static func validated(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TodoStoreError.emptyTitle }
        return trimmed
    }

    /// The one quadrant change (edit modal and Browse): on top of the new quadrant. Records the
    /// move.
    private func moveOnTop(_ todo: Todo, to quadrant: Quadrant) {
        guard todo.quadrant != quadrant else { return }
        recordMove(of: todo, to: quadrant)
        todo.quadrant = quadrant
        todo.sortDate = now()
    }

    /// Sets the due date and records the matching event (nothing when unchanged). Doesn't
    /// stamp `updatedAt`; the caller does.
    private func changeDue(of todo: Todo, to due: Date?, snoozed: Bool = false) {
        guard todo.due != due else { return }
        let kind: TodoEventKind = switch (todo.due, due) {
        case (_, nil): .dueRemoved
        case _ where snoozed: .dueSnoozed
        case (nil, _): .dueSet
        default: .dueChanged
        }
        record(kind, for: todo.id, previousDue: todo.due, due: due)
        todo.due = due
    }

    /// Records a `moved` event if `quadrant` is another one than the todo's.
    private func recordMove(of todo: Todo, to quadrant: Quadrant) {
        guard todo.quadrant != quadrant else { return }
        record(.moved, for: todo.id, from: todo.quadrant, to: quadrant)
    }

    /// Rewrites a `sortDate` (reorders), stamping `updatedAt` only if it really changes.
    private func setSortDate(of todo: Todo, to date: Date) {
        guard todo.sortDate != date else { return }
        todo.sortDate = date
        todo.updatedAt = now()
    }

    /// Inserts an event into the context; the caller's `commit` saves it with the change.
    private func record(
        _ kind: TodoEventKind, for todoID: UUID, at date: Date? = nil,
        from: Quadrant? = nil, to: Quadrant? = nil, previousDue: Date? = nil, due: Date? = nil
    ) {
        context.insert(TodoEvent(
            todoID: todoID, kind: kind, date: date ?? now(),
            from: from, to: to, previousDue: previousDue, due: due
        ))
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
