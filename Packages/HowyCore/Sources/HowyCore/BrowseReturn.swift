import Foundation

/// Where a screen opened from Browse (the edit screen, the create screen of `n`) goes back to:
/// the quadrant grid with a quadrant highlighted (`n` on the grid), or a quadrant's list with a
/// todo selected. Take one with `BrowseFlow.returnPoint`, pick the way back with
/// `afterCreate(_:savedInto:)` once the screen closes, and apply it to the new Browse with
/// `BrowseFlow.resume(at:)`.
public struct BrowseReturn: Hashable, Sendable {
    /// The screen to come back to.
    public enum Screen: Hashable, Sendable {
        /// The quadrant grid, `quadrant` highlighted.
        case grid
        /// `quadrant`'s list, `todoID` (or the row at `index`) selected.
        case list
    }

    public let quadrant: Quadrant
    /// The todo to select; `nil` (e.g. an empty list) selects the row at `index`, or nothing.
    public let todoID: UUID?
    /// The row to select when `todoID` is gone from the list (deleted, moved); clamped.
    public let index: Int?
    public let screen: Screen

    public init(quadrant: Quadrant, todoID: UUID?, index: Int?, screen: Screen = .list) {
        self.quadrant = quadrant
        self.todoID = todoID
        self.index = index
        self.screen = screen
    }

    /// The way back from the create screen. From the grid: the grid, with the same quadrant
    /// highlighted, whether it was saved (into that quadrant or another, ⇧⇥ in the editor) or not.
    /// From a list, saved (`created` and `savedInto` both given): the list of the quadrant it was
    /// saved into (which may not be the browsed one), with the new todo selected, or the top row,
    /// where new todos go. Esc (or no save): back to this point unchanged.
    public func afterCreate(_ created: UUID?, savedInto quadrant: Quadrant?) -> BrowseReturn {
        guard screen == .list, let created, let quadrant else { return self }
        return BrowseReturn(quadrant: quadrant, todoID: created, index: 0)
    }
}

extension BrowseFlow {
    /// The point to come back to from a screen opened now: the grid with its highlighted quadrant,
    /// or the shown quadrant and its selected row, or, with `opening`, that todo (Enter or a click
    /// on a row) at the selected row.
    public func returnPoint(opening id: UUID? = nil) -> BrowseReturn {
        if phase == .picking, id == nil {
            return BrowseReturn(quadrant: quadrant, todoID: nil, index: nil, screen: .grid)
        }
        return BrowseReturn(quadrant: quadrant, todoID: id ?? selectedTodo?.id, index: selectedIndex)
    }

    /// Back from a screen opened from Browse: the grid with `point`'s quadrant highlighted, or
    /// `point`'s quadrant listed with its todo selected, or the row at its index (clamped) when
    /// that todo is gone (see `resumeListing`).
    public func resume(at point: BrowseReturn) {
        switch point.screen {
        case .grid: highlight(point.quadrant)
        case .list: resumeListing(point.quadrant, selecting: point.todoID, fallbackIndex: point.index)
        }
    }
}
