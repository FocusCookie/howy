import CryptoKit
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
    /// Tie-breaker for events of one todo at the same `date`: the store sets it to the highest
    /// `seq` among the todo's events plus one on every write (`created` is 0). Reads sort by
    /// `date`, then `seq`.
    public var seq: Int = 0

    public init(
        id: UUID = UUID(),
        todoID: UUID,
        kind: TodoEventKind,
        date: Date,
        from: Quadrant? = nil,
        to: Quadrant? = nil,
        previousDue: Date? = nil,
        due: Date? = nil,
        seq: Int = 0
    ) {
        self.id = id
        self.todoID = todoID
        self.kindRaw = kind.rawValue
        self.date = date
        self.fromQuadrantRaw = from?.rawValue
        self.toQuadrantRaw = to?.rawValue
        self.previousDue = previousDue
        self.due = due
        self.seq = seq
    }

    /// The id of a backfilled event: a name-based (version 5) UUID of `todoID` and `kind`.
    ///
    /// The backfill can run in the app and the widget at the same time, and each would insert its
    /// own events. With ids derived from (todo, kind) both write the same ids, so the duplicate
    /// cleanup can collapse them by `id`.
    public static func backfillID(todoID: UUID, kind: TodoEventKind) -> UUID {
        let name = withUnsafeBytes(of: todoID.uuid) { Array($0) } + Array("howy.backfill.\(kind.rawValue)".utf8)
        var bytes = Array(Insecure.SHA1.hash(data: name).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
    }

    /// `nil` for a kind this build doesn't know (written by a newer one).
    public var kind: TodoEventKind? { TodoEventKind(rawValue: kindRaw) }
    public var fromQuadrant: Quadrant? { fromQuadrantRaw.flatMap(Quadrant.init(rawValue:)) }
    public var toQuadrant: Quadrant? { toQuadrantRaw.flatMap(Quadrant.init(rawValue:)) }
}
