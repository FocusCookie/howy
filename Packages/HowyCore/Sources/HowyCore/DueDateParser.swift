import Foundation

/// A time of day (24-hour clock): the default for due dates typed without a time (a Settings
/// choice, 9:00 unless changed).
public struct DueTime: Hashable, Codable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// 9:00.
    public static let standard = DueTime(hour: 9, minute: 0)

    /// "9:00", "8:30" (the hour unpadded, as the dialog's notes say it).
    public var text: String { "\(hour):" + String(format: "%02d", minute) }

    public static let defaultsKey = "dueDefaultTime"

    /// The stored setting (minutes after midnight); 9:00 when unset.
    public static func load(from defaults: UserDefaults = .standard) -> DueTime {
        guard defaults.object(forKey: defaultsKey) != nil else { return .standard }
        let minutes = defaults.integer(forKey: defaultsKey)
        return DueTime(hour: minutes / 60, minute: minutes % 60)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(hour * 60 + minute, forKey: Self.defaultsKey)
    }
}

/// Why a phrase is not a due date.
public enum DueDateError: Hashable, Sendable {
    /// Nothing in it says when (only filler words).
    case notADate
    /// These words were left over after everything known was read.
    case didNotUnderstand(String)
    /// It resolves to now or earlier.
    case inThePast
    /// An hour or minute that doesn't exist ("25:00", "13pm").
    case impossibleTime
    /// A day that doesn't exist ("31.2.").
    case impossibleDate

    /// What the dialog shows.
    public var message: String {
        switch self {
        case .notADate: "Not a date"
        case .didNotUnderstand(let rest): "Didn't understand “\(rest)”"
        case .inThePast: "That's in the past"
        case .impossibleTime: "That time doesn't exist"
        case .impossibleDate: "That date doesn't exist"
        }
    }
}

/// The words the parser knows. English only for now; another language is another instance.
public struct DueDateVocabulary: Sendable {
    /// Full weekday names, Sunday first (a typed weekday is any prefix of three letters or more).
    public var weekdays: [String]
    /// Full month names, January first (a typed month is any prefix of three letters or more).
    public var months: [String]
    /// Words for small numbers in relative phrases ("in a week").
    public var numbers: [String: Int]
    /// Spellings of "tomorrow", typos included.
    public var tomorrow: [String]
    public var today: String
    public var dayAfterTomorrow: String
    /// "tonight", "this evening": today at 18:00 unless a time is given.
    public var tonight: [String]
    public var nextWeek: String
    public var weekend: String
    /// "this" / "next" before a weekday.
    public var this: String
    public var next: String
    /// "in" before a relative amount.
    public var `in`: String
    /// Parts of the day used as the time, e.g. "morning" → 9:00.
    public var partsOfDay: [String: DueTime]
    /// Words that name a time on their own ("noon").
    public var namedTimes: [String: DueTime]
    /// "at" before a bare hour ("at 10").
    public var at: String
    /// Ignored words.
    public var fillers: [String]
    /// Units of relative phrases, as a regex alternation, and how to read a matched unit.
    public var unitPattern: String
    public var unit: @Sendable (String) -> Calendar.Component?
    /// The ordinal suffixes after a day number ("3rd").
    public var ordinalPattern: String
    public var am: String
    public var pm: String

    public static let english = DueDateVocabulary(
        weekdays: ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"],
        months: ["january", "february", "march", "april", "may", "june", "july", "august",
                 "september", "october", "november", "december"],
        numbers: ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                  "seven": 7, "eight": 8, "nine": 9, "ten": 10],
        tomorrow: ["tomorrow", "tomorow", "tommorow", "tommorrow", "tmrw", "tmr"],
        today: "today",
        dayAfterTomorrow: "day after tomorrow",
        tonight: ["tonight", "this evening"],
        nextWeek: "next week",
        weekend: "weekend",
        this: "this",
        next: "next",
        in: "in",
        partsOfDay: [
            "morning": DueTime(hour: 9, minute: 0),
            "afternoon": DueTime(hour: 14, minute: 0),
            "evening": DueTime(hour: 18, minute: 0),
        ],
        namedTimes: ["noon": DueTime(hour: 12, minute: 0), "midnight": DueTime(hour: 23, minute: 59)],
        at: "at",
        fillers: ["at", "on", "by", "the", "of"],
        unitPattern: "minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|wks?|w|months?",
        unit: { unit in
            if unit.hasPrefix("mo") { return .month }
            switch unit.first {
            case "m": return .minute
            case "h": return .hour
            case "d": return .day
            case "w": return .weekOfYear
            default: return nil
            }
        },
        ordinalPattern: "st|nd|rd|th",
        am: "am",
        pm: "pm"
    )

    /// The index of the weekday (0 = Sunday) or month (0 = January) a typed word names.
    func index(of word: String, in names: [String]) -> Int? {
        guard word.count >= 3 else { return nil }
        return names.firstIndex { $0.hasPrefix(word) }
    }
}

