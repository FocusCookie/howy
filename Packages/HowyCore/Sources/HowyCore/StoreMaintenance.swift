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
        for row in DuplicateRules.losers(try modelContext.fetch(FetchDescriptor<Todo>())) {
            modelContext.delete(row)
            result.removedTodos += 1
        }
        for row in DuplicateRules.losers(try modelContext.fetch(FetchDescriptor<TodoEvent>())) {
            modelContext.delete(row)
            result.removedEvents += 1
        }
        guard !result.isEmpty else { return result }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return result
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
