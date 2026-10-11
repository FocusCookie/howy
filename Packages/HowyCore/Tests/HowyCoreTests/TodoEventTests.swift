import Foundation
import Testing
@testable import HowyCore

/// The append-only event log `TodoStore` writes next to every change (schema v3), and the
/// `updatedAt` stamp every write sets.
@MainActor
@Suite struct TodoEventTests {
    let clock = FakeClock()
    let store: TodoStore
    /// A day after the clock's start; fixed, so advancing the clock doesn't move it.
    let inADay: Date

    init() throws {
        let clock = clock
        store = try TodoStore.inMemory(now: { clock.now })
        inADay = clock.now.addingTimeInterval(86_400)
    }

    /// Optional on purpose: a kind this build can't read must show up as `nil`, not vanish.
    func kinds(_ id: UUID) throws -> [TodoEventKind?] {
        try store.events(for: id).map(\.kind)
    }

    func eventCount() throws -> Int {
        try store.allEvents().count
    }

    func last(_ id: UUID) throws -> TodoEvent {
        try #require(try store.events(for: id).last)
    }

    // MARK: created

    @Test func addRecordsCreatedWithItsQuadrant() throws {
        let todo = try store.add(title: "Pay", quadrant: .notUrgentImportant)
        let events = try store.events(for: todo.id)
        #expect(events.map(\.kind) == [.created])
        let created = try #require(events.first)
        #expect(created.todoID == todo.id)
        #expect(created.date == clock.now)
        #expect(created.toQuadrant == .notUrgentImportant)
        #expect(created.fromQuadrant == nil)
        #expect(created.due == nil)
    }

