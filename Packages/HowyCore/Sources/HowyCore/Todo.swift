import Foundation
import SwiftData

/// A todo. Open while `completedAt == nil`, archived otherwise.
///
/// The quadrant is stored as a raw `Int` (`quadrantRaw`) so it can be used in `#Predicate`s;
/// use the `quadrant` accessor everywhere else.
///
/// Schema v3: no unique constraint and a default for every attribute, as CloudKit requires.
/// `id` stays unique by construction (fresh UUIDs; import skips taken ids).
@Model
public final class Todo {
    public var id: UUID = UUID()
    public var title: String = ""
    /// Markdown text; may be empty.
    public var note: String = ""
    public var quadrantRaw: Int = Quadrant.urgentImportant.rawValue
    public var createdAt: Date = Date.distantPast
    /// Drives newest-first ordering. Set on creation and when the todo moves quadrant.
    public var sortDate: Date = Date.distantPast
    public var completedAt: Date?
    /// When the todo is due (schema v2); `nil` for none. Completing, archiving and restoring
    /// keep it; the notification fires at this moment.
    public var due: Date?
    /// When a `TodoStore` write last changed this todo (schema v3). Picks the survivor when
    /// duplicates of one id meet.
    public var updatedAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        quadrant: Quadrant,
        createdAt: Date,
        sortDate: Date? = nil,
        completedAt: Date? = nil,
        due: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.quadrantRaw = quadrant.rawValue
        // Whole milliseconds, as CloudKit keeps them (`Date.wholeMilliseconds`).
        self.createdAt = createdAt.wholeMilliseconds
        self.sortDate = (sortDate ?? createdAt).wholeMilliseconds
        self.completedAt = completedAt.wholeMilliseconds
        self.due = due.wholeMilliseconds
        self.updatedAt = (updatedAt ?? createdAt).wholeMilliseconds
    }

    public var quadrant: Quadrant {
        get { Quadrant(rawValue: quadrantRaw) ?? .urgentImportant }
        set { quadrantRaw = newValue.rawValue }
    }

    public var isOpen: Bool { completedAt == nil }

    /// A lightweight value copy for widgets.
    public var snapshot: TodoSnapshot {
        TodoSnapshot(id: id, title: title, quadrant: quadrant, due: due)
    }
}

/// A value-type view of a todo for widget rendering (no SwiftData objects in views).
public struct TodoSnapshot: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var quadrant: Quadrant
    /// How many files are attached (for the paperclip); filled in by `TodoStore`.
    public var attachmentCount: Int
    /// When it is due, if ever (the list's clock or bell, the widget's clock).
    public var due: Date?

    public init(id: UUID, title: String, quadrant: Quadrant, attachmentCount: Int = 0, due: Date? = nil) {
        self.id = id
        self.title = title
        self.quadrant = quadrant
        self.attachmentCount = attachmentCount
        self.due = due
    }

    /// Whether the due date has passed at `now`.
    public func dueState(at now: Date) -> DueState {
        DueState(due: due, now: now)
    }
}

/// A todo's stored values as plain data, timestamps included (import and export).
public struct TodoRecord: Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var note: String
    public var quadrant: Quadrant
    public var createdAt: Date
    public var sortDate: Date
    /// `nil` while open; set means done and archived.
    public var completedAt: Date?
    /// `nil` without a due date.
    public var due: Date?

    public init(
        id: UUID,
        title: String,
        note: String = "",
        quadrant: Quadrant,
        createdAt: Date,
        sortDate: Date? = nil,
        completedAt: Date? = nil,
        due: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.quadrant = quadrant
        self.createdAt = createdAt
        self.sortDate = sortDate ?? createdAt
        self.completedAt = completedAt
        self.due = due
    }
}

extension Todo {
    /// The todo's values as plain data.
    public var record: TodoRecord {
        TodoRecord(
            id: id, title: title, note: note, quadrant: quadrant,
            createdAt: createdAt, sortDate: sortDate, completedAt: completedAt, due: due
        )
    }
}
