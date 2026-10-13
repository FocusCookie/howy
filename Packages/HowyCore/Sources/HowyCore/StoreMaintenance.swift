import Foundation
import SwiftData

/// What `TodoStore.removeDuplicates` removed.
public struct DuplicateCleanup: Hashable, Sendable {
    /// Todo rows deleted because a row with the same id and other values survived.
    public var removedTodos: Int
    /// Event rows deleted because a row with the same id and other values survived.
    public var removedEvents: Int
    /// Attachment rows deleted because a row with the same id and other values survived.
    public var removedAttachments: Int

    public init(removedTodos: Int = 0, removedEvents: Int = 0, removedAttachments: Int = 0) {
        self.removedTodos = removedTodos
        self.removedEvents = removedEvents
        self.removedAttachments = removedAttachments
    }

    /// Whether nothing was removed (and nothing written).
    public var isEmpty: Bool { removedTodos == 0 && removedEvents == 0 && removedAttachments == 0 }
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

    @concurrent
    nonisolated static func adoptLegacyAttachments(_ container: ModelContainer, files: AttachmentStore) async -> LegacyAdoption {
        await StoreMaintenance(modelContainer: container).adoptLegacyAttachments(files: files)
    }

    @concurrent
    nonisolated static func removeOrphanedAttachmentRows(
        _ container: ModelContainer, deletedBefore cutoff: Date, unclaimedBefore ageCutoff: Date
    ) async throws -> Int {
        try await StoreMaintenance(modelContainer: container)
            .removeOrphanedAttachmentRows(deletedBefore: cutoff, unclaimedBefore: ageCutoff)
    }

    @concurrent
    nonisolated static func writeLocalCopies(_ container: ModelContainer, files: AttachmentStore, todoID: UUID) async throws -> Int {
        try await StoreMaintenance(modelContainer: container).writeLocalCopies(files: files, todoID: todoID)
    }

    // MARK: Duplicates