/// Turns what the user types into the due-date dialog ("tomorrow 10am", "fri", "24.12.",
/// "in a week") into a point in time. Pure: `now`, the calendar and the default time of day are
/// passed in.
///
/// Rules:
/// - "in N min / h": exactly now + N. "in N days / weeks / months": that many later at the same
///   time as now, unless a time is given.
/// - Day words ("today", "tomorrow" and its typos, "day after tomorrow"), weekdays, "next week"
///   (Monday), "weekend" (Saturday) and dates use the default time unless a time is given.
///   "tonight" / "this evening" are today at 18:00.
/// - A weekday ("fri", "this friday", "wednes") is the coming one, a week later on that same
///   weekday; "next friday" is the coming one + 7 days.
/// - Day-first dates ("10.10.2026", "10.10.26", "24.12.", "24.12"), month names ("3 nov",
///   "nov 3", "3rd november 2027") and ISO dates; without a year, the next time that date comes.
/// - Times "10am", "10 am", "10:30pm", "14:30", "at 10", "noon"; parts of the day ("morning"
///   9:00, "afternoon" 14:00, "evening" 18:00). A bare time already passed today is tomorrow.
/// - "at", "on", "by", "the", "of", "@" and commas are ignored; any other word left over is an
///   error, as is a result at or before `now`, an hour or minute that doesn't exist, or a day
///   that doesn't exist.
public enum DueDateParser {
    public enum Outcome: Hashable, Sendable {
        /// Nothing typed.
        case empty
        /// The due date, and what was filled in, if anything ("no time → 9:00").
        case resolved(Date, note: String?)
        case failure(DueDateError)

        public var date: Date? {
            if case .resolved(let date, _) = self { date } else { nil }
        }

        public var note: String? {
            if case .resolved(_, let note) = self { note } else { nil }
        }

        public var error: DueDateError? {
            if case .failure(let error) = self { error } else { nil }
        }
    }

    public static func parse(
        _ input: String,
        now: Date,
        calendar: Calendar = .current,
        defaultTime: DueTime = .standard,
        vocabulary words: DueDateVocabulary = .english
    ) -> Outcome {
        var reader = Reader(input)
        guard !reader.isBlank else { return .empty }

        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: now)
        var relative: (amount: Int, unit: Calendar.Component)?
        var time: (hour: Int, minute: Int)?
        var badTime = false
        var day: (year: Int, month: Int, day: Int)?
        var dayOffset: Int?
        var yearless = false
        var weekday: Int?
        var nextWeekday = false

        // Relative: "in 2 h", "in a week", "in 3 days".
        let numberWords = words.numbers.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        reader.take(#"\b\#(words.in)\s+(\#(numberWords)|\d+)\s*(\#(words.unitPattern))\b"#) { m in
            guard let amount = words.numbers[m[1]] ?? Int(m[1]), let unit = words.unit(m[2]) else { return false }
            relative = (amount, unit)
            return true
        }

        // Times: am/pm, hh:mm, named times.
        _ = reader.take(#"\b(\d{1,2})(?:[:.](\d{2}))?\s*(\#(words.am)|\#(words.pm))\b"#) { m in
            let hour = Int(m[1])!, minute = Int(m[2]) ?? 0
            if !(1...12).contains(hour) || minute > 59 { badTime = true }
            time = (hour % 12 + (m[3] == words.pm ? 12 : 0), minute)
            return true
        } || reader.take(#"\b(\d{1,2}):(\d{2})\b"#) { m in
            time = (Int(m[1])!, Int(m[2])!)
            return true
        } || reader.take(#"\b(\#(words.namedTimes.keys.joined(separator: "|")))\b"#) { m in
            let named = words.namedTimes[m[1]]!
            time = (named.hour, named.minute)
            return true
        }

