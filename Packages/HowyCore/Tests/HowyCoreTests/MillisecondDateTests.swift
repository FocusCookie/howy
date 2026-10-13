import Foundation
import Testing
@testable import HowyCore

/// Dates are stored at whole milliseconds since 1970 (CloudKit's epoch and precision), and
/// compared by that millisecond, so a row that made a round trip through CloudKit is the same
/// row as the local original.
@MainActor
@Suite final class MillisecondDateTests {
    /// A date as CloudKit hands it back: whole milliseconds since 1970, cut by `convert`.
    static func roundTripped(_ date: Date, _ convert: (Double) -> Double) -> Date {
        let milliseconds = Int64(convert(date.timeIntervalSince1970 * 1000))
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    static func randomDates(count: Int) -> [Date] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in
            // 2001 to 2040, with a random fraction of a millisecond.
            Date(timeIntervalSinceReferenceDate: Double.random(in: 0..<1_200_000_000, using: &generator))
        }
    }

    @Test func aQuantizedDateKeepsItsKeyThroughARoundTrip() {
        for date in Self.randomDates(count: 5000) {
            let stored = date.wholeMilliseconds
            let key = DuplicateRules.milliseconds(stored)
            #expect(stored.wholeMilliseconds == stored, "quantizing twice changes nothing")
            #expect(abs(stored.timeIntervalSince(date)) <= 0.0005 + 1e-6)
            for (name, convert) in [("rounding", { (x: Double) in x.rounded() }), ("truncating", { (x: Double) in x.rounded(.down) })] as [(String, (Double) -> Double)] {
                let back = Self.roundTripped(stored, convert)
                #expect(DuplicateRules.milliseconds(back) == key, "\(name) round trip of \(stored.timeIntervalSince1970)")
            }
        }
    }

    @Test func dateKeysIgnoreSubMillisecondNoise() {
        let base = Date(timeIntervalSince1970: 1_780_000_000.123)
        for noise in [-0.0004, -0.0001, 0, 0.0001, 0.0004] {
            #expect(DuplicateRules.milliseconds(base.addingTimeInterval(noise)) == 1_780_000_000_123)
        }
        #expect(DuplicateRules.milliseconds(base.addingTimeInterval(0.0006)) == 1_780_000_000_124)
    }

    @Test func everyDateTheStoreWritesIsWholeMilliseconds() throws {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 800_000_000.0004))
        let store = try TodoStore.inMemory(now: { clock.now })
        let fraction = 0.0003
        let due = clock.now.addingTimeInterval(3600 + fraction)
        let first = try store.add(title: "A", quadrant: .urgentImportant, due: due)
        let second = try store.add(title: "B", quadrant: .urgentImportant)
        let third = try store.add(title: "C", quadrant: .urgentImportant)
        clock.advance(by: 1.0007)
        try store.reorder([first.id, second.id, third.id], in: .urgentImportant)
        try store.snooze(id: first.id, by: 600.0004)
        try store.setDue(id: second.id, to: due.addingTimeInterval(0.00049))
        try store.move(id: third.id, to: .urgentImportant, at: 0)
        try store.move(id: third.id, to: .notUrgentImportant)
        try store.moveBack(id: third.id, to: .urgentImportant, sortDate: clock.now.addingTimeInterval(0.00033))
        try store.complete(id: first.id)

        func whole(_ date: Date?) -> Bool { date.map { $0 == $0.wholeMilliseconds } ?? true }
        for todo in try store.allTodos() {
            #expect([todo.createdAt, todo.sortDate, todo.updatedAt].allSatisfy(whole))
            #expect(whole(todo.due) && whole(todo.completedAt))
        }
        for event in try store.allEvents() {
            #expect(whole(event.date) && whole(event.previousDue) && whole(event.due))
        }
        #expect(try store.allEvents().count > 5)
    }

    @Test func anImportQuantizesTodosAndEvents() throws {
        let store = try TodoStore.inMemory()
        let noisy = Date(timeIntervalSince1970: 1_780_000_000.1234567)
        let id = UUID()
        try store.insert(
            [TodoRecord(id: id, title: "Imported", quadrant: .urgentImportant, createdAt: noisy, completedAt: noisy, due: noisy)],
            events: [TodoEventRecord(id: UUID(), todoID: id, kindRaw: "dueSet", date: noisy, previousDue: noisy, due: noisy)]
        )
        let todo = try #require(try store.todo(id: id))
        #expect([todo.createdAt, todo.sortDate, todo.updatedAt, todo.completedAt, todo.due].allSatisfy { $0 == $0?.wholeMilliseconds })
        #expect(todo.createdAt == Date(timeIntervalSince1970: 1_780_000_000.123))
        let events = try store.events(for: id)
        #expect(events.allSatisfy { $0.date == $0.date.wholeMilliseconds && $0.due == $0.due.wholeMilliseconds })
    }

    @Test func aTwinThatWentThroughARoundTripSurvivesTheCleanup() async throws {
        let clock = FakeClock(Date(timeIntervalSinceReferenceDate: 800_000_000.0004))
        let store = try TodoStore.inMemory(now: { clock.now })
        let todo = try store.add(title: "Twin", note: "n", quadrant: .urgentImportant, due: clock.now.addingTimeInterval(77.0003))
        try store.complete(id: todo.id)
        let local = try #require(try store.todo(id: todo.id))

        // The same row as CloudKit would return it: every date on its whole-millisecond grid
        // again, however the conversion cut it, and a float-noisy date for good measure.
        func back(_ date: Date) -> Date { Self.roundTripped(date) { $0.rounded() } }
        let remote = Todo(
            id: local.id, title: local.title, note: local.note, quadrant: local.quadrant,
            createdAt: back(local.createdAt), sortDate: back(local.sortDate),
            completedAt: back(try #require(local.completedAt)),
            due: back(try #require(local.due)).addingTimeInterval(0.00002), updatedAt: back(local.updatedAt)
        )
        store.context.insert(remote)
        for event in try store.allEvents() {
            store.context.insert(TodoEvent(
                id: event.id, todoID: event.todoID, kind: event.kind ?? .created, date: back(event.date),
                from: event.fromQuadrant, to: event.toQuadrant, previousDue: event.previousDue.map(back),
                due: event.due.map(back), seq: event.seq
            ))
        }
        try store.context.save()

        #expect(local.duplicateKey == remote.duplicateKey)
        #expect(try await store.removeDuplicates().isEmpty)
        #expect(try store.todos(id: todo.id).count == 2)
        #expect(try store.allEvents().count == 2) // created, completed: one each, though stored twice
    }
}