    @Test func addWithADueDateCarriesItOnTheCreatedEvent() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        #expect(try kinds(todo.id) == [.created])
        #expect(try last(todo.id).due == inADay)
    }

    @Test func importRecordsCreatedAndCompletedAtTheRecordsTimes() throws {
        let created = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let completed = created.addingTimeInterval(3_600)
        let open = TodoRecord(id: UUID(), title: "Open", quadrant: .urgentUnimportant, createdAt: created)
        let done = TodoRecord(id: UUID(), title: "Done", quadrant: .notUrgentUnimportant, createdAt: created, completedAt: completed)
        try store.insert([open, done])

        #expect(try kinds(open.id) == [.created])
        #expect(try store.events(for: open.id).first?.date == created)
        #expect(try store.events(for: open.id).first?.toQuadrant == .urgentUnimportant)
        let doneEvents = try store.events(for: done.id)
        #expect(doneEvents.map(\.kind) == [.created, .completed])
        #expect(doneEvents.map(\.date) == [created, completed])
    }

    @Test func importSkippingExistingIdsRecordsNothingForThem() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        let stamped = todo.updatedAt
        clock.advance(by: 60)
        let inserted = try store.insert([TodoRecord(id: todo.id, title: "Other", quadrant: .notUrgentImportant, createdAt: clock.now)])
        #expect(inserted.isEmpty)
        #expect(try kinds(todo.id) == [.created])
        let kept = try #require(try store.todo(id: todo.id))
        #expect(kept.title == "Pay")
        #expect(kept.quadrant == .urgentImportant)
        #expect(kept.updatedAt == stamped)
    }

    @Test func importWithTheSameIdTwiceInOneBatchRecordsOneCreated() throws {
        let id = UUID()
        let first = TodoRecord(id: id, title: "First", quadrant: .urgentImportant, createdAt: clock.now)
        let second = TodoRecord(id: id, title: "Second", quadrant: .urgentUnimportant, createdAt: clock.now, completedAt: clock.now)
        #expect(try store.insert([first, second]) == [id])
        #expect(try kinds(id) == [.created])
        #expect(try store.allTodos().count == 1)
        #expect(try store.todo(id: id)?.title == "First")
    }

    // MARK: completed / reopened

    @Test func completeRecordsCompleted() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.complete(id: todo.id)
        #expect(try kinds(todo.id) == [.created, .completed])
        #expect(try last(todo.id).date == clock.now)
    }

    @Test func restoreRecordsReopened() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.complete(id: todo.id)
        clock.advance(by: 60)
        try store.restore(id: todo.id, onTop: false)
        #expect(try kinds(todo.id) == [.created, .completed, .reopened])
        #expect(try last(todo.id).date == clock.now)
    }

    // MARK: moved

    @Test func moveRecordsFromAndTo() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.move(id: todo.id, to: .notUrgentUnimportant)
        let moved = try last(todo.id)
        #expect(moved.kind == .moved)
        #expect(moved.fromQuadrant == .urgentImportant)
        #expect(moved.toQuadrant == .notUrgentUnimportant)
        #expect(moved.date == clock.now)
    }

    @Test func moveAtAnIndexInAnotherQuadrantRecordsMoved() throws {
        _ = try store.add(title: "There", quadrant: .notUrgentImportant)
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.move(id: todo.id, to: .notUrgentImportant, at: 1)
        let moved = try last(todo.id)
        #expect(moved.kind == .moved)
        #expect(moved.fromQuadrant == .urgentImportant)
        #expect(moved.toQuadrant == .notUrgentImportant)
    }

    @Test func reorderingWithinAQuadrantRecordsNothing() throws {
        let first = try store.add(title: "A", quadrant: .urgentImportant)
        clock.advance(by: 1)
        let second = try store.add(title: "B", quadrant: .urgentImportant)
        clock.advance(by: 1)
        try store.move(id: first.id, to: .urgentImportant, at: 0)
        clock.advance(by: 1)
        try store.reorder([second.id, first.id], in: .urgentImportant)
        #expect(try kinds(first.id) == [.created])
        #expect(try kinds(second.id) == [.created])
    }

    @Test func moveBackRecordsTheMoveBack() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        let sortDate = try store.move(id: todo.id, to: .urgentUnimportant)
        clock.advance(by: 60)
        try store.moveBack(id: todo.id, to: .urgentImportant, sortDate: sortDate)
        let back = try last(todo.id)
        #expect(try kinds(todo.id) == [.created, .moved, .moved])
        #expect(back.fromQuadrant == .urgentUnimportant)
        #expect(back.toQuadrant == .urgentImportant)
    }

    @Test func updateThatMovesTheQuadrantRecordsMoved() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .notUrgentImportant)
        let moved = try last(todo.id)
        #expect(moved.kind == .moved)
        #expect(moved.fromQuadrant == .urgentImportant)
        #expect(moved.toQuadrant == .notUrgentImportant)
    }

    // MARK: due

    @Test func setDueOnATodoWithoutOneRecordsDueSet() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.setDue(id: todo.id, to: inADay)
        let event = try last(todo.id)
        #expect(event.kind == .dueSet)
        #expect(event.previousDue == nil)
        #expect(event.due == inADay)
    }

    @Test func setDueOnADatedTodoRecordsDueChanged() throws {
        let before = clock.now
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: before)
        clock.advance(by: 60)
        try store.setDue(id: todo.id, to: inADay)
        let event = try last(todo.id)
        #expect(event.kind == .dueChanged)
        #expect(event.previousDue == before)
        #expect(event.due == inADay)
    }

    @Test func clearDueRecordsDueRemoved() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        clock.advance(by: 60)
        try store.clearDue(id: todo.id)
        let event = try last(todo.id)
        #expect(event.kind == .dueRemoved)
        #expect(event.previousDue == inADay)
        #expect(event.due == nil)
    }

    @Test func snoozeByAnIntervalRecordsDueSnoozed() throws {
        let before = clock.now
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: before)
        clock.advance(by: 60)
        try store.snooze(id: todo.id, by: 3_600)
        let event = try last(todo.id)
        #expect(event.kind == .dueSnoozed)
        #expect(event.previousDue == before)
        #expect(event.due == clock.now.addingTimeInterval(3_600))
    }

    @Test func snoozeUntilADateRecordsDueSnoozed() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: clock.now)
        clock.advance(by: 60)
        try store.snooze(id: todo.id, until: inADay)
        #expect(try last(todo.id).kind == .dueSnoozed)
        #expect(try last(todo.id).due == inADay)
    }

    @Test func snoozingATodoWithoutADueDateRecordsDueSet() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.snooze(id: todo.id, by: 3_600)
        let event = try last(todo.id)
        #expect(event.kind == .dueSet)
        #expect(event.previousDue == nil)
        #expect(event.due == clock.now.addingTimeInterval(3_600))
        try store.clearDue(id: todo.id)
        try store.snooze(id: todo.id, until: inADay)
        #expect(try last(todo.id).kind == .dueSet)
    }

    @Test func updateThatChangesTheDueDateRecordsIt() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant, due: inADay)
        #expect(try last(todo.id).kind == .dueSet)
        clock.advance(by: 60)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant, due: nil)
        #expect(try last(todo.id).kind == .dueRemoved)
    }

    @Test func updateThatChangesOneDueDateToAnotherRecordsDueChanged() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        clock.advance(by: 60)
        let later = inADay.addingTimeInterval(3_600)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant, due: later)
        let event = try last(todo.id)
        #expect(event.kind == .dueChanged)
        #expect(event.previousDue == inADay)
        #expect(event.due == later)
    }

    @Test func updateThatMovesAndRedatesRecordsBoth() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentUnimportant, due: inADay)
        let events = try store.events(for: todo.id)
        #expect(events.count == 3)
        #expect(events.first?.kind == .created)
        let moved = try #require(events.first { $0.kind == .moved })
        #expect(moved.fromQuadrant == .urgentImportant)
        #expect(moved.toQuadrant == .urgentUnimportant)
        let dated = try #require(events.first { $0.kind == .dueSet })
        #expect(dated.previousDue == nil)
        #expect(dated.due == inADay)
    }

    // MARK: deleted

    @Test func deleteRecordsDeletedAndKeepsTheHistory() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.delete(id: todo.id)
        #expect(try store.todo(id: todo.id) == nil)
        let events = try store.events(for: todo.id)
        #expect(events.map(\.kind) == [.created, .deleted])
        #expect(events.last?.fromQuadrant == .urgentImportant)
        #expect(events.last?.date == clock.now)
    }

    @Test func deletingAnArchivedTodoRecordsDeleted() throws {
        let todo = try store.add(title: "Pay", quadrant: .notUrgentImportant)
        clock.advance(by: 60)
        try store.complete(id: todo.id)
        clock.advance(by: 60)
        try store.delete(id: todo.id)
        #expect(try kinds(todo.id) == [.created, .completed, .deleted])
        #expect(try last(todo.id).fromQuadrant == .notUrgentImportant)
    }

    @Test func purgingTheArchiveKeepsTheEvents() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.complete(id: todo.id)
        clock.advance(by: ArchiveRetention.default.interval + 1)
        #expect(try store.purgeArchive() == 1)
        #expect(try kinds(todo.id) == [.created, .completed])
    }

    // MARK: no-ops

    @Test func titleAndNoteEditsRecordNothing() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        try store.update(id: todo.id, title: "Pay now", note: "**soon**", quadrant: .urgentImportant)
        #expect(try kinds(todo.id) == [.created])
    }

    @Test func allEventsListsEveryTodosEventsOldestFirst() throws {
        let first = try store.add(title: "A", quadrant: .urgentImportant)
        clock.advance(by: 1)
        let second = try store.add(title: "B", quadrant: .urgentImportant)
        clock.advance(by: 1)
        try store.complete(id: first.id)
        let all = try store.allEvents()
        #expect(all.map(\.todoID) == [first.id, second.id, first.id])
        #expect(all.map(\.kind) == [.created, .created, .completed])
    }

    // MARK: updatedAt

    @Test func addStampsUpdatedAt() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        #expect(todo.updatedAt == clock.now)
    }

    @Test func everyWriteStampsUpdatedAt() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        let id = todo.id
        let steps: [(String, () throws -> Void)] = [
            ("update", { try store.update(id: id, title: "Pay now", note: "", quadrant: .urgentImportant) }),
            ("setDue", { try store.setDue(id: id, to: inADay) }),
            ("snooze", { try store.snooze(id: id, by: 60) }),
            ("clearDue", { try store.clearDue(id: id) }),
            ("move", { try store.move(id: id, to: .notUrgentImportant) }),
            ("move at", { try store.move(id: id, to: .urgentImportant, at: 0) }),
            ("moveBack", { try store.moveBack(id: id, to: .notUrgentImportant, sortDate: .distantPast) }),
            ("complete", { try store.complete(id: id) }),
            ("restore", { try store.restore(id: id) }),
        ]
        for (name, step) in steps {
            clock.advance(by: 10)
            try step()
            #expect(try store.todo(id: id)?.updatedAt == clock.now, "\(name)")
        }
    }

    @Test func reorderStampsTheTodosItRewrites() throws {
        let first = try store.add(title: "A", quadrant: .urgentImportant)
        clock.advance(by: 1)
        let second = try store.add(title: "B", quadrant: .urgentImportant)
        clock.advance(by: 10)
        try store.reorder([first.id, second.id], in: .urgentImportant)
        #expect(try store.todo(id: first.id)?.updatedAt == clock.now)
        #expect(try store.todo(id: second.id)?.updatedAt == clock.now) // shifted down by the new order
    }

    @Test func moveAtAnIndexStampsTheShiftedTodosToo() throws {
        let there = try store.add(title: "There", quadrant: .notUrgentImportant)
        clock.advance(by: 1)
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 10)
        try store.move(id: todo.id, to: .notUrgentImportant, at: 0)
        #expect(try store.todo(id: todo.id)?.updatedAt == clock.now)
        #expect(try store.todo(id: there.id)?.updatedAt == clock.now)
        #expect(try kinds(there.id) == [.created]) // shifted, not moved: no event
    }

    @Test func importStampsUpdatedAtWithTheClock() throws {
        let record = TodoRecord(id: UUID(), title: "Old", quadrant: .urgentImportant, createdAt: .distantPast)
        try store.insert([record])
        #expect(try store.todo(id: record.id)?.updatedAt == clock.now)
    }

    @Test func noOpWritesLeaveUpdatedAtAlone() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        let stamped = clock.now
        clock.advance(by: 10)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant)
        try store.move(id: todo.id, to: .urgentImportant)
        try store.restore(id: todo.id)
        #expect(try store.todo(id: todo.id)?.updatedAt == stamped)
    }

    // MARK: no-ops

    enum NoOp: String, CaseIterable, CustomTestStringConvertible {
        case clearDueOnAnUndatedTodo, snoozeToTheIdenticalDate, moveBackToTheSameQuadrantAndSortDate
        case restoreAnOpenTodo, unchangedReorder
        var testDescription: String { rawValue }
    }

    @Test(arguments: NoOp.allCases)
    func aNoOpRecordsNoEventAndLeavesUpdatedAtAlone(_ noOp: NoOp) throws {
        let dated = try store.add(title: "Dated", quadrant: .urgentImportant, due: inADay)
        clock.advance(by: 1)
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        let stamped = [dated.updatedAt, todo.updatedAt]
        let events = try eventCount()
        clock.advance(by: 60)

        switch noOp {
        case .clearDueOnAnUndatedTodo: try store.clearDue(id: todo.id)
        case .snoozeToTheIdenticalDate: try store.snooze(id: dated.id, until: inADay)
        case .moveBackToTheSameQuadrantAndSortDate:
            try store.moveBack(id: todo.id, to: .urgentImportant, sortDate: todo.sortDate)
        case .restoreAnOpenTodo: try store.restore(id: todo.id)
        case .unchangedReorder: try store.reorder([todo.id, dated.id], in: .urgentImportant)
        }

        #expect(try eventCount() == events)
        #expect([dated.updatedAt, todo.updatedAt] == stamped)
    }

    @Test func movingToTheTodosOwnQuadrantRecordsNothing() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        let stamped = todo.updatedAt
        clock.advance(by: 60)
        try store.move(id: todo.id, to: .urgentImportant)
        try store.move(id: todo.id, to: .urgentImportant, at: 0)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant)
        try store.setDue(id: todo.id, to: nil)
        try store.insert([])
        #expect(try kinds(todo.id) == [.created])
        #expect(todo.updatedAt == stamped)
    }

    @Test func completingTwiceRecordsOneCompleted() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        clock.advance(by: 60)
        try store.complete(id: todo.id)
        clock.advance(by: 60)
        try store.complete(id: todo.id)
        #expect(try kinds(todo.id) == [.created, .completed])
    }

    // MARK: errors

    @Test func failedWritesRecordNothing() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        let events = try eventCount()
        let unknown = UUID()
        #expect(throws: TodoStoreError.notFound(unknown)) {
            try store.update(id: unknown, title: "x", note: "", quadrant: .urgentImportant)
        }
        #expect(throws: TodoStoreError.notFound(unknown)) { try store.delete(id: unknown) }
        #expect(throws: TodoStoreError.emptyTitle) { try store.add(title: "  ", quadrant: .urgentImportant) }
        #expect(throws: TodoStoreError.emptyTitle) {
            try store.update(id: todo.id, title: " ", note: "", quadrant: .notUrgentImportant, due: inADay)
        }
        #expect(throws: TodoStoreError.emptyTitle) {
            try store.insert([TodoRecord(id: UUID(), title: "", quadrant: .urgentImportant, createdAt: clock.now)])
        }
        #expect(try eventCount() == events)
        #expect(try store.allTodos().count == 1)
    }

    // MARK: ordering at one instant

    @Test func completeRestoreCompleteAtOneInstantReadsInOrder() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        try store.complete(id: todo.id)
        try store.restore(id: todo.id, onTop: false)
        try store.complete(id: todo.id)
        #expect(try kinds(todo.id) == [.created, .completed, .reopened, .completed])
        #expect(try store.events(for: todo.id).map(\.seq) == [0, 1, 2, 3])
        #expect(Set(try store.events(for: todo.id).map(\.date)).count == 1)
    }

    @Test func moveThenMoveBackAtOneInstantReadsInOrder() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        let sortDate = try store.move(id: todo.id, to: .notUrgentImportant)
        try store.moveBack(id: todo.id, to: .urgentImportant, sortDate: sortDate)
        let events = try store.events(for: todo.id)
        #expect(events.map(\.kind) == [.created, .moved, .moved])
        #expect(events[1].fromQuadrant == .urgentImportant)
        #expect(events[1].toQuadrant == .notUrgentImportant)
        #expect(events[2].fromQuadrant == .notUrgentImportant)
        #expect(events[2].toQuadrant == .urgentImportant)
        #expect(try store.allEvents().map(\.seq) == [0, 1, 2])
    }

    @Test func seqCountsPerTodo() throws {
        let first = try store.add(title: "A", quadrant: .urgentImportant)
        let second = try store.add(title: "B", quadrant: .urgentImportant)
        try store.complete(id: first.id)
        #expect(try store.events(for: first.id).map(\.seq) == [0, 1])
        #expect(try store.events(for: second.id).map(\.seq) == [0])
    }

    // MARK: one timestamp per write

    /// A clock that moves on a second every time it is read.
    final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var now: Date { lock.withLock { current = current.addingTimeInterval(1); return current } }
    }

    @Test func aWriteUsesOneTimestampThroughout() throws {
        let ticking = TickingClock()
        let store = try TodoStore.inMemory(now: { ticking.now })
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        #expect(todo.createdAt == todo.sortDate)
        #expect(todo.createdAt == todo.updatedAt)
        #expect(try store.events(for: todo.id).last?.date == todo.createdAt)

        try store.complete(id: todo.id)
        #expect(todo.completedAt == todo.updatedAt)
        #expect(try store.events(for: todo.id).last?.date == todo.completedAt)

        try store.restore(id: todo.id)
        #expect(todo.sortDate == todo.updatedAt)
        #expect(try store.events(for: todo.id).last?.date == todo.updatedAt)

        try store.move(id: todo.id, to: .notUrgentImportant)
        #expect(todo.sortDate == todo.updatedAt)
        #expect(try store.events(for: todo.id).last?.date == todo.updatedAt)

        try store.snooze(id: todo.id, by: 100)
        let snoozed = try #require(try store.events(for: todo.id).last)
        #expect(snoozed.date == todo.updatedAt)
        #expect(todo.due == snoozed.date.addingTimeInterval(100))

        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant, due: nil)
        let events = try store.events(for: todo.id)
        let tail = events.suffix(2)
        #expect(tail.map(\.date) == [todo.updatedAt, todo.updatedAt])
        #expect(todo.sortDate == todo.updatedAt)
    }

    // MARK: duplicate ids

    /// Schema v3 has no unique constraint, so two rows can share an id (e.g. after a sync).
    func insertDuplicates(quadrant: Quadrant = .urgentImportant) throws -> UUID {
        let id = UUID()
        for offset in 0..<2 {
            store.context.insert(Todo(
                id: id, title: "Twin", quadrant: quadrant,
                createdAt: clock.now.addingTimeInterval(Double(offset))
            ))
        }
        try store.context.save()
        return id
    }

    @Test func reorderSurvivesDuplicateIds() throws {
        let id = try insertDuplicates()
        let other = try store.add(title: "Other", quadrant: .urgentImportant)
        clock.advance(by: 10)
        try store.reorder([id, other.id], in: .urgentImportant)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [id, other.id], "the duplicate pair reads as one todo")
    }

    @Test func deleteRemovesEveryRowWithTheIdAndRecordsOneDeleted() throws {
        let id = try insertDuplicates(quadrant: .notUrgentUnimportant)
        #expect(try store.todos(id: id).count == 2)
        #expect(try store.allTodos().count == 1)
        try store.delete(id: id)
        #expect(try store.allTodos().isEmpty)
        let events = try store.events(for: id)
        #expect(events.map(\.kind) == [.deleted])
        #expect(events.first?.fromQuadrant == .notUrgentUnimportant)
    }

    // MARK: on disk

    func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "howy-events-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appending(path: "Howy.store"))
    }

    @Test func eventsOfADeletedTodoSurviveReopening() throws {
        try withTemporaryDirectory { url in
            let clock = FakeClock()
            let id: UUID
            do {
                let disk = try TodoStore.onDisk(url: url, now: { clock.now })
                id = try disk.add(title: "Pay", quadrant: .urgentImportant).id
                clock.advance(by: 60)
                try disk.delete(id: id)
            }
            let reopened = try TodoStore.onDisk(url: url, now: { clock.now })
            #expect(try reopened.todo(id: id) == nil)
            #expect(try reopened.events(for: id).map(\.kind) == [.created, .deleted])
        }
    }

    @Test func purgingKeepsTheEventsOfOpenFreshAndExpiredTodos() throws {
        try withTemporaryDirectory { url in
            let clock = FakeClock()
            do {
                let disk = try TodoStore.onDisk(url: url, now: { clock.now })
                let expired = try disk.add(title: "Old", quadrant: .urgentImportant)
                try disk.complete(id: expired.id)
                clock.advance(by: ArchiveRetention.default.interval + 60)
                let fresh = try disk.add(title: "Fresh", quadrant: .urgentImportant)
                try disk.complete(id: fresh.id)
                try disk.add(title: "Open", quadrant: .urgentImportant)
                #expect(try disk.purgeArchive() == 1)
                #expect(try disk.allTodos().count == 2)
                #expect(try disk.allEvents().count == 5)
            }
            let reopened = try TodoStore.onDisk(url: url, now: { clock.now })
            #expect(try reopened.allTodos().count == 2)
            #expect(try reopened.allEvents().count == 5)
        }
    }
}
