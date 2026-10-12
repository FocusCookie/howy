import Foundation
import SwiftData

/// What `TodoStore.removeDuplicates` removed.
public struct DuplicateCleanup: Hashable, Sendable {
    /// Todo rows deleted because a row with the same id and other values survived.
    public var removedTodos: Int
    /// Event rows deleted because a row with the same id and other values survived.
    public var removedEvents: Int

    public init(removedTodos: Int = 0, removedEvents: Int = 0) {
        self.removedTodos = removedTodos
        self.removedEvents = removedEvents
    }

    /// Whether nothing was removed (and nothing written).
    public var isEmpty: Bool { removedTodos == 0 && removedEvents == 0 }
}

/// Store work that runs on its own background `ModelContext` (same container as the
/// `TodoStore`; for the shared store, the process's one `SharedContainer`), so the launch
/// cleanups and the daily backup don't block the main actor.
///
/// Reads collapse rows that share an id exactly as `TodoStore` does (`DuplicateRules`).
///
/// Only `TodoStore` and `DailyBackup` use it; models never leave the actor, only values do.
///
/// Always go through the `@concurrent` static helpers (`removeDuplicates(_:)`, `todoIDs(_:)`,
/// `isEmpty(_:)`, `exportDocument(_:…)`): they construct the actor off the main actor, which is
/// what makes its `ModelContext` (created in the macro's `init`) and so all its reads and
/// writes run off the main thread. Constructing it on the main actor would put the context
/// there. The heavy methods assert this in debug builds.
@ModelActor
actor StoreMaintenance {
    // MARK: Entry points

    @concurrent
    nonisolated static func removeDuplicates(_ container: ModelContainer) async throws -> DuplicateCleanup {
        try await StoreMaintenance(modelContainer: container).removeDuplicates()
    }

    @concurrent
    nonisolated static func removeDeletedTodos(_ container: ModelContainer) async throws -> Set<UUID> {
        try await StoreMaintenance(modelContainer: container).removeDeletedTodos()
    }

    @concurrent
    nonisolated static func todoIDs(_ container: ModelContainer) async throws -> Set<UUID> {
        try await StoreMaintenance(modelContainer: container).todoIDs()
    }

    @concurrent
    nonisolated static func isEmpty(_ container: ModelContainer) async throws -> Bool {
        try await StoreMaintenance(modelContainer: container).isEmpty()
    }

    @concurrent
    nonisolated static func exportDocument(
        _ container: ModelContainer, appVersion: String?, exportedAt: Date, attachments: AttachmentStore?
    ) async throws -> HowyExport {
        try await StoreMaintenance(modelContainer: container)
            .exportDocument(appVersion: appVersion, exportedAt: exportedAt, attachments: attachments)
    }

    // MARK: Duplicates

    /// Removes rows that share an `id` with a row of other values (schema v3 has no unique
    /// constraint; duplicates come from edge cases such as two Macs importing the same file, or
    /// the app and the widget backfilling at once, and with CloudKit each row is its own record).
    ///
    /// Safe across devices: every Mac runs this on its own, so it must delete the same records
    /// everywhere. Per id the survivor is chosen by a total order over the stored values
    /// (`Todo.prefers(_:over:)`, `TodoEvent.prefers(_:over:)`), never by fetch order or
    /// anything device-local, and every row with the survivor's exact values stays. Fully
    /// identical rows are never deleted (each Mac could delete a different one, and both records
    /// would go); reads show them as one. Records no events. A clean store isn't saved.
    func removeDuplicates() throws -> DuplicateCleanup {
        assert(!Thread.isMainThread, "StoreMaintenance must run off the main thread")
        var result = DuplicateCleanup()
        // Ids first (a cheap check; most runs end here), then, on a fresh context, the full
        // rows of the repeated ids only, read right before the delete: rows that arrived since
        // are in the decision, and no twin is deleted from a stale snapshot.
        let todoIDs = try repeatedIDs(\Todo.id)
        let eventIDs = try repeatedIDs(\TodoEvent.id)
        guard !todoIDs.isEmpty || !eventIDs.isEmpty else { return result }
        let fresh = ModelContext(modelContainer)
        if !todoIDs.isEmpty {
            let ids = Array(todoIDs)
            let rows = try fresh.fetch(FetchDescriptor<Todo>(predicate: #Predicate { ids.contains($0.id) }))
            for row in DuplicateRules.losers(rows) {
                fresh.delete(row)
                result.removedTodos += 1
            }
        }
        if !eventIDs.isEmpty {
            let ids = Array(eventIDs)
            let rows = try fresh.fetch(FetchDescriptor<TodoEvent>(predicate: #Predicate { ids.contains($0.id) }))
            for row in DuplicateRules.losers(rows) {
                fresh.delete(row)
                result.removedEvents += 1
            }
        }
        guard !result.isEmpty else { return result }
        do {
            try fresh.save()
        } catch {
            fresh.rollback()
            throw error
        }
        return result
    }

    // MARK: Deleted todos

    /// Deletes todo rows that a `deleted` event has outdated: every row whose `updatedAt` is at or
    /// before the newest `deleted` event of its id (compared in milliseconds,
    /// `DuplicateRules.milliseconds`). Such a row came back after the delete: a twin or a late
    /// write from another device that arrived once the delete had already removed the local rows.
    ///
    /// Every device applies it alike, from synced values only (the rows and the events). A write
    /// after the delete (an edit on another Mac, or an import, which stamps `updatedAt` with the
    /// clock's now) is newer than the event and keeps the todo. Records no events (the `deleted`
    /// one is there). Returns the ids removed; a store without such rows isn't saved.
    func removeDeletedTodos() throws -> Set<UUID> {
        assert(!Thread.isMainThread, "StoreMaintenance must run off the main thread")
        let deletedKind = TodoEventKind.deleted.rawValue
        var descriptor = FetchDescriptor<TodoEvent>(predicate: #Predicate { $0.kindRaw == deletedKind })
        descriptor.propertiesToFetch = [\.todoID, \.date]
        var deletedAt: [UUID: Int64] = [:]
        for event in try modelContext.fetch(descriptor) {
            let stamp = DuplicateRules.milliseconds(event.date)
            deletedAt[event.todoID] = max(deletedAt[event.todoID] ?? stamp, stamp)
        }
        guard !deletedAt.isEmpty else { return [] }
        let ids = Array(deletedAt.keys)
        // The rows are read on a fresh context right before the delete (an edit that arrived
        // since is newer than the event and keeps its todo).
        let fresh = ModelContext(modelContainer)
        let rows = try fresh.fetch(FetchDescriptor<Todo>(predicate: #Predicate { ids.contains($0.id) }))
        var removed = Set<UUID>()
        for row in rows {
            guard let stamp = deletedAt[row.id], DuplicateRules.milliseconds(row.updatedAt) <= stamp else { continue }
            fresh.delete(row)
            removed.insert(row.id)
        }
        guard !removed.isEmpty else { return [] }
        do {
            try fresh.save()
        } catch {
            fresh.rollback()
            throw error
        }
        return removed
    }

    /// The ids that more than one row of `Model` has, read without loading the other values.
    ///
    /// Takes the model's own key path: a `\Model.id` written in a generic context resolves through
    /// the protocol requirement, which SwiftData doesn't know as a stored property (it traps with
    /// "Couldn't find \Todo.<computed …> on Todo").
    private func repeatedIDs<Model: PersistentModel>(_ id: KeyPath<Model, UUID>) throws -> Set<UUID> {
        var descriptor = FetchDescriptor<Model>()
        descriptor.propertiesToFetch = [id]
        return DuplicateRules.repeated(try modelContext.fetch(descriptor).map { $0[keyPath: id] })
    }

    // MARK: Reads

    /// The ids of all todos, open and archived.
    func todoIDs() throws -> Set<UUID> {
        assert(!Thread.isMainThread, "StoreMaintenance must run off the main thread")
        var descriptor = FetchDescriptor<Todo>()
        descriptor.propertiesToFetch = [\.id]
        return Set(try modelContext.fetch(descriptor).map(\.id))
    }

    /// Whether the store has neither todos nor events.
    func isEmpty() throws -> Bool {
        assert(!Thread.isMainThread, "StoreMaintenance must run off the main thread")
        return try modelContext.fetchCount(FetchDescriptor<Todo>()) == 0
            && modelContext.fetchCount(FetchDescriptor<TodoEvent>()) == 0
    }

    /// Everything an export writes, read on this background context: one todo and one event per
    /// id (the survivors, as `TodoStore` reads them).
    func exportDocument(appVersion: String?, exportedAt: Date, attachments: AttachmentStore?) throws -> HowyExport {
        assert(!Thread.isMainThread, "StoreMaintenance must run off the main thread")
        return try HowyExport(
            appVersion: appVersion, exportedAt: exportedAt,
            todos: DuplicateRules.collapsed(modelContext.fetch(FetchDescriptor<Todo>(sortBy: [SortDescriptor(\.createdAt)]))),
            events: DuplicateRules.collapsed(
                modelContext.fetch(FetchDescriptor<TodoEvent>(sortBy: [SortDescriptor(\.date), SortDescriptor(\.seq)]))
            ),
            attachments: attachments
        )
    }
}
