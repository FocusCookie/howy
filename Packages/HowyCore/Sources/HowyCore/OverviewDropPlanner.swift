import CoreGraphics
import Foundation

/// Where a todo dragged over an Overview tile would land.
public struct OverviewDropPlan: Hashable, Sendable {
    /// Insertion point in the tile's rows, `0...rowCount` (0: the header or above the first row).
    public let index: Int
    /// The drop would leave the todo where it is (its own row, or the gap right after it):
    /// draw no line; `BrowseFlow.drop` answers `.handled` for it.
    public let isNoOp: Bool
    /// Where to draw the insertion line (the middle of the gap above row `index`), in the same
    /// space as the inputs and kept 1 pt inside the list; `nil` when `isNoOp`.
    public let lineY: CGFloat?

    public init(index: Int, isNoOp: Bool, lineY: CGFloat?) {
        self.index = index
        self.isNoOp = isNoOp
        self.lineY = lineY
    }
}

/// The Overview's drop geometry, without per-row frames (rows are lazy, so only the ones in view
/// have frames): row `i`'s top is `listFrame.minY - scrollOffset + i * rowPitch`.
public enum OverviewDropPlanner {
    /// How far below the header's bottom edge still counts as "on the header" (top of the tile).
    public static let headerSlop: CGFloat = 4

    /// The insertion point for a pointer at `pointY` over one tile.
    ///
    /// All values are in one coordinate space with y growing **downwards** (SwiftUI's; e.g. a
    /// named space around the tiles).
    /// - Parameters:
    ///   - pointY: the pointer's y.
    ///   - headerFrame: the tile's header; a point above `headerFrame.maxY + headerSlop` lands at
    ///     index 0. `nil` when unknown.
    ///   - listFrame: the visible (clipped) list area: the scroll view's frame.
    ///   - scrollOffset: how far the list is scrolled down (content offset, ≥ 0): row 0's top is
    ///     `listFrame.minY - scrollOffset`.
    ///   - rowPitch: row height plus the spacing between rows (fixed for all rows).
    ///   - rowHeight: one row's height.
    ///   - rowCount: the tile's rows (the dragged todo included when it comes from this tile).
    ///   - draggedFromIndex: the dragged todo's row in this tile, or `nil` when it comes from
    ///     another tile.
    public static func plan(
        pointY: CGFloat,
        headerFrame: CGRect?,
        listFrame: CGRect,
        scrollOffset: CGFloat,
        rowPitch: CGFloat,
        rowHeight: CGFloat,
        rowCount: Int,
        draggedFromIndex: Int?
    ) -> OverviewDropPlan {
        let count = max(rowCount, 0)
        let top = listFrame.minY - scrollOffset
        let index: Int
        if let headerFrame, pointY <= headerFrame.maxY + headerSlop {
            index = 0
        } else if rowPitch > 0 {
            // The gap nearest the pointer: past a row's middle means below it.
            let gap = Int(((pointY - top - rowHeight / 2) / rowPitch).rounded(.down)) + 1
            index = min(max(gap, 0), count)
        } else {
            index = 0
        }
        if BrowseFlow.dropIsNoOp(from: draggedFromIndex, at: index, count: count) {
            return OverviewDropPlan(index: index, isNoOp: true, lineY: nil)
        }
        let spacing = max(rowPitch - rowHeight, 0)
        let y = top + CGFloat(index) * rowPitch - spacing / 2
        let lower = listFrame.minY + 1
        let upper = max(listFrame.maxY - 1, lower)
        return OverviewDropPlan(index: index, isNoOp: false, lineY: min(max(y, lower), upper))
    }
}
