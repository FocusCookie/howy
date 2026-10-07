import Foundation
import Observation

/// UI-independent state machine behind the archive panel: the archived todos (newest first) with
/// one selected row.
///
/// Keys (`handle(_:)` returns what the caller should do):
/// - ↑/↓ move the selection (clamped).
/// - `r` → `.restore(id)`: bring the selected todo back; the row is removed here, the caller
///   writes it.
/// - ⌫ / ⌘⌫ → `.delete(id)`: delete the selected todo for good; the row is removed here, the
///   caller writes it.
/// - Esc → `.close`. Everything else is swallowed (`.handled`): there is nothing to type into.
///
/// After a removal the selection stays on the row that moves up into the gap (the new last row
/// at the end), so repeated `r` or ⌫ walks down the list.
@MainActor
@Observable
public final class ArchiveFlow {
    public enum Outcome: Hashable, Sendable {
        /// Consumed; nothing for the caller to do.
        case handled
        /// Restore this todo (already removed from the list).
        case restore(UUID)
        /// Delete this todo permanently (already removed from the list).
        case delete(UUID)
        /// Close the panel (or go back to where the archive was opened from).
        case close
    }

    /// The key that restores the selected todo.
    public static let restoreKey: Character = "r"

    /// The archived todos' ids, in display order.
    public private(set) var ids: [UUID]
    /// Index into `ids`; `nil` when the list is empty.
    public private(set) var selectedIndex: Int?

    public init(ids: [UUID]) {
        self.ids = ids
        selectedIndex = ids.isEmpty ? nil : 0
    }

    public var selectedID: UUID? { selectedIndex.map { ids[$0] } }

    // MARK: Keys

    @discardableResult
    public func handle(_ key: QuickEntryKey) -> Outcome {
        switch key {
        case .up: moveSelection(by: -1)
        case .down: moveSelection(by: 1)
        case .letter(Self.restoreKey):
            if let id = selectedID, remove(id: id) { return .restore(id) }
        case .backspace, .commandDelete:
            if let id = selectedID, remove(id: id) { return .delete(id) }
        case .escape: return .close
        default: break
        }
        return .handled
    }

    // MARK: Pointer / programmatic actions

    public func select(id: UUID) {
        guard let index = ids.firstIndex(of: id) else { return }
        selectedIndex = index
    }

    /// Removes a row (restored or deleted). The selection stays on the same todo, or, when that
    /// one went, on the row that moves up into its place. Returns `false` for an unknown id.
    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard let index = ids.firstIndex(of: id) else { return false }
        let selectedID = selectedID
        ids.remove(at: index)
        if let selectedID, selectedID != id {
            selectedIndex = ids.firstIndex(of: selectedID)
        } else {
            selectedIndex = ids.isEmpty ? nil : min(index, ids.count - 1)
        }
        return true
    }

    /// Replaces the data (after a write, or a failed one), keeping the selected todo when it is
    /// still there and clamping otherwise.
    public func reload(ids: [UUID]) {
        let selectedID = selectedID
        let oldIndex = selectedIndex
        self.ids = ids
        if let selectedID, let index = ids.firstIndex(of: selectedID) {
            selectedIndex = index
        } else {
            selectedIndex = ids.isEmpty ? nil : min(oldIndex ?? 0, ids.count - 1)
        }
    }

    private func moveSelection(by delta: Int) {
        guard let current = selectedIndex else { return }
        selectedIndex = min(max(current + delta, 0), ids.count - 1)
    }
}
