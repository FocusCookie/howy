import Foundation
import SwiftData

/// A todo. Open while `completedAt == nil`, archived otherwise.
///
/// The quadrant is stored as a raw `Int` (`quadrantRaw`) so it can be used in `#Predicate`s;
/// use the `quadrant` accessor everywhere else.
@Model
public final class Todo {
    @Attribute(.unique) public var id: UUID
    public var title: String
    /// Markdown text; may be empty.
    public var note: String
    public var quadrantRaw: Int
    public var createdAt: Date
    /// Drives newest-first ordering. Set on creation and when the todo moves quadrant.
    public var sortDate: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        quadrant: Quadrant,
        createdAt: Date,
        sortDate: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.quadrantRaw = quadrant.rawValue
        self.createdAt = createdAt
        self.sortDate = sortDate ?? createdAt
        self.completedAt = completedAt
    }

    public var quadrant: Quadrant {
        get { Quadrant(rawValue: quadrantRaw) ?? .urgentImportant }
        set { quadrantRaw = newValue.rawValue }
    }

    public var isOpen: Bool { completedAt == nil }

    /// A lightweight value copy for widgets.
    public var snapshot: TodoSnapshot {
        TodoSnapshot(id: id, title: title, quadrant: quadrant)
    }
}

/// A value-type view of a todo for widget rendering (no SwiftData objects in views).
public struct TodoSnapshot: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var quadrant: Quadrant
    /// How many files are attached (for the paperclip); filled in by `TodoStore`.
    public var attachmentCount: Int

    public init(id: UUID, title: String, quadrant: Quadrant, attachmentCount: Int = 0) {
        self.id = id
        self.title = title
        self.quadrant = quadrant
        self.attachmentCount = attachmentCount
    }
}
