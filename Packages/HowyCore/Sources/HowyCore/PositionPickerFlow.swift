import CoreGraphics
import Foundation
import Observation

/// UI-independent state machine behind the position picker: ⌘⇧P in any panel shows a 3×3 grid
/// of spots on the screen (`PanelSlot`) over the panel's content, which stays as it is (a
/// half-typed todo is kept).
///
/// The selection starts on the slot nearest to where the card is now; `current` is the slot the
/// card is in, if it is in one exactly (a dragged card is in none).
///
/// Keys (`handle(_:)` returns what the caller should do):
/// - ←↑↓→ or h j k l move the selection. It stops at the grid's edges (no wrap-around).
/// - ↩ → `.commit(slot)`: move the panel there (and remember it).
/// - Esc, or ⌘⇧P again → `.cancel`: close the picker, the panel stays where it is.
/// - Everything else is swallowed (`.handled`), so typing never reaches the content underneath.
@MainActor
@Observable
public final class PositionPickerFlow {
    public enum Outcome: Hashable, Sendable {
        /// Consumed; nothing for the caller to do.
        case handled
        /// Move the panel to this slot and close the picker.
        case commit(PanelSlot)
        /// Close the picker, leaving the panel where it is.
        case cancel
    }

    /// The highlighted slot; ↩ moves the panel there.
    public private(set) var selected: PanelSlot
    /// The slot the card is in now, or `nil` when it was dragged somewhere else.
    public let current: PanelSlot?

    public init(selected: PanelSlot, current: PanelSlot?) {
        self.selected = selected
        self.current = current
    }

    /// Starts on the slot nearest to `position` (a card of `cardSize` on a screen whose visible
    /// frame is `visible`).
    public convenience init(position: PanelPosition, cardSize: CGSize, in visible: CGRect) {
        let current = PanelPlacement.slot(at: position, in: visible)
        self.init(selected: current ?? PanelPlacement.nearestSlot(to: position, cardSize: cardSize, in: visible), current: current)
    }

    @discardableResult
    public func handle(_ key: QuickEntryKey) -> Outcome {
        switch key.vimArrow(horizontal: true) {
        case .up: move(rows: -1, columns: 0)
        case .down: move(rows: 1, columns: 0)
        case .left: move(rows: 0, columns: -1)
        case .right: move(rows: 0, columns: 1)
        case .enter: return .commit(selected)
        case .escape, .openPositionPicker: return .cancel
        default: break
        }
        return .handled
    }

    private func move(rows: Int, columns: Int) {
        if let next = PanelSlot.at(row: selected.row + rows, column: selected.columnIndex + columns) {
            selected = next
        }
    }
}
