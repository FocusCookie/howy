import Foundation

/// Whether a todo has a due date and whether it has passed.
public enum DueState: Hashable, Sendable, Codable {
    case none
    case upcoming
    /// The due moment has come (at `due` itself or later).
    case overdue

    public init(due: Date?, now: Date) {
        guard let due else { self = .none; return }
        self = due <= now ? .overdue : .upcoming
    }
}

/// The due-date texts: short labels for lists and pills, the full date for tooltips, and the
/// dialog's live preview. English, 24-hour times.
///
/// Short label rules: overdue → "Overdue · N min / h / days"; under an hour → "in N min"; later
/// today → "16:00"; tomorrow → "Tomorrow 10:00"; within six days → "Fri 10:00"; further →
/// "21 Oct", with the year when it isn't `now`'s ("10 Oct 2027").
public struct DueFormat: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "09:05".
    public func time(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "Fri 16 Oct 2026, 10:00".
    public func long(_ date: Date) -> String {
        let c = calendar.dateComponents([.weekday, .day, .month, .year], from: date)
        return "\(Self.weekdays[(c.weekday ?? 1) - 1]) \(c.day ?? 0) \(Self.months[(c.month ?? 1) - 1]) \(c.year ?? 0), \(time(date))"
    }

    /// Calendar days from `now`'s day to `date`'s (negative in the past).
    private func dayDistance(_ date: Date, from now: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// "in 30 min", "in 12 h", "in 3 days", "2 h ago".
    public func relative(_ date: Date, now: Date) -> String {
        let past = date < now
        let amount = distance(date, now: now)
        return past ? "\(amount) ago" : "in \(amount)"
    }

    /// "30 min", "2 h", "3 days" between `now` and `date` (either way); at least "1 min".
    private func distance(_ date: Date, now: Date) -> String {
        let seconds = abs(date.timeIntervalSince(now))
        if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded()))) min" }
        if seconds < 86_400 { return "\(Int((seconds / 3600).rounded())) h" }
        let days = abs(dayDistance(date, from: now))
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    /// The short label for lists, pills and the examples panel.
    public func short(_ due: Date, now: Date) -> String {
        if due <= now { return "Overdue · \(distance(due, now: now))" }
        if due.timeIntervalSince(now) < 3600 { return relative(due, now: now) }
        let days = dayDistance(due, from: now)
        switch days {
        case 0: return time(due)
        case 1: return "Tomorrow \(time(due))"
        case 2...6:
            let weekday = calendar.component(.weekday, from: due)
            return "\(Self.weekdays[weekday - 1]) \(time(due))"
        default:
            let c = calendar.dateComponents([.day, .month, .year], from: due)
            let date = "\(c.day ?? 0) \(Self.months[(c.month ?? 1) - 1])"
            return c.year == calendar.component(.year, from: now) ? date : "\(date) \(c.year ?? 0)"
        }
    }

    /// The line under the dialog's field.
    public enum Preview: Hashable, Sendable {
        /// Nothing typed (and nothing set).
        case idle(String)
        /// The date ("→ Fri 16 Oct 2026, 10:00") and the details after it ("in 7 days · no time → 9:00").
        case ok(String, detail: String)
        case error(String)
    }

    /// The preview of a parse outcome. `unchanged` (an empty field with a date already set) adds
    /// "unchanged".
    public func preview(_ outcome: DueDateParser.Outcome, now: Date, unchanged: Bool = false) -> Preview {
        switch outcome {
        case .empty:
            return .idle("Type when it's due")
        case .failure(let error):
            return .error(error.message)
        case .resolved(let date, let note):
            let detail = [relative(date, now: now), note, unchanged ? "unchanged" : nil].compactMap { $0 }
            return .ok("→ \(long(date))", detail: detail.joined(separator: " · "))
        }
    }
}
