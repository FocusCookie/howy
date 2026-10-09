import Foundation

/// Where a screen opened from Browse's list (the edit screen, the create screen of `n`) goes back
/// to: a quadrant's list with a todo selected. Take one with `BrowseFlow.returnPoint`, pick the
/// way back with `afterCreate(_:savedInto:)` once the screen closes, and apply it to the new
/// Browse with `BrowseFlow.resume(at:)`.
public struct BrowseReturn: Hashable, Sendable {
    public let quadrant: Quadrant
    /// The todo to select; `nil` (e.g. an empty list) selects the row at `index`, or nothing.
    public let todoID: UUID?
    /// The row to select when `todoID` is gone from the list (deleted, moved); clamped.
    public let index: Int?
    /// Browse itself was opened from the launcher, so leaving it goes back there.
    public let viaLauncher: Bool

    public init(quadrant: Quadrant, todoID: UUID?, index: Int?, viaLauncher: Bool) {
        self.quadrant = quadrant
        self.todoID = todoID
        self.index = index
        self.viaLauncher = viaLauncher
    }

    /// The way back from the create screen. Saved (`created` and `savedInto` both given): the list
    /// of the quadrant it was saved into (which may not be the browsed one, ⇧⇥ in the editor),
    /// with the new todo selected, or the top row, where new todos go. Esc (or no save): back to
    /// this point unchanged.
    public func afterCreate(_ created: UUID?, savedInto quadrant: Quadrant?) -> BrowseReturn {
        guard let created, let quadrant else { return self }
        return BrowseReturn(quadrant: quadrant, todoID: created, index: 0, viaLauncher: viaLauncher)
    }
}

extension BrowseFlow {
    /// The point to come back to from a screen opened now: the shown quadrant and its selected
    /// row, or, with `opening`, that todo (Enter or a click on a row) at the selected row.
    public func returnPoint(opening id: UUID? = nil, viaLauncher: Bool) -> BrowseReturn {
        BrowseReturn(
            quadrant: quadrant, todoID: id ?? selectedTodo?.id, index: selectedIndex, viaLauncher: viaLauncher
        )
    }

    /// Back from a screen opened from the list: shows `point`'s quadrant with its todo selected,
    /// or the row at its index (clamped) when that todo is gone (see `resumeListing`).
    public func resume(at point: BrowseReturn) {
        resumeListing(point.quadrant, selecting: point.todoID, fallbackIndex: point.index)
    }
}
