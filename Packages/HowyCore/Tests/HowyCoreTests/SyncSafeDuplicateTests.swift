import Foundation
import SwiftData
import Testing
@testable import HowyCore

/// Duplicates as CloudKit sync makes them: two rows with one id are two CloudKit records, and
/// every Mac runs the cleanup on its own. Each must delete the same rows, so fully identical
/// rows are never deleted (each Mac could pick a different one, and both would go) and rows
/// that differ resolve by their stored values only.
@MainActor
@Suite final class SyncSafeDuplicateTests {
    let clock = FakeClock()
    let writes = TodoStoreTests.WriteCounter()
    let store: TodoStore

    init() throws {
        let clock = clock
        let writes = writes
        store = try TodoStore.inMemory(now: { clock.now }, didWrite: { writes.count += 1 })
    }

    // MARK: Helpers

    /// A row with exactly the stored values of `todo`, as a second CloudKit record would bring.
    func twin(of todo: Todo, in store: TodoStore? = nil) throws {
        let store = store ?? self.store
        store.context.insert(Self.copy(of: todo))
        try store.context.save()
    }

    static func copy(of todo: Todo) -> Todo {
        Todo(
            id: todo.id, title: todo.title, note: todo.note, quadrant: todo.quadrant,
            createdAt: todo.createdAt, sortDate: todo.sortDate, completedAt: todo.completedAt,
            due: todo.due, updatedAt: todo.updatedAt
        )
    }

    /// Every stored value of a row, `updatedAt` included.
    struct Values: Hashable {
        var record: TodoRecord
        var updatedAt: Date
        init(_ todo: Todo) {
            record = todo.record
            updatedAt = todo.updatedAt
        }
    }

    func rows(_ id: UUID, in store: TodoStore? = nil) throws -> [Values] {
        try (store ?? self.store).todos(id: id).map(Values.init)
    }

    /// The rows of `id` are all equal, and there are `count` of them.
    func expectTwins(_ id: UUID, count: Int = 2, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let values = try rows(id)
        #expect(values.count == count, sourceLocation: sourceLocation)
        #expect(Set(values).count == 1, "the rows must stay identical", sourceLocation: sourceLocation)
    }

    // MARK: Identical twins: kept, and seen as one

    @Test func identicalTwinsSurviveTheCleanup() async throws {
        let todo = try store.add(title: "Twin", note: "note", quadrant: .notUrgentImportant, due: clock.now.addingTimeInterval(3600))
        try twin(of: todo)
        writes.count = 0

        let result = try await store.removeDuplicates()

        #expect(result.isEmpty)
        #expect(writes.count == 0)
        try expectTwins(todo.id)
    }

    @Test func identicalTwinsAppearOnceInEveryRead() async throws {
        let due = clock.now.addingTimeInterval(3600)
        let open = try store.add(title: "Open", quadrant: .urgentImportant, due: due)
        let done = try store.add(title: "Done", quadrant: .notUrgentImportant)
        try store.complete(id: done.id)
        try twin(of: open)
        try twin(of: done)

        #expect(try store.todo(id: open.id)?.title == "Open")
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [open.id])
        #expect(try store.openSnapshots()[.urgentImportant]?.map(\.id) == [open.id])
        #expect(try store.openDueSnapshots().map(\.id) == [open.id])
        #expect(try store.archivedTodos().map(\.id) == [done.id])
        let all = try store.allTodos().map(\.id)
        #expect(all.count == 2)
        #expect(Set(all) == [open.id, done.id])
        #expect(try store.allIDs() == [open.id, done.id])
        let document = try await StoreMaintenance.exportDocument(
            store.modelContainer, appVersion: nil, exportedAt: clock.now, attachments: nil
        )
        #expect(document.todos.count == 2)
        let content = WidgetContentBuilder.build(openTodos: try store.openSnapshots(), family: .large, selectedQuadrant: nil)
        #expect(content == WidgetContentBuilder.build(
            openTodos: [.urgentImportant: [store.snapshot(of: try #require(try store.todo(id: open.id)))]],
            family: .large, selectedQuadrant: nil
        ))
    }