    /// Removes rows that share an `id` with a row of other values (schema v3 has no unique
    /// constraint; duplicates come from edge cases such as two Macs importing the same file, or
    /// the app and the widget backfilling at once, and with CloudKit each row is its own record).
    ///
    /// Safe across devices: every Mac runs this on its own, so it must delete the same records
    /// everywhere. Per id the survivor is chosen by a total order over the stored values
    /// (`Todo.prefers(_:over:)`, `TodoEvent.prefers(_:over:)`, `StoredAttachment.prefers(_:over:)`), never by fetch order or
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
        let attachmentIDs = try repeatedIDs(\StoredAttachment.id)
        guard !todoIDs.isEmpty || !eventIDs.isEmpty || !attachmentIDs.isEmpty else { return result }
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
        if !attachmentIDs.isEmpty {
            let ids = Array(attachmentIDs)
            let rows = try fresh.fetch(FetchDescriptor<StoredAttachment>(predicate: #Predicate { ids.contains($0.id) }))
            for row in DuplicateRules.losers(rows) {
                fresh.delete(row)
                result.removedAttachments += 1
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

    /// Everything an export writes, read on this background context: one todo, one event and
    /// one attachment per id (the survivors, as `TodoStore` reads them). The attachments are
    /// only listed here; `HowyExporter.write` takes their bytes from the store and writes them
    /// into the export, so reading never creates local copies. `attachments` is only read, for
    /// the lists of an older build that aren't adopted into the store yet (their files are the
    /// only copy; `write` takes those from `attachments`).
    func exportDocument(appVersion: String?, exportedAt: Date, attachments: AttachmentStore?) throws -> HowyExport {
        assert(!Thread.isMainThread, "StoreMaintenance must run off the main thread")
        var lists: [UUID: [TodoAttachment]] = [:]
        let rows = try modelContext.fetch(FetchDescriptor<StoredAttachment>())
        for (todoID, group) in Dictionary(grouping: rows, by: \.todoID) {
            lists[todoID] = group.orderedSurvivors.map(\.attachment)
        }
        if let attachments {
            for todoID in attachments.legacyTodoIDs() {
                let stored = lists[todoID] ?? []
                let extra = attachments.unadoptedAttachments(for: todoID, excluding: Set(stored.map(\.id)))
                if !extra.isEmpty { lists[todoID] = stored + extra }
            }
        }
        return try HowyExport(
            appVersion: appVersion, exportedAt: exportedAt,
            todos: DuplicateRules.collapsed(modelContext.fetch(FetchDescriptor<Todo>(sortBy: [SortDescriptor(\.createdAt)]))),
            events: DuplicateRules.collapsed(
                modelContext.fetch(FetchDescriptor<TodoEvent>(sortBy: [SortDescriptor(\.date), SortDescriptor(\.seq)]))
            ),
            attachments: lists
        )
    }

    // MARK: Attachments

    /// See `TodoStore.adoptLegacyAttachments`.
    ///
    /// One todo at a time, each on its own fresh context and saved on its own, inside an
    /// autorelease pool: the bytes of one todo's files are freed before the next todo's are
    /// read, and a file that can't be read or a save that fails stops only that todo (its list
    /// stays for the next run).
    func adoptLegacyAttachments(files: AttachmentStore) -> LegacyAdoption {
        assert(!Thread.isMainThread, "StoreMaintenance must run off the main thread")
        var result = LegacyAdoption()
        let folders = files.legacyTodoIDs()
        guard !folders.isEmpty, let existing = try? todoIDs() else { return result }
        for todoID in folders.intersection(existing).sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                let adopted = try autoreleasepool { try adoptFolder(of: todoID, files: files) }
                result.adopted += adopted.count
                if !adopted.complete { result.incompleteTodos += 1 }
            } catch {
                result.failedTodos += 1
            }
        }
        return result
    }

    /// Moves one todo's legacy attachments into the store, after the rows it already has, and
    /// removes the legacy list when every readable file is stored. `complete` is false when a
    /// file couldn't be read (the list stays).
    private func adoptFolder(of todoID: UUID, files: AttachmentStore) throws -> (count: Int, complete: Bool) {
        guard let list = files.legacyAttachments(for: todoID) else { return (0, false) }
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<StoredAttachment>(predicate: #Predicate { $0.todoID == todoID })
        descriptor.propertiesToFetch = [\.id, \.position]
        let rows = try context.fetch(descriptor)
        var stored = Set(rows.map(\.id))
        var position = (rows.map(\.position).max() ?? -1) + 1
        var count = 0
        var complete = true
        for attachment in list where !stored.contains(attachment.id) {
            // A file the list names but that is gone has nothing to adopt (it couldn't be
            // opened before either); one that can't be read keeps the list for a retry.
            guard let url = files.committedFile(attachment, todoID: todoID) else { continue }
            guard let data = try? Data(contentsOf: url) else {
                complete = false
                continue
            }
            context.insert(StoredAttachment(
                id: attachment.id, todoID: todoID, name: attachment.name, position: position,
                data: data, updatedAt: .distantPast
            ))
            stored.insert(attachment.id)
            position += 1
            count += 1
        }
        if count > 0 {
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
        if complete { files.removeLegacyList(for: todoID) }
        return (count, complete)
    }

    /// See `TodoStore.materializeAttachments`.
    func writeLocalCopies(files: AttachmentStore, todoID: UUID) throws -> Int {
        assert(!Thread.isMainThread, "StoreMaintenance must run off the main thread")
        let rows = try modelContext.fetch(FetchDescriptor<StoredAttachment>(predicate: #Predicate { $0.todoID == todoID }))
        var written = 0
        for group in Dictionary(grouping: rows, by: \.id).values {
            guard let survivor = DuplicateRules.survivor(of: group) else { continue }
            let attachment = survivor.attachment
            guard files.committedFile(attachment, todoID: todoID) == nil, let data = group.bytes else { continue }
            _ = try files.writeCommitted(data, for: attachment, todoID: todoID)
            written += 1
        }
        return written
    }

    /// Deletes the attachment rows of todos that are gone. A todo is gone when it has no todo
    /// row and either
    /// - a `deleted` event whose newest one is before `cutoff` (the todo was deleted, here or on
    ///   another Mac, by a build that left the rows, or after a delete raced an edit that lost),
    ///   or
    /// - no events at all, and rows that are all dated and all before `ageCutoff` (a save that
    ///   stored the files but never created the todo, say after a crash). Adopted rows have no
    ///   date and never count as old.
    ///
    /// A todo with events but no `deleted` one is not gone: its row may only have failed to
    /// arrive. Nothing when the store has no todos, or when more than 3 todos have attachments
    /// and more than half of them would go (a store that looks wiped). The rows are read again on
    /// a fresh context right before the delete. Returns how many rows it deleted.
    func removeOrphanedAttachmentRows(deletedBefore cutoff: Date, unclaimedBefore ageCutoff: Date) throws -> Int {
        assert(!Thread.isMainThread, "StoreMaintenance must run off the main thread")
        var descriptor = FetchDescriptor<StoredAttachment>()
        descriptor.propertiesToFetch = [\.todoID, \.updatedAt]
        var owners = Set<UUID>()
        var undatedOrRecent = Set<UUID>() // an owner with a row that isn't old enough to be given up on
        for row in try modelContext.fetch(descriptor) {
            owners.insert(row.todoID)
            if row.hasUnknownAge || row.updatedAt >= ageCutoff { undatedOrRecent.insert(row.todoID) }
        }
        guard !owners.isEmpty else { return 0 }
        let existing = try todoIDs()
        guard !existing.isEmpty else { return 0 }
        let missing = Array(owners.subtracting(existing))
        guard !missing.isEmpty else { return 0 }
        var events = FetchDescriptor<TodoEvent>(predicate: #Predicate { missing.contains($0.todoID) })
        events.propertiesToFetch = [\.todoID, \.kindRaw, \.date]
        let deletedKind = TodoEventKind.deleted.rawValue
        var deletedAt: [UUID: Date] = [:]
        var withEvents = Set<UUID>()
        for event in try modelContext.fetch(events) {
            withEvents.insert(event.todoID)
            if event.kindRaw == deletedKind { deletedAt[event.todoID] = max(deletedAt[event.todoID] ?? event.date, event.date) }
        }
        var gone = Set(deletedAt.filter { $0.value < cutoff }.keys)
        gone.formUnion(missing.filter { !withEvents.contains($0) && !undatedOrRecent.contains($0) })
        guard !gone.isEmpty, !(owners.count > 3 && gone.count * 2 > owners.count) else { return 0 }
        let fresh = ModelContext(modelContainer)
        var still = FetchDescriptor<Todo>()
        still.propertiesToFetch = [\.id]
        let ids = Array(gone.subtracting(try fresh.fetch(still).map(\.id)))
        guard !ids.isEmpty else { return 0 }
        let rows = try fresh.fetch(FetchDescriptor<StoredAttachment>(predicate: #Predicate { ids.contains($0.todoID) }))
        guard !rows.isEmpty else { return 0 }
        rows.forEach(fresh.delete)
        do {
            try fresh.save()
        } catch {
            fresh.rollback()
            throw error
        }
        return rows.count
    }
}

/// What `TodoStore.adoptLegacyAttachments` did.
struct LegacyAdoption: Sendable {
    /// Attachments stored.
    var adopted = 0
    /// Todos whose list stays because a file couldn't be read.
    var incompleteTodos = 0
    /// Todos whose save failed.
    var failedTodos = 0
}
