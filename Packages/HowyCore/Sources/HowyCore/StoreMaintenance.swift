import Foundation
import SwiftData

/// What `TodoStore.removeDuplicates` removed.
public struct DuplicateCleanup: Hashable, Sendable {
    /// Todo rows deleted because another row with the same id survived.
    public var removedTodos: Int
    /// Event rows deleted because another row with the same id survived.
    public var removedEvents: Int

    public init(removedTodos: Int = 0, removedEvents: Int = 0) {
        self.removedTodos = removedTodos
        self.removedEvents = removedEvents
    }

    /// Whether nothing was removed (and nothing written).
    public var isEmpty: Bool { removedTodos == 0 && removedEvents == 0 }
}

/// Store work that runs on its own background `ModelContext` (same container as the
/// `TodoStore`), so the launch cleanups and the daily backup don't block the main actor.
///
/// Only `TodoStore` and `DailyBackup` use it; models never leave the actor, only values do.
@ModelActor
actor StoreMaintenance {
    // MARK: Duplicates

    /// Collapses rows that share an `id` (schema v3 has no unique constraint; duplicates come
    /// from edge cases such as two Macs importing the same file, or the app and the widget
    /// backfilling at once). Keeps one todo per id (`prefers(_:over:)`) and one event per id
    /// (the earliest by `date`, then `seq`; same-id events are copies of one event). Records no
    /// events. A clean store isn't saved.
    func removeDuplicates() throws -> DuplicateCleanup {
        var result = DuplicateCleanup()
        let todos = try modelContext.fetch(FetchDescriptor<Todo>())
        for rows in Dictionary(grouping: todos, by: \.id).values where rows.count > 1 {
            let keep = rows.reduce(rows[0]) { Self.prefers($1, over: $0) ? $1 : $0 }
            for row in rows where row !== keep {
                modelContext.delete(row)
                result.removedTodos += 1
            }
        }
        let events = try modelContext.fetch(FetchDescriptor<TodoEvent>())
        for rows in Dictionary(grouping: events, by: \.id).values where rows.count > 1 {
            let keep = rows.reduce(rows[0]) { Self.isEarlier($1, than: $0) ? $1 : $0 }
            for row in rows where row !== keep {
                modelContext.delete(row)
                result.removedEvents += 1
            }
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

    /// Which of two rows with the same id survives. In order, the first difference decides:
    /// 1. the newer `updatedAt` (the last write wins);
    /// 2. archived over open (a tick isn't lost);
    /// 3. with a due date over without;
    /// 4. the longer note;
    /// 5. the newer `sortDate`;
    /// 6. the greater title, then the greater note, by plain string order (only so the choice
    ///    never depends on fetch order).
    ///
    /// Rows equal in all of these are interchangeable.
    static func prefers(_ a: Todo, over b: Todo) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.isOpen != b.isOpen { return !a.isOpen }
        if (a.due != nil) != (b.due != nil) { return a.due != nil }
        if a.note.count != b.note.count { return a.note.count > b.note.count }
        if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
        if a.title != b.title { return a.title > b.title }
        return a.note > b.note
    }

    private static func isEarlier(_ a: TodoEvent, than b: TodoEvent) -> Bool {
        if a.date != b.date { return a.date < b.date }
        if a.seq != b.seq { return a.seq < b.seq }
        return a.kindRaw < b.kindRaw
    }

    // MARK: Reads

    /// The ids of all todos, open and archived.
    func todoIDs() throws -> Set<UUID> {
        var descriptor = FetchDescriptor<Todo>()
        descriptor.propertiesToFetch = [\.id]
        return Set(try modelContext.fetch(descriptor).map(\.id))
    }

    /// Whether the store has neither todos nor events.
    func isEmpty() throws -> Bool {
        try modelContext.fetchCount(FetchDescriptor<Todo>()) == 0
            && modelContext.fetchCount(FetchDescriptor<TodoEvent>()) == 0
    }

    /// Everything an export writes, read on this background context.
    func exportDocument(appVersion: String?, exportedAt: Date, attachments: AttachmentStore?) throws -> HowyExport {
        try HowyExport(
            appVersion: appVersion, exportedAt: exportedAt,
            todos: modelContext.fetch(FetchDescriptor<Todo>(sortBy: [SortDescriptor(\.createdAt)])),
            events: modelContext.fetch(FetchDescriptor<TodoEvent>(sortBy: [SortDescriptor(\.date), SortDescriptor(\.seq)])),
            attachments: attachments
        )
    }
}
