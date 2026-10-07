import Foundation
import Observation

/// UI-independent state machine behind the browse panel: a 2×2 picker with open-todo counts,
/// then one quadrant's open todos as a selectable list.
///
/// Keys (`handle(_:)` returns what the caller should do):
/// - Picker: arrows move and clamp; ↓ from the bottom row highlights the Archive button below the
///   grid and ↑ comes back; 1–4 open that quadrant's list; Enter/Tab open the highlighted one (or
///   the archive: `.openArchive`); `a` opens the archive; Esc closes (`.close`). Everything else
///   is swallowed.
/// - List: ↑/↓ move the selection (clamped); Enter → `.open(id)`; Space completes the selected
///   todo (the row is removed here, the caller writes it: `.complete(id)`); ⌫ archives it the
///   same way but without the celebration (`.archive(id)`); 1–4 switch quadrant;
///   `a` opens the archive; Esc / Shift+Tab go back to the picker; ⌘↑/⌘K and ⌘↓/⌘J move the
///   selected todo one row (`.reorder`, the caller writes the new order). Everything else is
///   swallowed.
/// - Closed: every key is `.ignored`.
///
/// An opened todo's edit modal comes back here (`resumeListing`) on Esc, save or delete.
///
/// Rows keep the order they are given in (the store's order), until moved here.
@MainActor
@Observable
public final class BrowseFlow {
    public enum Phase: Hashable, Sendable { case picking, listing, closed }

    public enum Outcome: Hashable, Sendable {
        /// Not for us (the flow is closed).
        case ignored
        /// Consumed; nothing for the caller to do.
        case handled
        /// Open this todo in the edit modal.
        case open(UUID)
        /// Mark this todo done (already removed from the list).
        case complete(UUID)
        /// Put this todo in the archive without calling it done (already removed from the list).
        /// Same write as `complete`; the UI skips the celebration.
        case archive(UUID)
        /// The shown quadrant's rows were reordered; persist `rows`' order.
        case reorder(Quadrant)
        /// Show the archive.
        case openArchive
        /// Close the panel.
        case close
    }

    /// The key that opens the archive.
    public static let archiveKey: Character = "a"

    public private(set) var phase: Phase = .picking
    /// The highlighted (picker) or shown (list) quadrant.
    public private(set) var quadrant: Quadrant
    /// Picker: the Archive button below the grid has the highlight instead of `quadrant`.
    public private(set) var isArchiveHighlighted = false
    /// Index into `rows`; `nil` in the picker or when the list is empty.
    public private(set) var selectedIndex: Int?
    private var todos: [Quadrant: [TodoSnapshot]]

    public init(todos: [Quadrant: [TodoSnapshot]], quadrant: Quadrant = .urgentImportant) {
        self.todos = todos
        self.quadrant = quadrant
    }

    public func count(in quadrant: Quadrant) -> Int { todos[quadrant]?.count ?? 0 }

    /// The shown quadrant's open todos.
    public var rows: [TodoSnapshot] { todos[quadrant] ?? [] }

    public var selectedTodo: TodoSnapshot? { selectedIndex.map { rows[$0] } }

    // MARK: Keys

    @discardableResult
    public func handle(_ key: QuickEntryKey) -> Outcome {
        switch phase {
        case .closed:
            return .ignored
        case .picking:
            switch key {
            case .up:
                if isArchiveHighlighted { isArchiveHighlighted = false } else { move(rows: -1, columns: 0) }
            case .down:
                if quadrant.gridPosition.row == 1 { isArchiveHighlighted = true } else { move(rows: 1, columns: 0) }
            case .left where !isArchiveHighlighted: move(rows: 0, columns: -1)
            case .right where !isArchiveHighlighted: move(rows: 0, columns: 1)
            case .digit(let n):
                if let picked = Quadrant(shortcutNumber: n) { choose(picked) }
            case .letter(Self.archiveKey): return .openArchive
            case .enter, .tab:
                if isArchiveHighlighted { return .openArchive }
                choose(quadrant)
            case .escape: return close()
            default: break
            }
            return .handled
        case .listing:
            switch key {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            case .enter:
                if let todo = selectedTodo { return .open(todo.id) }
            case .space:
                if let todo = selectedTodo, complete(id: todo.id) { return .complete(todo.id) }
            case .backspace:
                if let todo = selectedTodo, complete(id: todo.id) { return .archive(todo.id) }
            case .digit(let n):
                if let picked = Quadrant(shortcutNumber: n) { choose(picked) }
            case .letter(Self.archiveKey): return .openArchive
            case .escape, .shiftTab: backToPicker()
            case .moveUp, .moveDown:
                if let index = selectedIndex, move(from: index, to: index + (key == .moveUp ? -1 : 1)) {
                    return .reorder(quadrant)
                }
            default: break
            }
            return .handled
        }
    }