    @Test func writesToATwinPairChangeBothRowsAndRecordOneEvent() throws {
        let todo = try store.add(title: "Twin", quadrant: .urgentImportant)
        let other = try store.add(title: "Other", quadrant: .urgentImportant)
        try twin(of: todo)
        let id = todo.id
        var events = try store.allEvents().count

        func step(_ label: Comment, newEvents: Int, _ write: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) throws {
            clock.advance(by: 60)
            try write()
            try expectTwins(id, sourceLocation: sourceLocation)
            let count = try store.allEvents().count
            #expect(count - events == newEvents, label, sourceLocation: sourceLocation)
            events = count
        }

        try step("update", newEvents: 0) { try store.update(id: id, title: "Renamed", note: "n", quadrant: .urgentImportant) }
        #expect(try rows(id).first?.record.title == "Renamed")
        try step("update with move and due", newEvents: 2) {
            try store.update(id: id, title: "Renamed", note: "n", quadrant: .notUrgentImportant, due: clock.now.addingTimeInterval(600))
        }
        try step("setDue", newEvents: 1) { try store.setDue(id: id, to: clock.now.addingTimeInterval(900)) }
        try step("snooze", newEvents: 1) { try store.snooze(id: id, by: 3600) }
        try step("snooze until", newEvents: 1) { try store.snooze(id: id, until: clock.now.addingTimeInterval(86_400)) }
        try step("clearDue", newEvents: 1) { try store.clearDue(id: id) }
        var previous = Date.distantPast
        try step("move", newEvents: 1) { previous = try store.move(id: id, to: .urgentImportant) }
        try step("moveBack", newEvents: 1) { try store.moveBack(id: id, to: .notUrgentImportant, sortDate: previous) }
        try step("move at index", newEvents: 1) { try store.move(id: id, to: .urgentImportant, at: 1) }
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [other.id, id])
        try step("reorder", newEvents: 0) { try store.reorder([id, other.id], in: .urgentImportant) }
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [id, other.id])
        try step("complete", newEvents: 1) { try store.complete(id: id) }
        #expect(try rows(id).allSatisfy { $0.record.completedAt != nil })
        try step("restore", newEvents: 1) { try store.restore(id: id) }
        #expect(try rows(id).allSatisfy { $0.record.completedAt == nil })

        clock.advance(by: 60)
        try store.delete(id: id)
        #expect(try store.todos(id: id).isEmpty)
        #expect(try store.allEvents().count - events == 1)
    }

    @Test func purgingDeletesEveryRowOfAnExpiredTwin() throws {
        let todo = try store.add(title: "Old", quadrant: .urgentImportant)
        try store.complete(id: todo.id)
        try twin(of: todo)
        clock.advance(by: ArchiveRetention.default.interval + 60)

        #expect(try store.purgeArchive() == 1)
        #expect(try store.todos(id: todo.id).isEmpty)
    }

    @Test func twinsAndOneDifferentRowKeepTheTwinsWhenTheyWin() async throws {
        let todo = try store.add(title: "Winner", quadrant: .urgentImportant)
        try twin(of: todo)
        let loser = Self.copy(of: todo)
        loser.title = "Loser"
        loser.updatedAt = todo.updatedAt.addingTimeInterval(-60)
        store.context.insert(loser)
        try store.context.save()

        #expect(try store.todo(id: todo.id)?.title == "Winner")
        let result = try await store.removeDuplicates()

        #expect(result == DuplicateCleanup(removedTodos: 1, removedEvents: 0))
        try expectTwins(todo.id)
        #expect(try rows(todo.id).first?.record.title == "Winner")
    }

    // MARK: Different values: the same survivor everywhere

    /// Two rows of one id that differ in exactly one stored value (everything else equal).
    enum TodoChange: String, CaseIterable, Sendable {
        case updatedAt, openVsArchived, completedAt, dueVsNone, due, noteLength, noteText, sortDate, title, createdAt, quadrant

        func apply(to todo: Todo) {
            switch self {
            case .updatedAt: todo.updatedAt = todo.updatedAt.addingTimeInterval(1)
            case .openVsArchived: todo.completedAt = todo.completedAt == nil ? todo.createdAt : nil
            case .completedAt: todo.completedAt = (todo.completedAt ?? todo.createdAt).addingTimeInterval(5)
            case .dueVsNone: todo.due = todo.due == nil ? todo.createdAt.addingTimeInterval(60) : nil
            case .due: todo.due = (todo.due ?? todo.createdAt).addingTimeInterval(5)
            case .noteLength: todo.note += " and more"
            case .noteText: todo.note = String(todo.note.reversed())
            case .sortDate: todo.sortDate = todo.sortDate.addingTimeInterval(5)
            case .title: todo.title += "!"
            case .createdAt: todo.createdAt = todo.createdAt.addingTimeInterval(-5)
            case .quadrant: todo.quadrantRaw = Quadrant.notUrgentUnimportant.rawValue
            }
        }
    }

    @Test(arguments: TodoChange.allCases)
    func differentRowsResolveToTheSameSurvivorInAnyOrder(_ change: TodoChange) async throws {
        let name = change.rawValue
        for base in [Self.baseTodo(archived: false, due: false), Self.baseTodo(archived: true, due: true)] {
            let other = Self.copy(of: base)
            change.apply(to: other)
            guard Values(other) != Values(base) else { continue }

            let first = try TodoStore.inMemory(now: { Date() })
            let second = try TodoStore.inMemory(now: { Date() })
            for row in [base, other] { first.context.insert(Self.copy(of: row)) }
            for row in [other, base] { second.context.insert(Self.copy(of: row)) }
            try first.context.save()
            try second.context.save()

            // Reads already show the row the cleanup will keep.
            let shownFirst = try #require(try first.todo(id: base.id)).record
            let shownSecond = try #require(try second.todo(id: base.id)).record
            #expect(shownFirst == shownSecond, "\(name): reads differ by insertion order")

            #expect(try await first.removeDuplicates().removedTodos == 1, "\(name)")
            #expect(try await second.removeDuplicates().removedTodos == 1, "\(name)")
            let keptFirst = try rows(base.id, in: first)
            let keptSecond = try rows(base.id, in: second)
            #expect(keptFirst.count == 1 && keptFirst == keptSecond, "\(name): survivors differ by insertion order")
            #expect(keptFirst.first?.record == shownFirst, "\(name): the survivor isn't what reads showed")
        }
    }

    static func baseTodo(archived: Bool, due: Bool) -> Todo {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return Todo(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, title: "Base", note: "abc",
            quadrant: .urgentImportant, createdAt: start, sortDate: start.addingTimeInterval(10),
            completedAt: archived ? start.addingTimeInterval(20) : nil,
            due: due ? start.addingTimeInterval(30) : nil, updatedAt: start.addingTimeInterval(40)
        )
    }

    @Test func aWriteToDifferentRowsLeavesThemIdenticalWithTheSurvivorsValues() async throws {
        let todo = try store.add(title: "Newer", quadrant: .urgentImportant)
        let older = Self.copy(of: todo)
        older.title = "Older"
        older.completedAt = clock.now // archived, but older: must not win after the write
        older.updatedAt = todo.updatedAt.addingTimeInterval(-60)
        store.context.insert(older)
        try store.context.save()
        clock.advance(by: 60)

        try store.update(id: todo.id, title: "Edited", note: "", quadrant: .urgentImportant)

        try expectTwins(todo.id)
        let shown = try #require(try store.todo(id: todo.id))
        #expect(shown.title == "Edited")
        #expect(shown.isOpen)
        #expect(try await store.removeDuplicates().isEmpty)
    }

    @Test func aWriteCopiesOnlyTheFieldsItChangedToTheOtherRows() throws {
        let todo = try store.add(title: "Original", note: "survivor note", quadrant: .urgentImportant)
        let other = Self.copy(of: todo)
        // The twin has a value of its own for a field this write won't touch (a newer one from
        // another device, say), and still loses against the survivor.
        other.note = "x"
        other.updatedAt = todo.updatedAt.addingTimeInterval(-1)
        store.context.insert(other)
        try store.context.save()
        clock.advance(by: 60)

        try store.update(id: todo.id, title: "Edited", note: "survivor note", quadrant: .urgentImportant)

        #expect(other.title == "Edited")
        #expect(other.updatedAt == todo.updatedAt)
        #expect(other.note == "x", "the note wasn't written, so the twin keeps its own")
        #expect(try store.todo(id: todo.id)?.note == "survivor note")
    }

    // MARK: Events

    @Test func identicalEventsAreKeptAndReadOnce() async throws {
        let todo = try store.add(title: "Logged", quadrant: .urgentImportant)
        try store.complete(id: todo.id)
        for event in try store.allEvents() {
            store.context.insert(TodoEvent(record: event.record))
        }
        try store.context.save()
        writes.count = 0

        let result = try await store.removeDuplicates()

        #expect(result.isEmpty)
        #expect(writes.count == 0)
        #expect(try store.events(for: todo.id).compactMap(\.kind) == [.created, .completed])
        #expect(try store.allEvents().count == 2)
        let document = try await StoreMaintenance.exportDocument(
            store.modelContainer, appVersion: nil, exportedAt: clock.now, attachments: nil
        )
        #expect(document.events?.count == 2)
    }

    /// Two events of one id that differ in one stored value.
    enum EventChange: String, CaseIterable, Sendable {
        case date, seq, kind, todoID, fromQuadrant, toQuadrant, previousDue, due

        func apply(to event: TodoEvent) {
            switch self {
            case .date: event.date = event.date.addingTimeInterval(1)
            case .seq: event.seq += 1
            case .kind: event.kindRaw = TodoEventKind.moved.rawValue
            case .todoID: event.todoID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            case .fromQuadrant: event.fromQuadrantRaw = 2
            case .toQuadrant: event.toQuadrantRaw = 3
            case .previousDue: event.previousDue = event.date
            case .due: event.due = event.date.addingTimeInterval(60)
            }
        }
    }

    @Test(arguments: EventChange.allCases)
    func differentEventsResolveToTheSameSurvivorInAnyOrder(_ change: EventChange) async throws {
        let name = change.rawValue
        let base = TodoEvent(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FE")!,
            todoID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
            kind: .created, date: Date(timeIntervalSinceReferenceDate: 800_000_000), to: .urgentImportant, seq: 0
        )
        let other = TodoEvent(record: base.record)
        change.apply(to: other)
        #expect(other.record != base.record)

        let first = try TodoStore.inMemory()
        let second = try TodoStore.inMemory()
        for event in [base, other] { first.context.insert(TodoEvent(record: event.record)) }
        for event in [other, base] { second.context.insert(TodoEvent(record: event.record)) }
        try first.context.save()
        try second.context.save()

        let shownFirst = try first.allEvents().map(\.record)
        #expect(shownFirst.count == 1, "\(name)")
        #expect(shownFirst == (try second.allEvents().map(\.record)), "\(name): reads differ by insertion order")
        let shownFor = try first.events(for: base.todoID).map(\.record) + first.events(for: other.todoID).map(\.record)
        #expect(Set(shownFor) == Set(shownFirst), "\(name): events(for:) must show only the survivor")

        #expect(try await first.removeDuplicates().removedEvents == 1, "\(name)")
        #expect(try await second.removeDuplicates().removedEvents == 1, "\(name)")
        #expect(try first.allEvents().map(\.record) == shownFirst, "\(name)")
        #expect(try second.allEvents().map(\.record) == shownFirst, "\(name)")
    }
}

/// Destructive saves read fresh state right before they delete.
@MainActor
@Suite struct FreshReadBeforeDeleteTests {
    let clock = FakeClock()

    @Test func thePurgeSeesAReopenWrittenThroughAnotherContext() throws {
        let store = try TodoStore.inMemory(now: { clock.now })
        let todo = try store.add(title: "Archived long ago", quadrant: .urgentImportant)
        try store.complete(id: todo.id)
        _ = try store.allTodos() // this store's context has read it as completed
        clock.advance(by: 100 * 24 * 3600)

        // A sync import reopens it (another context writes the row).
        let other = ModelContext(store.modelContainer)
        let id = todo.id
        let row = try #require(try other.fetch(FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })).first)
        row.completedAt = nil
        row.updatedAt = clock.now
        try other.save()

        #expect(try store.purgeArchive(retention: ArchiveRetention(days: 30)) == 0)
        #expect(try store.todo(id: id) != nil)
    }
}
