import Foundation
import SwiftData

/// What happened to a todo, as recorded in the event log.
///
/// Stored as its raw string, so a kind added later reads as `nil` on an older build instead of
/// failing. Title and note edits are not recorded.
public enum TodoEventKind: String, CaseIterable, Codable, Sendable {
    /// The todo was added or imported; `toQuadrant` is where, `due` the due date it came with.
    case created
    /// The todo was ticked off (archived).
    case completed
    /// An archived todo was restored.
    case reopened
    /// The todo changed quadrant: `fromQuadrant` → `toQuadrant`.
    case moved
    /// A due date was given to a todo without one (`due`).
    case dueSet
    /// The due date changed from `previousDue` to `due`.
    case dueChanged
    /// The due date was pushed back by a notification snooze, `previousDue` → `due`.
    case dueSnoozed
    /// The due date (`previousDue`) was removed.
    case dueRemoved
    /// The todo was deleted; `fromQuadrant` is where it was.
    case deleted
}

/// One entry of the append-only event log (schema v3), written by `TodoStore` in the same
/// save as the change it records.
///
/// Events have no relationship to `Todo`: they outlive it (deleting a todo or purging the
/// archive keeps them) and only refer to it by `todoID`. They never carry titles or notes,
/// only ids, quadrants and times. Every attribute has a default, as CloudKit requires.
@Model
public final class TodoEvent {
    public var id: UUID = UUID()
    public var todoID: UUID = UUID()
    /// `TodoEventKind.rawValue`; use `kind`.
    public var kindRaw: String = ""
    public var date: Date = Date.distantPast
    /// `Quadrant.rawValue` the todo left (`moved`, `deleted`).
    public var fromQuadrantRaw: Int?
    /// `Quadrant.rawValue` the todo arrived in (`created`, `moved`).
    public var toQuadrantRaw: Int?
    /// The due date before the change (due events).
    public var previousDue: Date?
    /// The due date after the change (due events, `created`).
    public var due: Date?

    public init(
        id: UUID = UUID(),
        todoID: UUID,
        kind: TodoEventKind,
        date: Date,
        from: Quadrant? = nil,
        to: Quadrant? = nil,
        previousDue: Date? = nil,
        due: Date? = nil
    ) {
        self.id = id
        self.todoID = todoID
        self.kindRaw = kind.rawValue
        self.date = date
        self.fromQuadrantRaw = from?.rawValue
        self.toQuadrantRaw = to?.rawValue
        self.previousDue = previousDue
        self.due = due
    }

    /// `nil` for a kind this build doesn't know (written by a newer one).
    public var kind: TodoEventKind? { TodoEventKind(rawValue: kindRaw) }
    public var fromQuadrant: Quadrant? { fromQuadrantRaw.flatMap(Quadrant.init(rawValue:)) }
    public var toQuadrant: Quadrant? { toQuadrantRaw.flatMap(Quadrant.init(rawValue:)) }
}
