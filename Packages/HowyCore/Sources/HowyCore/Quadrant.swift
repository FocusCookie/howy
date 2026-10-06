import SwiftUI

/// A cell in the 2×2 Eisenhower grid. Row 0 is "Important", column 0 is "Urgent".
public struct GridPosition: Hashable, Sendable {
    public var row: Int
    public var column: Int
    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// The four Eisenhower quadrants, declared in reading order (left-to-right, top-to-bottom).
public enum Quadrant: Int, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case urgentImportant = 1
    case notUrgentImportant = 2
    case urgentUnimportant = 3
    case notUrgentUnimportant = 4

    public var id: Int { rawValue }

    /// The key (1–4) that picks this quadrant in quick entry.
    public var shortcutNumber: Int { rawValue }

    public init?(shortcutNumber: Int) {
        self.init(rawValue: shortcutNumber)
    }

    public var displayName: String {
        switch self {
        case .urgentImportant: "Urgent & Important"
        case .notUrgentImportant: "Not Urgent & Important"
        case .urgentUnimportant: "Urgent & Unimportant"
        case .notUrgentUnimportant: "Not Urgent & Unimportant"
        }
    }

    /// Quadrant colour (TickTick-style): red, orange, blue, green.
    public var color: Color {
        switch self {
        case .urgentImportant: .red
        case .notUrgentImportant: .orange
        case .urgentUnimportant: .blue
        case .notUrgentUnimportant: .green
        }
    }

    public var gridPosition: GridPosition {
        GridPosition(row: (rawValue - 1) / 2, column: (rawValue - 1) % 2)
    }

    /// The quadrant at a grid position; `nil` outside the 2×2 grid.
    public init?(gridPosition: GridPosition) {
        guard (0...1).contains(gridPosition.row), (0...1).contains(gridPosition.column) else { return nil }
        self.init(rawValue: gridPosition.row * 2 + gridPosition.column + 1)
    }
}
