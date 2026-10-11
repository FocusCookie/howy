import Foundation

/// A todo's due date as one thing to notify about: a new date is a new key.
public struct DueKey: Hashable, Codable, Sendable {
    public var id: UUID
    public var due: Date

    public init(id: UUID, due: Date) {
        self.id = id
        self.due = due
    }
}

/// One local notification Howy wants pending.
public struct NotificationRequest: Hashable, Sendable {
    /// Stable per todo (`NotificationPlan.identifier(for:)`), so a new date replaces the old request.
    public var identifier: String
    public var todoID: UUID
    public var due: Date
    /// When it fires; `nil` means right away (an overdue todo that never notified).
    public var fireDate: Date?
    /// The todo's title.
    public var title: String
    /// "Due now · Urgent & Important", or "Was due … · …" when late.
    public var body: String

    public var key: DueKey { DueKey(id: todoID, due: due) }
}

/// Which notifications should be pending, worked out from the open todos with due dates. Pure:
/// the app's adapter compares the result with `UNUserNotificationCenter` and adds or removes
/// requests (`diff`). Runs after every store write, at launch and on wake.
///
/// - Every open todo with a future due date gets a request that fires at that moment.
/// - An overdue todo that never notified (the Mac was asleep or off, or the app wasn't running)
///   gets one that fires right away; once shown (`shown`), it gets none.
/// - Done, archived and deleted todos aren't open, so their requests are removed.
/// - At most `limit` requests (the system keeps 64 per app): the earliest, right-away ones first.
public enum NotificationPlan {
    public static let limit = 64
    public static let identifierPrefix = "howy.due."
    /// The category with the Done, Snooze 1 h and Tomorrow actions.
    public static let categoryIdentifier = "howy.due"
    public static let doneAction = "howy.due.done"
    public static let snoozeAction = "howy.due.snooze"
    public static let tomorrowAction = "howy.due.tomorrow"
    /// "Snooze 1 h".
    public static let snoozeInterval: TimeInterval = 60 * 60
    /// The `userInfo` keys a request carries: the todo id and its due date (seconds since 1970).
    public static let todoIDKey = "todoID"
    public static let dueKey = "due"

    public static func identifier(for id: UUID) -> String { identifierPrefix + id.uuidString }

    public static func todoID(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
    }

    /// The requests for `todos` (open todos; undated ones are skipped). `shown` are the due
    /// dates already notified about.
    public static func requests(
        for todos: [TodoSnapshot], now: Date, shown: Set<DueKey>, format: DueFormat = DueFormat()
    ) -> [NotificationRequest] {
        let requests: [NotificationRequest] = todos.compactMap { todo in
            guard let due = todo.due else { return nil }
            let late = due <= now
            if late, shown.contains(DueKey(id: todo.id, due: due)) { return nil }
            let when = late ? "Was due \(format.long(due))" : "Due now"
            return NotificationRequest(
                identifier: identifier(for: todo.id), todoID: todo.id, due: due,
                fireDate: late ? nil : due, title: todo.title,
                body: "\(when) · \(todo.quadrant.displayName)"
            )
        }
        return Array(requests.sorted { ($0.fireDate ?? .distantPast) < ($1.fireDate ?? .distantPast) }.prefix(limit))
    }

    /// The due dates notified about: scheduled earlier (`scheduled`), their moment has passed and
    /// they are no longer pending (`pending`: identifier → due date), so the system showed them.
    public static func shown(scheduled: Set<DueKey>, pending: [String: Date], now: Date) -> Set<DueKey> {
        scheduled.filter { key in key.due <= now && pending[identifier(for: key.id)] != key.due }
    }

    /// What to change so `planned` is what's pending: requests to add (new, a changed date, or a
    /// right-away one replacing a pending request that missed its moment; adding replaces a
    /// pending request with the same identifier) and identifiers to remove (no longer planned).
    public static func diff(planned: [NotificationRequest], pending: [String: Date]) -> (add: [NotificationRequest], remove: [String]) {
        let plannedIDs = Set(planned.map(\.identifier))
        let add = planned.filter { request in request.fireDate == nil || pending[request.identifier] != request.due }
        let remove = pending.keys.filter { !plannedIDs.contains($0) }.sorted()
        return (add, remove)
    }

    /// The "Tomorrow" action's new due date: tomorrow at `time` (the default time of day).
    public static func tomorrow(at time: DueTime, now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: tomorrow) ?? tomorrow
    }
}