        // Dates.
        _ = reader.take(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#) { m in
            day = (Int(m[1])!, Int(m[2])!, Int(m[3])!)
            return true
        } || reader.take(#"(?:^|\s)(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?(?=\s)"#) { m in
            if let typed = Int(m[3]) {
                day = (m[3].count == 2 ? 2000 + typed : typed, Int(m[2])!, Int(m[1])!)
            } else {
                day = (year, Int(m[2])!, Int(m[1])!)
                yearless = true
            }
            return true
        } || reader.take(#"(?:^|\s)(\d{1,2})\.(\d{1,2})(?=\s)"#) { m in
            day = (year, Int(m[2])!, Int(m[1])!)
            yearless = true
            return true
        } || reader.take(#"\b(\d{1,2})(?:\#(words.ordinalPattern))?\s+(?:of\s+)?([a-z]+)\.?(?:\s+(\d{4}))?\b"#) { m in
            guard let month = words.index(of: m[2], in: words.months) else { return false }
            day = (Int(m[3]) ?? year, month + 1, Int(m[1])!)
            yearless = m[3].isEmpty
            return true
        } || reader.take(#"\b([a-z]+)\.?\s+(\d{1,2})(?:\#(words.ordinalPattern))?(?:\s+(\d{4}))?\b"#) { m in
            guard let month = words.index(of: m[1], in: words.months) else { return false }
            day = (Int(m[3]) ?? year, month + 1, Int(m[2])!)
            yearless = m[3].isEmpty
            return true
        }

        // Day words, "next week", "weekend", weekdays.
        let saturday = 6
        _ = reader.take(#"\b\#(words.dayAfterTomorrow)\b"#) { _ in
            dayOffset = 2
            return true
        } || reader.take(#"\b(\#(words.tomorrow.joined(separator: "|")))\b"#) { _ in
            dayOffset = 1
            return true
        } || reader.take(#"\b\#(words.today)\b"#) { _ in
            dayOffset = 0
            return true
        } || reader.take(#"\b(\#(words.tonight.joined(separator: "|")))\b"#) { _ in
            dayOffset = 0
            if time == nil { time = (18, 0) }
            return true
        } || reader.take(#"\b\#(words.nextWeek)\b"#) { _ in
            let current = calendar.component(.weekday, from: now) - 1
            dayOffset = (8 - current) % 7 == 0 ? 7 : (8 - current) % 7
            return true
        } || reader.take(#"\b(?:(?:\#(words.this)|\#(words.next))\s+)?\#(words.weekend)\b"#) { _ in
            weekday = saturday
            return true
        } || reader.take(#"\b(?:(\#(words.this)|\#(words.next))\s+)?([a-z]+)\b"#) { m in
            guard let index = words.index(of: m[2], in: words.weekdays) else { return false }
            weekday = index
            nextWeekday = m[1] == words.next
            return true
        }

        // Parts of the day after a day word ("tomorrow morning"), or "at 10".
        if time == nil {
            let parts = words.partsOfDay.keys.joined(separator: "|")
            _ = reader.take(#"\b(\#(parts))\b"#) { m in
                let part = words.partsOfDay[m[1]]!
                time = (part.hour, part.minute)
                return true
            } || reader.take(#"\b\#(words.at)\s+(\d{1,2})\b"#) { m in
                time = (Int(m[1])!, 0)
                return true
            }
        }

