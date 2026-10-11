import Foundation
import Testing
@testable import HowyCore

/// Fixed calendar and moments for the due-date tests (Europe/Berlin, Gregorian).
enum DueFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    static func date(_ text: String) -> Date {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).map { Int($0)! }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]
        ))!
    }

    static func text(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    /// Wednesday 7 October 2026, 10:00.
    static let wednesday = date("2026-10-07 10:00")
    /// Friday 9 October 2026, 14:00.
    static let friday = date("2026-10-09 14:00")

    static func parse(_ input: String, now: Date, defaultTime: DueTime = .nine) -> DueDateParser.Outcome {
        DueDateParser.parse(input, now: now, calendar: calendar, defaultTime: defaultTime)
    }
}

extension DueTime {
    static let nine = DueTime(hour: 9, minute: 0)
}

@Suite struct DueDateParserTests {
    /// (input, expected date) on Wednesday 7 Oct 2026, 10:00.
    static let wednesdayCases: [(String, String)] = [
        // Relative
        ("in 30 min", "2026-10-07 10:30"),
        ("in 12h", "2026-10-07 22:00"),
        ("in an hour", "2026-10-07 11:00"),
        ("in 2 hours", "2026-10-07 12:00"),
        ("in 3 days", "2026-10-10 10:00"),
        ("in a week", "2026-10-14 10:00"),
        ("in 2 weeks", "2026-10-21 10:00"),
        ("in 2 months", "2026-12-07 10:00"),
        ("in 3 days at 2pm", "2026-10-10 14:00"),
        // Day words
        ("today 17:00", "2026-10-07 17:00"),
        ("tomorrow", "2026-10-08 09:00"),
        ("tomorow", "2026-10-08 09:00"),
        ("tommorow", "2026-10-08 09:00"),
        ("day after tomorrow", "2026-10-09 09:00"),
        ("tonight", "2026-10-07 18:00"),
        ("this evening", "2026-10-07 18:00"),
        ("tonight 9pm", "2026-10-07 21:00"),
        ("tomorrow morning", "2026-10-08 09:00"),
        ("tomorrow afternoon", "2026-10-08 14:00"),
        ("tomorrow evening", "2026-10-08 18:00"),
        ("tomorrow noon", "2026-10-08 12:00"),
        ("afternoon", "2026-10-07 14:00"),
        ("tomorrow at 2pm", "2026-10-08 14:00"),
        ("Tomorrow, 10AM", "2026-10-08 10:00"),
        // Weekdays
        ("fri", "2026-10-09 09:00"),
        ("friday", "2026-10-09 09:00"),
        ("this friday", "2026-10-09 09:00"),
        ("next friday", "2026-10-16 09:00"),
        ("fri 9am", "2026-10-09 09:00"),
        ("on friday by 5pm", "2026-10-09 17:00"),
        ("wed", "2026-10-14 09:00"),
        ("wednes", "2026-10-14 09:00"),
        ("next wednesday", "2026-10-21 09:00"),
        ("mon", "2026-10-12 09:00"),
        ("thurs", "2026-10-08 09:00"),
        ("next week", "2026-10-12 09:00"),
        ("weekend", "2026-10-10 09:00"),
        // Dates
        ("10.10.2026", "2026-10-10 09:00"),
        ("10.10.26", "2026-10-10 09:00"),
        ("24.12.", "2026-12-24 09:00"),
        ("24.12", "2026-12-24 09:00"),
        ("1.10.", "2027-10-01 09:00"),
        ("10.10.2026 at 10am", "2026-10-10 10:00"),
        ("10.10.2027 at 10am", "2027-10-10 10:00"),
        ("3 nov", "2026-11-03 09:00"),
        ("nov 3", "2026-11-03 09:00"),
        ("3rd november 2027", "2027-11-03 09:00"),
        ("3 nov 5pm", "2026-11-03 17:00"),
        ("the 3rd of november", "2026-11-03 09:00"),
        ("2026-12-01", "2026-12-01 09:00"),
        // Just a time
        ("14:30", "2026-10-07 14:30"),
        ("9am", "2026-10-08 09:00"),
        ("10 am", "2026-10-08 10:00"),
        ("2pm", "2026-10-07 14:00"),
        ("10:30pm", "2026-10-07 22:30"),
        ("noon", "2026-10-07 12:00"),
        ("at 11", "2026-10-07 11:00"),
        ("@ 11", "2026-10-07 11:00"),
    ]

    @Test(arguments: wednesdayCases)
    func onAWednesday(input: String, expected: String) throws {
        let outcome = DueFixture.parse(input, now: DueFixture.wednesday)
        let date = try #require(outcome.date, "\(input) → \(outcome)")
        #expect(DueFixture.text(date) == expected, "\(input)")
    }