    // MARK: Pointer / programmatic actions

    /// Shows a quadrant's list, selecting its first row.
    public func choose(_ quadrant: Quadrant) {
        guard phase != .closed else { return }
        self.quadrant = quadrant
        isArchiveHighlighted = false
        phase = .listing
        selectedIndex = rows.isEmpty ? nil : 0
    }

    /// Picker: puts the highlight on the Archive button (e.g. coming back from the archive).
    public func highlightArchive() {
        guard phase == .picking else { return }
        isArchiveHighlighted = true
    }

    /// Back from editing a todo: shows `quadrant`'s list with that todo selected, or, when it is
    /// gone from this list (deleted, moved), the row now at `fallbackIndex` (clamped).
    public func resumeListing(_ quadrant: Quadrant, selecting id: UUID?, fallbackIndex: Int?) {
        choose(quadrant)
        guard !rows.isEmpty else { return }
        if let id, let index = rows.firstIndex(where: { $0.id == id }) {
            selectedIndex = index
        } else if let fallbackIndex {
            selectedIndex = min(max(fallbackIndex, 0), rows.count - 1)
        }
    }

    /// Moves the shown list's row at `source` to `destination` (clamped); the selection follows
    /// the todo it was on. Returns `false` when nothing moved.
    @discardableResult
    public func move(from source: Int, to destination: Int) -> Bool {
        guard phase == .listing, rows.indices.contains(source) else { return false }
        let destination = min(max(destination, 0), rows.count - 1)
        guard destination != source else { return false }
        let selectedID = selectedTodo?.id
        var list = rows
        list.insert(list.remove(at: source), at: destination)
        todos[quadrant] = list
        selectedIndex = selectedID.flatMap { id in list.firstIndex { $0.id == id } }
        return true
    }

    /// Moves a todo (by id) to `destination` in the shown list; see `move(from:to:)`.
    @discardableResult
    public func move(id: UUID, to destination: Int) -> Bool {
        guard let source = rows.firstIndex(where: { $0.id == id }) else { return false }
        return move(from: source, to: destination)
    }

    public func backToPicker() {
        guard phase == .listing else { return }
        phase = .picking
        selectedIndex = nil
    }

    public func select(id: UUID) {
        guard phase == .listing, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    /// Removes a todo from the list (it was marked done). The selection stays on the same todo,
    /// or, when that one was completed, on the row that moves up into its place (the new last
    /// row at the end). Returns `false` for an unknown id.
    @discardableResult
    public func complete(id: UUID) -> Bool {
        for (q, list) in todos {
            guard let index = list.firstIndex(where: { $0.id == id }) else { continue }
            let selectedID = selectedTodo?.id
            todos[q]?.remove(at: index)
            if q == quadrant, phase == .listing {
                if let selectedID, selectedID != id {
                    selectedIndex = rows.firstIndex { $0.id == selectedID }
                } else {
                    selectedIndex = rows.isEmpty ? nil : min(index, rows.count - 1)
                }
            }
            return true
        }
        return false
    }

    /// Replaces the data (e.g. after a failed write), keeping the selected todo when it is still
    /// there and clamping otherwise.
    public func reload(_ todos: [Quadrant: [TodoSnapshot]]) {
        let selectedID = selectedTodo?.id
        let oldIndex = selectedIndex
        self.todos = todos
        guard phase == .listing else { return }
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = rows.isEmpty ? nil : min(oldIndex ?? 0, rows.count - 1)
        }
    }

    @discardableResult
    public func close() -> Outcome {
        guard phase != .closed else { return .ignored }
        phase = .closed
        selectedIndex = nil
        return .close
    }

    private func moveSelection(by delta: Int) {
        guard let current = selectedIndex else { return }
        selectedIndex = min(max(current + delta, 0), rows.count - 1)
    }

    private func move(rows: Int, columns: Int) {
        let current = quadrant.gridPosition
        let target = GridPosition(
            row: min(max(current.row + rows, 0), 1),
            column: min(max(current.column + columns, 0), 1)
        )
        quadrant = Quadrant(gridPosition: target) ?? quadrant
    }
}