        reader.remove(#"\b(\#(words.fillers.joined(separator: "|")))\b"#)
        let rest = reader.rest
        if !rest.isEmpty { return .failure(.didNotUnderstand(rest)) }
        if let time, badTime || time.hour > 23 || time.minute > 59 { return .failure(.impossibleTime) }

        func at(_ date: Date, _ hour: Int, _ minute: Int) -> Date? {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
        }
        func days(_ count: Int, from date: Date) -> Date? {
            calendar.date(byAdding: .day, value: count, to: date)
        }
        let defaultNote = "no time → \(defaultTime.text)"

        var result: Date?
        var notes: [String] = []
        if let relative {
            if relative.unit == .minute || relative.unit == .hour {
                result = calendar.date(byAdding: relative.unit, value: relative.amount, to: now)
            } else {
                result = calendar.date(byAdding: relative.unit, value: relative.amount, to: now)
                if let time, let shifted = result {
                    result = at(shifted, time.hour, time.minute)
                } else {
                    notes.append("same time as now")
                }
            }
        } else if day != nil || dayOffset != nil {
            var base: Date?
            if let day {
                let components = DateComponents(year: day.year, month: day.month, day: day.day)
                guard let date = calendar.date(from: components),
                      calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(
                        year: day.year, month: day.month, day: day.day
                      )
                else { return .failure(.impossibleDate) }
                base = date
            } else if let dayOffset {
                base = days(dayOffset, from: today)
            }
            if let base {
                result = at(base, time?.hour ?? defaultTime.hour, time?.minute ?? defaultTime.minute)
                if time == nil { notes.append(defaultNote) }
                if yearless, let date = result, date <= now {
                    result = calendar.date(byAdding: .year, value: 1, to: date)
                    notes.append("next year")
                }
            }
        } else if let weekday {
            let current = calendar.component(.weekday, from: now) - 1
            let ahead = (weekday - current + 7) % 7
            let offset = (ahead == 0 ? 7 : ahead) + (nextWeekday ? 7 : 0)
            if let base = days(offset, from: today) {
                result = at(base, time?.hour ?? defaultTime.hour, time?.minute ?? defaultTime.minute)
                if time == nil { notes.append(defaultNote) }
            }
        } else if let time {
            result = at(today, time.hour, time.minute)
            if let date = result, date <= now {
                result = days(1, from: date)
                notes.append("already passed today → tomorrow")
            }
        } else {
            return .failure(.notADate)
        }
        guard let result else { return .failure(.notADate) }
        guard result > now else { return .failure(.inThePast) }
        return .resolved(result, note: notes.isEmpty ? nil : notes.joined(separator: ", "))
    }
}

/// The phrase being read: each recognised part is cut out, so what is left at the end is what
/// wasn't understood.
private struct Reader {
    private var text: String

    init(_ input: String) {
        let lowered = input.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "@", with: " at ")
        let words = lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = " \(words) "
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    var rest: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Finds the first match of `pattern` that `accept` takes (it gets the capture groups, ""
    /// for a group that didn't take part) and cuts it out. Returns whether one was taken.
    @discardableResult
    mutating func take(_ pattern: String, _ accept: ([String]) -> Bool) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let groups = (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            if accept(groups) {
                text = ns.replacingCharacters(in: match.range, with: " ")
                return true
            }
        }
        return false
    }

    mutating func remove(_ pattern: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        text = regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " "
        )
    }
}

/// The examples the dialog's **?** panel lists, grouped, each with a hint of what it means.
public enum DueDateExamples {
    public struct Example: Hashable, Sendable, Identifiable {
        public let phrase: String
        /// What the phrase means beyond its date ("keeps the current time"); may be empty.
        public let hint: String
        public var id: String { phrase }
    }

    public struct Group: Hashable, Sendable, Identifiable {
        public let title: String
        public let examples: [Example]
        public var id: String { title }
    }

    public static let groups: [Group] = [
        Group(title: "Relative", examples: [
            Example(phrase: "in 30 min", hint: ""),
            Example(phrase: "in 12h", hint: ""),
            Example(phrase: "in 3 days", hint: "keeps the current time"),
            Example(phrase: "in a week", hint: "keeps the current time"),
        ]),
        Group(title: "Days", examples: [
            Example(phrase: "tomorrow at 2pm", hint: ""),
            Example(phrase: "tonight", hint: "18:00"),
            Example(phrase: "next wednesday", hint: "the one after the coming one"),
            Example(phrase: "fri 9am", hint: ""),
            Example(phrase: "next week", hint: "Monday"),
            Example(phrase: "weekend", hint: "Saturday"),
        ]),
        Group(title: "Dates", examples: [
            Example(phrase: "24.12.", hint: "day.month — the next one"),
            Example(phrase: "10.10.2027 at 10am", hint: ""),
            Example(phrase: "3 nov 5pm", hint: ""),
        ]),
        Group(title: "Just a time", examples: [
            Example(phrase: "14:30", hint: "today, or tomorrow if passed"),
            Example(phrase: "9am", hint: ""),
            Example(phrase: "noon", hint: ""),
        ]),
    ]
}
