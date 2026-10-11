import Foundation
import Testing
@testable import HowyCore

@Suite struct NotificationPlanTests {
    let now = DueFixture.wednesday // Wed 7 Oct 2026, 10:00
    let format = DueFormat(calendar: DueFixture.calendar)

    func todo(_ title: String, _ quadrant: Quadrant = .urgentImportant, due: Date?) -> TodoSnapshot {
        TodoSnapshot(id: UUID(), title: title, quadrant: quadrant, due: due)
    }

    func plan(_ todos: [TodoSnapshot], shown: Set<DueKey> = []) -> [NotificationRequest] {
        NotificationPlan.requests(for: todos, now: now, shown: shown, format: format)
    }

    @Test func aFutureDueDateFiresAtThatMoment() throws {
        let due = DueFixture.date("2026-10-08 09:00")
        let taxes = todo("Submit tax return", .urgentImportant, due: due)
        let request = try #require(plan([taxes]).first)
        #expect(request.identifier == NotificationPlan.identifier(for: taxes.id))
        #expect(request.todoID == taxes.id)
        #expect(request.fireDate == due)
        #expect(request.key == DueKey(id: taxes.id, due: due))
        #expect(request.title == "Submit tax return")
        #expect(request.body == "Due now · Urgent & Important")
    }

    @Test func identifiersAreStablePerTodo() {
        let id = UUID()
        #expect(NotificationPlan.identifier(for: id) == NotificationPlan.identifier(for: id))
        #expect(NotificationPlan.todoID(fromIdentifier: NotificationPlan.identifier(for: id)) == id)
        #expect(NotificationPlan.todoID(fromIdentifier: "something-else") == nil)
    }

    @Test func todosWithoutADueDateGetNothing() {
        #expect(plan([todo("Undated", due: nil)]).isEmpty)
    }

    @Test func anOverdueTodoThatNeverNotifiedFiresRightAway() throws {
        let due = DueFixture.date("2026-10-07 08:00")
        let late = todo("Call the landlord", .notUrgentImportant, due: due)
        let request = try #require(plan([late]).first)
        #expect(request.fireDate == nil, "immediately")
        #expect(request.body == "Was due Wed 7 Oct 2026, 08:00 · Not Urgent & Important")
    }

    @Test func anOverdueTodoThatAlreadyNotifiedGetsNothing() {
        let due = DueFixture.date("2026-10-07 08:00")
        let late = todo("Call", due: due)
        #expect(plan([late], shown: [DueKey(id: late.id, due: due)]).isEmpty)
    }

    @Test func aChangedDateIsANewKeySoItNotifiesAgain() throws {
        let late = todo("Call", due: DueFixture.date("2026-10-07 09:00"))
        let shownEarlier: Set<DueKey> = [DueKey(id: late.id, due: DueFixture.date("2026-10-06 09:00"))]
        #expect(plan([late], shown: shownEarlier).count == 1)
    }

    @Test func requestsAreEarliestFirstAndCapped() {
        let todos = (0..<70).map { i in todo("T\(i)", due: now.addingTimeInterval(Double(70 - i) * 60)) }
        let requests = plan(todos)
        #expect(requests.count == NotificationPlan.limit)
        #expect(requests.map(\.fireDate) == requests.map(\.fireDate).sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) })
        #expect(requests.first?.title == "T69")
    }

    @Test func immediateOnesComeFirst() {
        let soon = todo("Soon", due: now.addingTimeInterval(60))
        let late = todo("Late", due: now.addingTimeInterval(-60))
        #expect(plan([soon, late]).map(\.title) == ["Late", "Soon"])
    }

    // MARK: What was shown

    @Test func aScheduledKeyWhoseMomentPassedAndIsNoLongerPendingWasShown() {
        let id = UUID(), other = UUID(), future = UUID()
        let passed = DueFixture.date("2026-10-07 09:00")
        let scheduled: Set<DueKey> = [
            DueKey(id: id, due: passed),
            DueKey(id: other, due: passed),
            DueKey(id: future, due: DueFixture.date("2026-10-08 09:00")),
        ]
        let pending: [String: Date] = [NotificationPlan.identifier(for: other): passed]
        #expect(NotificationPlan.shown(scheduled: scheduled, pending: pending, now: now) == [DueKey(id: id, due: passed)])
    }

    // MARK: Diff

    @Test func theDiffAddsNewAndChangedAndRemovesStale() {
        let keep = todo("Keep", due: DueFixture.date("2026-10-08 09:00"))
        let moved = todo("Moved", due: DueFixture.date("2026-10-09 09:00"))
        let fresh = todo("Fresh", due: DueFixture.date("2026-10-10 09:00"))
        let planned = plan([keep, moved, fresh])
        let gone = UUID()
        let pending: [String: Date] = [
            NotificationPlan.identifier(for: keep.id): DueFixture.date("2026-10-08 09:00"),
            NotificationPlan.identifier(for: moved.id): DueFixture.date("2026-10-08 18:00"),
            NotificationPlan.identifier(for: gone): DueFixture.date("2026-10-08 18:00"),
        ]
        let diff = NotificationPlan.diff(planned: planned, pending: pending)
        #expect(Set(diff.add.map(\.title)) == ["Moved", "Fresh"])
        #expect(diff.remove == [NotificationPlan.identifier(for: gone)])
    }

    @Test func anImmediateRequestReplacesAPendingOneThatMissedItsMoment() {
        let late = todo("Late", due: DueFixture.date("2026-10-07 09:00"))
        let pending: [String: Date] = [NotificationPlan.identifier(for: late.id): DueFixture.date("2026-10-07 09:00")]
        let diff = NotificationPlan.diff(planned: plan([late]), pending: pending)
        #expect(diff.add.map(\.title) == ["Late"])
        #expect(diff.remove.isEmpty)
    }

    @Test func doneTodosArentPlannedSoTheirRequestIsRemoved() {
        let id = UUID()
        let pending: [String: Date] = [NotificationPlan.identifier(for: id): DueFixture.date("2026-10-08 09:00")]
        let diff = NotificationPlan.diff(planned: plan([]), pending: pending)
        #expect(diff.remove == [NotificationPlan.identifier(for: id)])
    }

    // MARK: Actions

    @Test func tomorrowAtTheDefaultTime() {
        let date = NotificationPlan.tomorrow(at: DueTime(hour: 9, minute: 0), now: now, calendar: DueFixture.calendar)
        #expect(DueFixture.text(date) == "2026-10-08 09:00")
    }

    @Test func snoozeIsAnHour() {
        #expect(NotificationPlan.snoozeInterval == 3600)
    }
}
