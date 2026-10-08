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
/// - List: ↑/↓ move the selection (clamped); Enter → `.open(id)`; `d` completes the selected
///   todo (the row is removed here, the caller writes it: `.complete(id)`); ⌫ archives it the
///   same way but without the celebration (`.archive(id)`); 1–4 switch quadrant;
///   `a` opens the archive; Esc / Shift+Tab go back to the picker; ⌘↑/⌘K and ⌘↓/⌘J move the
///   selected todo one row (`.reorder`, the caller writes the new order); ⌘1–4 move the selected
///   todo to that quadrant (`.move`: it leaves this list, which stays shown, and goes on top of
///   the other one; the caller writes it); `m` opens the move picker. Everything else is
///   swallowed.
/// - Move picker (a 2×2 over the list, for the selected todo): 1–4 (or ⌘1–4) move straight away;
///   arrows move the highlight and clamp; Enter moves to the highlighted quadrant; Esc closes only
///   the picker. The todo's own quadrant does nothing. Everything else is swallowed.
/// - Picker and list: ⌘Z takes back the last `d` / ⌫ / move of this panel: a completed todo is
///   put back where it was and the caller clears its done mark (`.restore(id)`); a moved one goes
///   back to its old quadrant and position (`.moveBack`). Several in a row undo several.
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
        /// ⌘Z: this todo is back in its list (already re-inserted); clear its done mark.
        case restore(UUID)
        /// This todo went from one quadrant to the other (already moved here, on top of `to`).
        case move(UUID, from: Quadrant, to: Quadrant)
        /// ⌘Z took back a move: this todo is in quadrant `to` again, at its old position (already
        /// moved back here); restore its old place there.
        case moveBack(UUID, to: Quadrant)
        /// The shown quadrant's rows were reordered; persist `rows`' order.
        case reorder(Quadrant)
        /// Show the archive.
        case openArchive
        /// Close the panel.
        case close
    }

    /// The key that opens the archive.
    public static let archiveKey: Character = "a"
    /// The key that marks the selected todo done (list only).
    public static let doneKey: Character = "d"
    /// The key that opens the move picker for the selected todo (list only).
    public static let moveKey: Character = "m"

    /// The small "Move to…" picker over the list: which todo, and which quadrant has the highlight.
    public struct MovePicker: Hashable, Sendable {
        public var todo: TodoSnapshot
        public var highlighted: Quadrant

        public init(todo: TodoSnapshot, highlighted: Quadrant) {
            self.todo = todo
            self.highlighted = highlighted
        }
    }

    /// Something ⌘Z can take back.
    private enum Undoable {
        /// Marked done (or archived) from `index` of its quadrant.
        case completion(TodoSnapshot, index: Int)
        /// Moved away from `index` of `todo.quadrant` (the snapshot from before the move).
        case move(TodoSnapshot, index: Int)
    }

    public private(set) var phase: Phase = .picking
    /// The highlighted (picker) or shown (list) quadrant.
    public private(set) var quadrant: Quadrant
    /// Picker: the Archive button below the grid has the highlight instead of `quadrant`.
    public private(set) var isArchiveHighlighted = false
    /// Index into `rows`; `nil` in the picker or when the list is empty.
    public private(set) var selectedIndex: Int?
    /// The open move picker, or `nil`.
    public private(set) var movePicker: MovePicker?
    private var todos: [Quadrant: [TodoSnapshot]]
    /// The completions and moves of this panel that ⌘Z can take back, oldest first.
    private var undoable: [Undoable] = []

    public init(todos: [Quadrant: [TodoSnapshot]], quadrant: Quadrant = .urgentImportant) {
        self.todos = todos
        self.quadrant = quadrant
    }

    public func count(in quadrant: Quadrant) -> Int { todos[quadrant]?.count ?? 0 }

    /// The shown quadrant's open todos.
    public var rows: [TodoSnapshot] { todos[quadrant] ?? [] }

    public var selectedTodo: TodoSnapshot? { selectedIndex.map { rows[$0] } }

    /// Whether ⌘Z has a completion or move to take back.
    public var canUndo: Bool { !undoable.isEmpty }

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
            case .undo:
                if let outcome = undo() { return outcome }
            case .escape: return close()
            default: break
            }
            return .handled
        case .listing:
            if let picker = movePicker { return handleMovePicker(key, picker) }
            switch key {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            case .enter:
                if let todo = selectedTodo { return .open(todo.id) }
            case .letter(Self.doneKey):
                if let todo = selectedTodo, complete(id: todo.id) { return .complete(todo.id) }
            case .backspace:
                if let todo = selectedTodo, complete(id: todo.id) { return .archive(todo.id) }
            case .digit(let n):
                if let picked = Quadrant(shortcutNumber: n) { choose(picked) }
            case .commandDigit(let n):
                if let todo = selectedTodo, let target = Quadrant(shortcutNumber: n), moveTodo(id: todo.id, to: target) {
                    return .move(todo.id, from: todo.quadrant, to: target)
                }
            case .letter(Self.moveKey):
                if let todo = selectedTodo { openMovePicker(id: todo.id) }
            case .letter(Self.archiveKey): return .openArchive
            case .undo:
                if let outcome = undo() { return outcome }
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

    private func handleMovePicker(_ key: QuickEntryKey, _ picker: MovePicker) -> Outcome {
        var target: Quadrant?
        switch key {
        case .digit(let n), .commandDigit(let n): target = Quadrant(shortcutNumber: n)
        case .enter: target = picker.highlighted
        case .up: movePicker?.highlighted = picker.highlighted.moved(rows: -1, columns: 0)
        case .down: movePicker?.highlighted = picker.highlighted.moved(rows: 1, columns: 0)
        case .left: movePicker?.highlighted = picker.highlighted.moved(rows: 0, columns: -1)
        case .right: movePicker?.highlighted = picker.highlighted.moved(rows: 0, columns: 1)
        case .escape: closeMovePicker()
        default: break
        }
        if let target, moveTodo(id: picker.todo.id, to: target) {
            return .move(picker.todo.id, from: picker.todo.quadrant, to: target)
        }
        return .handled
    }

    // MARK: Pointer / programmatic actions

    /// Shows a quadrant's list, selecting its first row.
    public func choose(_ quadrant: Quadrant) {
        guard phase != .closed else { return }
        self.quadrant = quadrant
        isArchiveHighlighted = false
        movePicker = nil
        phase = .listing
        selectedIndex = rows.isEmpty ? nil : 0
    }

    /// Opens the move picker for a todo of the shown list (`m`, or the row's move button),
    /// selecting it. The highlight starts on the first quadrant that isn't its own.
    public func openMovePicker(id: UUID) {
        guard phase == .listing, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
        let todo = rows[index]
        let first = Quadrant.allCases.first { $0 != todo.quadrant } ?? todo.quadrant
        movePicker = MovePicker(todo: todo, highlighted: first)
    }

    public func closeMovePicker() {
        movePicker = nil
    }

    /// Moves a todo to another quadrant: it leaves its list (the selection clamps as after `d`)
    /// and goes on top of `target`'s; the shown list stays. Closes the move picker. ⌘Z takes it
    /// back. Returns `false` (and changes nothing) for an unknown id or the todo's own quadrant.
    @discardableResult
    public func moveTodo(id: UUID, to target: Quadrant) -> Bool {
        guard phase != .closed else { return false }
        for (q, list) in todos {
            guard let index = list.firstIndex(where: { $0.id == id }) else { continue }
            guard q != target else { return false }
            let todo = list[index]
            undoable.append(.move(todo, index: index))
            removeRow(at: index, of: q)
            var moved = todo
            moved.quadrant = target
            todos[target, default: []].insert(moved, at: 0)
            movePicker = nil
            return true
        }
        return false
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
        movePicker = nil
        phase = .picking
        selectedIndex = nil
    }

    public func select(id: UUID) {
        guard phase == .listing, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    /// Removes a todo from the list (it was marked done; `undo` brings it back). The
    /// selection stays on the same todo, or, when that one was completed, on the row that moves
    /// up into its place (the new last row at the end). Returns `false` for an unknown id.
    @discardableResult
    public func complete(id: UUID) -> Bool {
        for (q, list) in todos {
            guard let index = list.firstIndex(where: { $0.id == id }) else { continue }
            undoable.append(.completion(list[index], index: index))
            removeRow(at: index, of: q)
            return true
        }
        return false
    }

    /// Takes back the most recent `complete` or `moveTodo`: the todo goes back into its (old)
    /// quadrant at its old position (clamped). The list shows that quadrant with the todo
    /// selected; the picker moves its highlight onto that quadrant. Returns `.restore` or
    /// `.moveBack` for the caller to write, or `nil` with nothing to undo.
    @discardableResult
    public func undo() -> Outcome? {
        guard phase != .closed, let last = undoable.popLast() else { return nil }
        let todo: TodoSnapshot
        let index: Int
        let outcome: Outcome
        switch last {
        case .completion(let snapshot, let at):
            (todo, index, outcome) = (snapshot, at, .restore(snapshot.id))
        case .move(let snapshot, let at):
            (todo, index, outcome) = (snapshot, at, .moveBack(snapshot.id, to: snapshot.quadrant))
            // Out of the quadrant it was moved to (unless a reload already put it back).
            for q in Quadrant.allCases where q != snapshot.quadrant {
                todos[q]?.removeAll { $0.id == snapshot.id }
            }
        }
        var list = todos[todo.quadrant] ?? []
        if !list.contains(where: { $0.id == todo.id }) {
            list.insert(todo, at: min(index, list.count))
            todos[todo.quadrant] = list
        }
        movePicker = nil
        if phase == .listing {
            choose(todo.quadrant)
            select(id: todo.id)
        } else {
            quadrant = todo.quadrant
            isArchiveHighlighted = false
        }
        return outcome
    }

    /// Replaces the data (e.g. after a failed write), keeping the selected todo when it is still
    /// there and clamping otherwise.
    public func reload(_ todos: [Quadrant: [TodoSnapshot]]) {
        let selectedID = selectedTodo?.id
        let oldIndex = selectedIndex
        self.todos = todos
        if let picker = movePicker, !rows.contains(where: { $0.id == picker.todo.id }) { movePicker = nil }
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
        movePicker = nil
        return .close
    }

    /// Takes a row out of quadrant `q`. The selection stays on the same todo, or, when that one
    /// went, on the row that moves up into its place (the new last row at the end).
    private func removeRow(at index: Int, of q: Quadrant) {
        let selectedID = selectedTodo?.id
        let removedID = todos[q]?[index].id
        todos[q]?.remove(at: index)
        guard q == quadrant, phase == .listing else { return }
        if let selectedID, selectedID != removedID {
            selectedIndex = rows.firstIndex { $0.id == selectedID }
        } else {
            selectedIndex = rows.isEmpty ? nil : min(index, rows.count - 1)
        }
    }

    private func moveSelection(by delta: Int) {
        guard let current = selectedIndex else { return }
        selectedIndex = min(max(current + delta, 0), rows.count - 1)
    }

    private func move(rows: Int, columns: Int) {
        quadrant = quadrant.moved(rows: rows, columns: columns)
    }
}

extension Quadrant {
    /// The neighbour in the 2×2 grid, clamped at its edges.
    func moved(rows: Int, columns: Int) -> Quadrant {
        let current = gridPosition
        let target = GridPosition(
            row: min(max(current.row + rows, 0), 1),
            column: min(max(current.column + columns, 0), 1)
        )
        return Quadrant(gridPosition: target) ?? self
    }
}
