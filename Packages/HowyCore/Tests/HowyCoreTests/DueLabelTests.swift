import Foundation
import Testing
@testable import HowyCore

@Suite struct DueLabelTests {
    static let now = DueFixture.wednesday // Wed 7 Oct 2026, 10:00

    static func format() -> DueFormat { DueFormat(calendar: DueFixture.calendar) }

    @Test(arguments: [
        ("2026-10-07 10:25", "in 25 min"),
        ("2026-10-07 10:00", "Overdue · 1 min"),
        ("2026-10-07 10:59", "in 59 min"),
        ("2026-10-07 16:00", "16:00"),
        ("2026-10-07 23:59", "23:59"),
        ("2026-10-08 10:00", "Tomorrow 10:00"),
        ("2026-10-08 00:30", "Tomorrow 00:30"),
        ("2026-10-09 10:00", "Fri 10:00"),
        ("2026-10-13 09:00", "Tue 09:00"),
        ("2026-10-14 09:00", "14 Oct"),
        ("2026-10-21 09:00", "21 Oct"),
        ("2027-01-03 09:00", "3 Jan"),
        ("2026-10-07 08:00", "Overdue · 2 h"),
        ("2026-10-07 09:50", "Overdue · 10 min"),
        ("2026-10-05 10:00", "Overdue · 2 days"),
        ("2026-10-06 09:00", "Overdue · 1 day"),
    ])
    func shortLabel(due: String, label: String) {
        #expect(Self.format().short(DueFixture.date(due), now: Self.now) == label, "\(due)")
    }

    @Test func longLabel() {
        #expect(Self.format().long(DueFixture.date("2026-10-16 10:00")) == "Fri 16 Oct 2026, 10:00")
        #expect(Self.format().long(DueFixture.date("2027-01-03 09:05")) == "Sun 3 Jan 2027, 09:05")
    }

    @Test(arguments: [
        ("2026-10-07 10:30", "in 30 min"),
        ("2026-10-07 22:00", "in 12 h"),
        ("2026-10-16 10:00", "in 9 days"),
        ("2026-10-08 09:00", "in 23 h"),
        ("2026-10-09 09:00", "in 2 days"),
        ("2026-10-07 08:00", "2 h ago"),
    ])
    func relative(due: String, text: String) {
        #expect(Self.format().relative(DueFixture.date(due), now: Self.now) == text)
    }

    @Test func previewOfAParsedPhrase() {
        let format = Self.format()
        let outcome = DueFixture.parse("tomorrow", now: Self.now)
        #expect(format.preview(outcome, now: Self.now) == .ok("→ Thu 8 Oct 2026, 09:00", detail: "in 23 h · no time → 9:00"))
        #expect(format.preview(DueFixture.parse("xyz", now: Self.now), now: Self.now) == .error("Didn't understand “xyz”"))
        #expect(format.preview(.empty, now: Self.now) == .idle("Type when it's due"))
    }

    @Test(arguments: [
        (nil as String?, DueState.none),
        ("2026-10-07 10:01", .upcoming),
        ("2026-10-07 10:00", .overdue),
        ("2026-10-01 10:00", .overdue),
    ])
    func state(due: String?, state: DueState) {
        #expect(DueState(due: due.map(DueFixture.date), now: Self.now) == state)
    }
}