    /// (input, expected date) on Friday 9 Oct 2026, 14:00.
    static let fridayCases: [(String, String)] = [
        ("fri", "2026-10-16 09:00"),
        ("friday", "2026-10-16 09:00"),
        ("this friday", "2026-10-16 09:00"),
        ("next friday", "2026-10-23 09:00"),
        ("mon", "2026-10-12 09:00"),
        ("next week", "2026-10-12 09:00"),
        ("weekend", "2026-10-10 09:00"),
        ("9am", "2026-10-10 09:00"),
        ("14:30", "2026-10-09 14:30"),
        ("tonight", "2026-10-09 18:00"),
        ("24.12.", "2026-12-24 09:00"),
        ("in a week", "2026-10-16 14:00"),
    ]

    @Test(arguments: fridayCases)
    func onAFriday(input: String, expected: String) throws {
        let outcome = DueFixture.parse(input, now: DueFixture.friday)
        let date = try #require(outcome.date, "\(input) → \(outcome)")
        #expect(DueFixture.text(date) == expected, "\(input)")
    }

    @Test func aYearlessDateRollsIntoNextYear() throws {
        let outcome = DueFixture.parse("3 jan", now: DueFixture.date("2026-12-30 12:00"))
        #expect(DueFixture.text(try #require(outcome.date)) == "2027-01-03 09:00")
        #expect(outcome.note?.contains("next year") == true)
    }

    @Test func theDefaultTimeIsPassedIn() throws {
        let outcome = DueFixture.parse("tomorrow", now: DueFixture.wednesday, defaultTime: DueTime(hour: 8, minute: 30))
        #expect(DueFixture.text(try #require(outcome.date)) == "2026-10-08 08:30")
        #expect(outcome.note == "no time → 8:30")
    }

    // MARK: Notes

    @Test(arguments: [
        ("tomorrow", "no time → 9:00"),
        ("in 3 days", "same time as now"),
        ("9am", "already passed today → tomorrow"),
        ("1.10.", "no time → 9:00, next year"),
    ])
    func explainsWhatItFilledIn(input: String, note: String) {
        #expect(DueFixture.parse(input, now: DueFixture.wednesday).note == note)
    }

    @Test(arguments: ["in 30 min", "tomorrow 10am", "14:30", "in 3 days at 2pm"])
    func saysNothingWhenNothingWasFilledIn(input: String) {
        #expect(DueFixture.parse(input, now: DueFixture.wednesday).note == nil)
    }

    // MARK: Errors

    @Test(arguments: ["", "   ", "\n"])
    func blankIsEmpty(input: String) {
        #expect(DueFixture.parse(input, now: DueFixture.wednesday) == .empty)
    }

    @Test(arguments: [
        ("xyz", DueDateError.didNotUnderstand("xyz")),
        ("tomorrow foo", .didNotUnderstand("foo")),
        ("next month", .didNotUnderstand("next month")),
        ("10", .didNotUnderstand("10")),
        ("at", .notADate),
        ("1.1.25", .inThePast),
        ("today 8am", .inThePast),
        ("25:00", .impossibleTime),
        ("tomorrow 13pm", .impossibleTime),
        ("at 24", .impossibleTime),
        ("10:75", .impossibleTime),
        ("31.2.2027", .impossibleDate),
    ])
    func refuses(input: String, error: DueDateError) {
        #expect(DueFixture.parse(input, now: DueFixture.wednesday) == .failure(error), "\(input)")
    }

    @Test func todayWithItsDefaultTimeIsPastOnAFridayAfternoon() {
        #expect(DueFixture.parse("today", now: DueFixture.friday) == .failure(.inThePast))
    }

    @Test(arguments: [
        (DueDateError.didNotUnderstand("foo"), "Didn't understand “foo”"),
        (.notADate, "Not a date"),
        (.inThePast, "That's in the past"),
        (.impossibleTime, "That time doesn't exist"),
        (.impossibleDate, "That date doesn't exist"),
    ])
    func errorMessages(error: DueDateError, message: String) {
        #expect(error.message == message)
    }

    // MARK: Help examples

    @Test func everyHelpExampleParsesToItsShownTime() {
        for group in DueDateExamples.groups {
            for example in group.examples {
                let outcome = DueFixture.parse(example.phrase, now: DueFixture.wednesday)
                #expect(outcome.date != nil, "\(example.phrase)")
            }
        }
        #expect(DueDateExamples.groups.map(\.title) == ["Relative", "Days", "Dates", "Just a time"])
    }
}
