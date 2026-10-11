import Foundation
import Testing
@testable import HowyCore

/// The append-only event log `TodoStore` writes next to every change (schema v3), and the
/// `updatedAt` stamp every write sets.
@MainActor
@Suite struct TodoEventTests {
    let clock = FakeClock()
    let store: TodoStore

    init() throws {
        let clock = clock
        store = try TodoStore.inMemory(now: { clock.now })
    }

    var inADay: Date { clock.now.addingTimeInterval(86_400) }

    func kinds(_ id: UUID) throws -> [TodoEventKind] {
        try store.events(for: id).compactMap(\.kind)
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
        try store.insert([TodoRecord(id: todo.id, title: "Other", quadrant: .notUrgentImportant, createdAt: clock.now)])
        #expect(try kinds(todo.id) == [.created])
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
        try store.move(id: first.id, to: .urgentImportant, at: 0)
        try store.reorder([second.id, first.id], in: .urgentImportant)
        #expect(try kinds(first.id) == [.created])
        #expect(try kinds(second.id) == [.created])
    }

    @Test func moveBackRecordsTheMoveBack() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        let sortDate = try store.move(id: todo.id, to: .urgentUnimportant)
        try store.moveBack(id: todo.id, to: .urgentImportant, sortDate: sortDate)
        let back = try last(todo.id)
        #expect(try kinds(todo.id) == [.created, .moved, .moved])
        #expect(back.fromQuadrant == .urgentUnimportant)
        #expect(back.toQuadrant == .urgentImportant)
    }

    @Test func updateThatMovesTheQuadrantRecordsMoved() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .notUrgentImportant)
        let moved = try last(todo.id)
        #expect(moved.kind == .moved)
        #expect(moved.fromQuadrant == .urgentImportant)
        #expect(moved.toQuadrant == .notUrgentImportant)
    }

    // MARK: due

    @Test func setDueOnATodoWithoutOneRecordsDueSet() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        try store.setDue(id: todo.id, to: inADay)
        let event = try last(todo.id)
        #expect(event.kind == .dueSet)
        #expect(event.previousDue == nil)
        #expect(event.due == inADay)
    }

    @Test func setDueOnADatedTodoRecordsDueChanged() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: clock.now)
        try store.setDue(id: todo.id, to: inADay)
        let event = try last(todo.id)
        #expect(event.kind == .dueChanged)
        #expect(event.previousDue == clock.now)
        #expect(event.due == inADay)
    }

    @Test func clearDueRecordsDueRemoved() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        try store.clearDue(id: todo.id)
        let event = try last(todo.id)
        #expect(event.kind == .dueRemoved)
        #expect(event.previousDue == inADay)
        #expect(event.due == nil)
    }

    @Test func snoozeByAnIntervalRecordsDueSnoozed() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: clock.now)
        try store.snooze(id: todo.id, by: 3_600)
        let event = try last(todo.id)
        #expect(event.kind == .dueSnoozed)
        #expect(event.previousDue == clock.now)
        #expect(event.due == clock.now.addingTimeInterval(3_600))
    }

    @Test func snoozeUntilADateRecordsDueSnoozed() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: clock.now)
        try store.snooze(id: todo.id, until: inADay)
        #expect(try last(todo.id).kind == .dueSnoozed)
        #expect(try last(todo.id).due == inADay)
    }

    @Test func updateThatChangesTheDueDateRecordsIt() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant, due: inADay)
        #expect(try last(todo.id).kind == .dueSet)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant, due: nil)
        #expect(try last(todo.id).kind == .dueRemoved)
    }

    @Test func updateThatMovesAndRedatesRecordsBoth() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentUnimportant, due: inADay)
        #expect(Set(try kinds(todo.id)) == [.created, .moved, .dueSet])
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

    @Test func purgingTheArchiveKeepsTheEvents() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        try store.complete(id: todo.id)
        clock.advance(by: ArchiveRetention.default.interval + 1)
        #expect(try store.purgeArchive() == 1)
        #expect(try kinds(todo.id) == [.created, .completed])
    }

    // MARK: no-ops

    @Test func noOpWritesRecordNothing() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant)
        try store.setDue(id: todo.id, to: inADay)
        try store.move(id: todo.id, to: .urgentImportant)
        try store.move(id: todo.id, to: .urgentImportant, at: 0)
        try store.restore(id: todo.id)
        try store.complete(id: todo.id)
        try store.complete(id: todo.id)
        try store.insert([])
        #expect(try kinds(todo.id) == [.created, .completed])
    }

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
}
