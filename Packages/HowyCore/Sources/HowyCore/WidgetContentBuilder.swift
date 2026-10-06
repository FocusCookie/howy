import Foundation

/// Howy's own widget size vocabulary (keeps the core free of WidgetKit types).
/// `small`/`medium` show one quadrant; `large`/`extraLarge` show the full matrix.
public enum HowyWidgetFamily: String, CaseIterable, Hashable, Sendable {
    case small, medium, large, extraLarge

    public var showsMatrix: Bool { self == .large || self == .extraLarge }
}

/// What one quadrant section of a widget renders.
public struct QuadrantContent: Hashable, Sendable {
    public var quadrant: Quadrant
    /// Titles to show, newest first.
    public var visible: [TodoSnapshot]
    /// All open todos in the quadrant (the label's count).
    public var openCount: Int
    /// Hidden todos for the "+N more" row; 0 means no such row.
    public var overflowCount: Int

    public init(quadrant: Quadrant, visible: [TodoSnapshot], openCount: Int, overflowCount: Int) {
        self.quadrant = quadrant
        self.visible = visible
        self.openCount = openCount
        self.overflowCount = overflowCount
    }

    public var isEmpty: Bool { openCount == 0 }
}

/// What a whole widget renders: one section (single-quadrant widget) or four in reading order (matrix).
public struct WidgetContent: Hashable, Sendable {
    public var family: HowyWidgetFamily
    public var quadrants: [QuadrantContent]

    public init(family: HowyWidgetFamily, quadrants: [QuadrantContent]) {
        self.family = family
        self.quadrants = quadrants
    }
}

/// Pure layout decisions for widgets: which titles fit and how many are hidden.
///
/// Capacity is the number of **lines per quadrant section** below its label. If a quadrant has
/// more todos than its capacity, the last line is used for "+N more", so `capacity - 1` titles
/// are shown and `overflowCount = openCount - (capacity - 1)`.
public enum WidgetContentBuilder {
    public static func capacity(for family: HowyWidgetFamily) -> Int {
        switch family {
        case .small: 4
        case .medium: 4
        case .large: 5
        case .extraLarge: 6
        }
    }

    /// - Parameters:
    ///   - openTodos: open todos per quadrant, already newest-first (order is preserved).
    ///   - selectedQuadrant: the single-quadrant widget's quadrant (default `.urgentImportant`); ignored for matrix families.
    ///   - capacity: overrides `capacity(for:)`; values below 1 are treated as 1.
    public static func build(
        openTodos: [Quadrant: [TodoSnapshot]],
        family: HowyWidgetFamily,
        selectedQuadrant: Quadrant?,
        capacity: Int? = nil
    ) -> WidgetContent {
        let lines = max(capacity ?? self.capacity(for: family), 1)
        let quadrants = family.showsMatrix ? Quadrant.allCases : [selectedQuadrant ?? .urgentImportant]
        return WidgetContent(family: family, quadrants: quadrants.map { quadrant in
            let todos = openTodos[quadrant] ?? []
            let fits = todos.count <= lines
            let visible = fits ? todos : Array(todos.prefix(lines - 1))
            return QuadrantContent(
                quadrant: quadrant,
                visible: visible,
                openCount: todos.count,
                overflowCount: todos.count - visible.count
            )
        })
    }
}
