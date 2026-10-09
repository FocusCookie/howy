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
///   `n` asks for a new todo in the shown quadrant (`.newTodo`, also on an empty one; the list
///   stays as it is for coming back); `a` opens the archive; Esc / Shift+Tab go back to the picker; ⌘↑/⌘K and ⌘↓/⌘J move the
///   selected todo one row (`.reorder`, the caller writes the new order); ⌘1–4 move the selected
///   todo to that quadrant (`.move`: it leaves this list, which stays shown, and goes on top of
///   the other one; the caller writes it); `m` opens the move picker. Everything else is
///   swallowed.
/// - Move picker (a 2×2 over the list, for the selected todo): 1–4 (or ⌘1–4) move straight away;
///   arrows move the highlight and clamp; Enter moves to the highlighted quadrant; Esc closes only
///   the picker. The todo's own quadrant does nothing. Everything else is swallowed.
/// - Picker, list and Overview: ⌘Z takes back the last `d` / ⌫ / move / reorder of this panel: a
///   completed todo is put back where it was and the caller clears its done mark (`.restore(id)`);
///   a moved (or dropped) one goes back to its old quadrant and position (`.moveBack`); a reorder
///   (⌘K/⌘J, `nudge`, a drop inside one tile, a list drag between `beginReorderDrag` and
///   `endReorderDrag`) gets the quadrant's old order back (`.reorder`). Several in a row undo
///   several.
/// - Overview (all four quadrants as tiles, one focused; `o` from the picker or the list, or
///   `toggleOverview()`): every list key acts on the focused tile (`quadrant`, `rows`,
///   `selectedIndex`), except that 1–4 and ⌥1–4 focus that quadrant instead of opening its list
///   (Tab / Shift-Tab focus the next / previous quadrant in priority order, wrapping),
///   Enter opens the selected todo in the tile's editor (`.editInTile`), `n` opens a create
///   editor there for a new todo in the focused quadrant (`.createInTile`), and Esc goes back to
///   the picker with the focused quadrant highlighted (`.hideOverview`). Each tile remembers its
///   selection: focusing it again selects that todo, or the first one when it is gone.
///   With a tile editor open (`tileEditor`), only Esc and ⌥1–4 of another quadrant are ours;
///   every other key is `.ignored`, for the editor. Esc closes the editor and goes back to the
///   tile's earlier selection: an edit is discarded (`.dismissEditor(.edit(id), stash: false)`),
///   a new todo is kept as the create draft (`stash: true`). ⌥1–4 keeps either as a draft and
///   focuses there (`.dismissEditor(_, stash: true)`).
/// - Closed: every key is `.ignored`.
///
/// An opened todo's edit modal comes back here (`resumeListing`) on Esc, save or delete; so does
/// the create screen `n` opens from the list (selecting the new todo after a save).
///
/// Rows keep the order they are given in (the store's order), until moved here.
@MainActor
@Observable
public final class BrowseFlow {
    public enum Phase: Hashable, Sendable { case picking, listing, overview, closed }

    public enum Outcome: Hashable, Sendable {
        /// Not for us: the flow is closed, or (Overview) a tile editor is open and the key is the
        /// editor's.
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
        /// A quadrant's rows were reordered (⌘K/⌘J, a nudge, a drop or drag inside one tile, or ⌘Z
        /// of any of those); persist `rows(in:)` of that quadrant with `TodoStore.reorder`.
        case reorder(Quadrant)
        /// Overview drag and drop: this todo went from one quadrant to the other, to `index` of
        /// `to` (already moved here). Persist with `TodoStore.move(id:to:at:)`; ⌘Z gives `.moveBack`.
        case place(UUID, from: Quadrant, to: Quadrant, index: Int)
        /// The Overview opened: grow the panel and show the tiles.
        case showOverview
        /// The Overview closed, back to the picker: shrink the panel. A tile editor that was open
        /// is closed too; stash its edit.
        case hideOverview
        /// List: create a new todo in this quadrant (the create screen, starting in the title).
        case newTodo(Quadrant)
        /// Overview: open this todo in the focused tile's editor (it is selected there). Stash any
        /// other tile editor still open first.
        case editInTile(UUID)
        /// Overview: open a create editor for a new todo in this quadrant in its (focused) tile.
        /// Stash any other tile editor still open first.
        case createInTile(Quadrant)
        /// Overview: this tile editor closed. `stash`: keep it as a draft (focus moved to another
        /// tile, like losing panel focus, or Esc on a new todo); otherwise discard it (Esc on an edit).
        case dismissEditor(TileEditor, stash: Bool)
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
    /// The key that opens the Overview (picker and list).
    public static let overviewKey: Character = "o"
    /// The key that creates a new todo in the shown quadrant (list and Overview).
    public static let newKey: Character = "n"

    /// What the editor in the focused Overview tile is for.
    public enum TileEditor: Hashable, Sendable {
        /// Editing this todo.
        case edit(UUID)
        /// A new todo, started in this quadrant (the editor may save it into another one).
        case create(Quadrant)
    }

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
        /// `quadrant`'s order was `previousIDs` before `moved` was moved inside it.
        case reorder(Quadrant, previousIDs: [UUID], moved: UUID)
    }

    public private(set) var phase: Phase = .picking
    /// The highlighted (picker), shown (list) or focused (Overview) quadrant.
    public private(set) var quadrant: Quadrant
    /// Picker: the Archive button below the grid has the highlight instead of `quadrant`.
    public private(set) var isArchiveHighlighted = false
    /// Index into `rows`; `nil` in the picker or when the list is empty.
    public private(set) var selectedIndex: Int?
    /// The open move picker, or `nil`.
    public private(set) var movePicker: MovePicker?
    /// Overview: the editor open in the focused tile (an edit or a new todo), or `nil`.
    public private(set) var tileEditor: TileEditor?
    /// Overview: the todo open in the focused tile's editor; `nil` without one or for a new todo.
    public var editingTodoID: UUID? {
        if case .edit(let id) = tileEditor { id } else { nil }
    }
    /// Overview: the todo last selected in each quadrant's tile.
    private var rememberedSelection: [Quadrant: UUID] = [:]
    private var todos: [Quadrant: [TodoSnapshot]]
    /// The completions and moves of this panel that ⌘Z can take back, oldest first.
    private var undoable: [Undoable] = []
    /// The list's order when a pointer drag inside it began (`beginReorderDrag`).
    private var reorderDragStart: (quadrant: Quadrant, ids: [UUID], moved: UUID)?

    public init(todos: [Quadrant: [TodoSnapshot]], quadrant: Quadrant = .urgentImportant) {
        self.todos = todos
        self.quadrant = quadrant
    }

    public func count(in quadrant: Quadrant) -> Int { todos[quadrant]?.count ?? 0 }

    /// The shown (or focused) quadrant's open todos.
    public var rows: [TodoSnapshot] { todos[quadrant] ?? [] }

    /// A quadrant's open todos (the Overview's tiles).
    public func rows(in quadrant: Quadrant) -> [TodoSnapshot] { todos[quadrant] ?? [] }

    /// Overview: the selected todo of a tile: the focused tile's selection, or the one a tile
    /// would select when focused.
    public func selection(in quadrant: Quadrant) -> TodoSnapshot? {
        if phase == .overview, quadrant == self.quadrant { return selectedTodo }
        let list = rows(in: quadrant)
        return rememberedSelection[quadrant].flatMap { id in list.first { $0.id == id } } ?? list.first
    }

    /// The list or the Overview: rows are shown and selectable.
    private var showsRows: Bool { phase == .listing || phase == .overview }

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
            case .letter(Self.overviewKey): return showOverview()
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
                if let todo = selectedTodo, let target = Quadrant(shortcutNumber: n) {
                    return move(id: todo.id, toQuadrant: target)
                }
            case .letter(Self.moveKey):
                if let todo = selectedTodo { openMovePicker(id: todo.id) }
            case .letter(Self.newKey): return .newTodo(quadrant)
            case .letter(Self.archiveKey): return .openArchive
            case .letter(Self.overviewKey): return showOverview()
            case .undo:
                if let outcome = undo() { return outcome }
            case .escape, .shiftTab: backToPicker()
            case .moveUp, .moveDown:
                if let todo = selectedTodo { return nudge(id: todo.id, by: key == .moveUp ? -1 : 1) }
            default: break
            }
            return .handled
        case .overview:
            return handleOverview(key)
        }
    }

    private func handleOverview(_ key: QuickEntryKey) -> Outcome {
        if let editor = tileEditor {
            switch key {
            case .escape:
                closeEditor()
                if case .create = editor { return .dismissEditor(editor, stash: true) }
                return .dismissEditor(editor, stash: false)
            case .optionDigit(let n):
                guard let picked = Quadrant(shortcutNumber: n) else { return .handled }
                return focus(picked)
            default:
                return .ignored
            }
        }
        if case .optionDigit(let n) = key {
            if let picked = Quadrant(shortcutNumber: n) { return focus(picked) }
            return .handled
        }
        if let picker = movePicker { return handleMovePicker(key, picker) }
        switch key {
        case .up: moveSelection(by: -1)
        case .down: moveSelection(by: 1)
        case .enter:
            if let todo = selectedTodo { return openEditor(id: todo.id) }
        case .letter(Self.doneKey):
            if let todo = selectedTodo, complete(id: todo.id) { return .complete(todo.id) }
        case .backspace:
            if let todo = selectedTodo, complete(id: todo.id) { return .archive(todo.id) }
        case .digit(let n):
            if let picked = Quadrant(shortcutNumber: n) { return focus(picked) }
        case .tab, .shiftTab:
            // Cycles the focused tile in priority order (1→2→3→4→1), wrapping both ways.
            let count = Quadrant.allCases.count
            let step = key == .tab ? 1 : count - 1
            let next = (quadrant.shortcutNumber - 1 + step) % count + 1
            if let picked = Quadrant(shortcutNumber: next) { return focus(picked) }
        case .commandDigit(let n):
            if let todo = selectedTodo, let target = Quadrant(shortcutNumber: n) {
                return move(id: todo.id, toQuadrant: target)
            }
        case .letter(Self.moveKey):
            if let todo = selectedTodo { openMovePicker(id: todo.id) }
        case .letter(Self.newKey):
            tileEditor = .create(quadrant)
            return .createInTile(quadrant)
        case .letter(Self.archiveKey): return .openArchive
        case .undo:
            if let outcome = undo() { return outcome }
        case .escape: return hideOverview()
        case .moveUp, .moveDown:
            if let todo = selectedTodo { return nudge(id: todo.id, by: key == .moveUp ? -1 : 1) }
        default: break
        }
        return .handled
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
        if let target { return move(id: picker.todo.id, toQuadrant: target) }
        return .handled
    }

    // MARK: Overview

    /// The middle button: opens the Overview from the picker or the list (`.showOverview`), or
    /// closes it back to the picker (`.hideOverview`, closing any tile editor). `.ignored` when
    /// the flow is closed.
    @discardableResult
    public func toggleOverview() -> Outcome {
        switch phase {
        case .closed: .ignored
        case .overview: hideOverview()
        case .picking, .listing: showOverview()
        }
    }

    /// Focuses a quadrant's tile (⌥1–4, 1–4, a click on its header), selecting the todo last
    /// selected there or its first one. Focusing another tile closes an open tile editor (an edit
    /// or a new todo): `.dismissEditor(editor, stash: true)`; otherwise `.handled`. `.ignored`
    /// outside the Overview.
    @discardableResult
    public func focus(_ target: Quadrant) -> Outcome {
        guard phase == .overview else { return .ignored }
        movePicker = nil
        guard target != quadrant else { return .handled }
        let editor = tileEditor
        tileEditor = nil
        rememberSelection()
        movePicker = nil
        quadrant = target
        selectedIndex = rememberedIndex(in: target)
        return editor.map { .dismissEditor($0, stash: true) } ?? .handled
    }

    /// Opens a todo in its tile's editor (Enter, or a click on a row in any tile), focusing that
    /// tile and selecting it: `.editInTile(id)`. The caller stashes any other tile editor still
    /// open (also a create editor). `.ignored` outside the Overview or for an unknown id.
    @discardableResult
    public func openEditor(id: UUID) -> Outcome {
        guard phase == .overview,
              let target = Quadrant.allCases.first(where: { q in rows(in: q).contains { $0.id == id } })
        else { return .ignored }
        tileEditor = nil
        movePicker = nil
        _ = focus(target)
        select(id: id)
        tileEditor = .edit(id)
        return .editInTile(id)
    }

    /// Closes the tile editor (after the caller saved, completed or discarded it), back to the
    /// tile's list. An edit: that todo selected, or, when it left this tile, the row now in its
    /// place. A new todo: pass its id (`created`) once saved, and focus moves to the tile it was
    /// saved into with it selected; without one (discarded, stashed) the tile keeps its earlier
    /// selection. Call `reload` with the new data first when the save changed it.
    public func closeEditor(created id: UUID? = nil) {
        guard let editor = tileEditor else { return }
        tileEditor = nil
        switch editor {
        case .edit(let id):
            select(id: id)
        case .create:
            guard let id, let target = quadrant(of: id) else { return }
            _ = focus(target)
            select(id: id)
        }
    }

    /// Overview drag and drop: whether `target`'s tile takes drops. Not the focused tile while
    /// its editor (an edit or a new todo) is open (the list is hidden under it); every tile
    /// otherwise. `false` outside the Overview.
    public func canDrop(on target: Quadrant) -> Bool {
        phase == .overview && !(tileEditor != nil && target == quadrant)
    }

    /// The one rule for a drop that leaves a todo where it is: inside its own quadrant, at row
    /// `from`, insertion point `index` (clamped to `0...count`) before or right after its own row.
    /// `from` is `nil` when the todo comes from another quadrant (never a no-op).
    public nonisolated static func dropIsNoOp(from: Int?, at index: Int, count: Int) -> Bool {
        guard let from else { return false }
        let clamped = min(max(index, 0), count)
        return clamped == from || clamped == from + 1
    }

    /// Whether dropping todo `id` at insertion point `index` of `target` would leave it where it
    /// is (see `dropIsNoOp(from:at:count:)`). `false` for an unknown id.
    public func dropIsNoOp(id: UUID, on target: Quadrant, at index: Int) -> Bool {
        let list = rows(in: target)
        guard let from = list.firstIndex(where: { $0.id == id }) else { return false }
        return Self.dropIsNoOp(from: from, at: index, count: list.count)
    }

    /// Overview drag and drop: puts a todo at insertion point `index` of `target`'s tile (before
    /// the row now at `index`; 0 for a drop on the header, the row count for the end; clamped).
    /// Into another quadrant it is `.place(id, from:, to:, index:)` (⌘Z gives `.moveBack`); inside
    /// its own it reorders (`.reorder(target)`; persist `rows(in: target)`; ⌘Z gives
    /// `.reorder(target)` with the old order back), and `.handled` when it lands where it was
    /// (`dropIsNoOp`). The drop focuses `target` and selects the todo, unless a tile editor is
    /// open: then focus stays, the edited todo can't be dropped and the focused tile takes no
    /// drops (`canDrop(on:)`). `.ignored` outside the Overview, for an unknown id or a refused drop.
    @discardableResult
    public func drop(id: UUID, on target: Quadrant, at index: Int) -> Outcome {
        guard canDrop(on: target), id != editingTodoID,
              let source = quadrant(of: id),
              let from = rows(in: source).firstIndex(where: { $0.id == id })
        else { return .ignored }
        let outcome: Outcome
        if source == target {
            let count = rows(in: target).count
            guard !Self.dropIsNoOp(from: from, at: index, count: count) else { return .handled }
            // An insertion point after the todo's own row means one less once it is taken out.
            let clamped = min(max(index, 0), count)
            let previous = rows(in: target).map(\.id)
            guard reorder(target, from: from, to: clamped - (clamped > from ? 1 : 0)) else { return .handled }
            undoable.append(.reorder(target, previousIDs: previous, moved: id))
            movePicker = nil
            outcome = .reorder(target)
        } else {
            let todo = rows(in: source)[from]
            undoable.append(.move(todo, index: from))
            removeRow(at: from, of: source)
            var moved = todo
            moved.quadrant = target
            let landed = min(max(index, 0), rows(in: target).count)
            todos[target, default: []].insert(moved, at: landed)
            movePicker = nil
            outcome = .place(id, from: source, to: target, index: landed)
        }
        if tileEditor == nil {
            _ = focus(target)
            select(id: id)
        }
        return outcome
    }

    /// Moves a todo `delta` rows up (negative) or down inside its quadrant (⌘K/⌘J, and the
    /// accessibility Move Up / Move Down actions), clamped at the ends. List: only the shown
    /// quadrant's todos. Overview: any tile's; like a drop, it focuses that tile and selects the
    /// todo unless a tile editor is open, and the focused tile under an open editor (and the
    /// edited todo) refuse. Returns `.reorder(quadrant)` (⌘Z puts the old order back), `.handled`
    /// when it is already at that end, `.ignored` when refused or for an unknown id.
    @discardableResult
    public func nudge(id: UUID, by delta: Int) -> Outcome {
        guard showsRows, id != editingTodoID, let q = quadrant(of: id),
              phase == .overview ? canDrop(on: q) : q == quadrant,
              let from = rows(in: q).firstIndex(where: { $0.id == id })
        else { return .ignored }
        let previous = rows(in: q).map(\.id)
        guard reorder(q, from: from, to: from + delta) else { return .handled }
        undoable.append(.reorder(q, previousIDs: previous, moved: id))
        movePicker = nil
        if phase == .overview, tileEditor == nil {
            _ = focus(q)
            select(id: id)
        }
        return .reorder(q)
    }

    /// The quadrant holding todo `id`, or `nil`.
    private func quadrant(of id: UUID) -> Quadrant? {
        Quadrant.allCases.first { q in rows(in: q).contains { $0.id == id } }
    }

    private func showOverview() -> Outcome {
        if phase == .listing { rememberSelection() }
        isArchiveHighlighted = false
        movePicker = nil
        tileEditor = nil
        phase = .overview
        selectedIndex = rememberedIndex(in: quadrant)
        return .showOverview
    }

    private func hideOverview() -> Outcome {
        rememberSelection()
        tileEditor = nil
        movePicker = nil
        phase = .picking
        selectedIndex = nil
        return .hideOverview
    }

    private func rememberSelection() {
        if let id = selectedTodo?.id { rememberedSelection[quadrant] = id }
    }

    /// The remembered todo's row in `quadrant`, else the first; `nil` when empty.
    private func rememberedIndex(in quadrant: Quadrant) -> Int? {
        let list = rows(in: quadrant)
        guard !list.isEmpty else { return nil }
        return rememberedSelection[quadrant].flatMap { id in list.firstIndex { $0.id == id } } ?? 0
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
        guard showsRows, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
        let todo = rows[index]
        let first = Quadrant.allCases.first { $0 != todo.quadrant } ?? todo.quadrant
        movePicker = MovePicker(todo: todo, highlighted: first)
    }

    public func closeMovePicker() {
        movePicker = nil
    }

    /// The one "Move to" path (⌘1–4, the move picker, a click on a picker tile or a row's quadrant
    /// dot, the accessibility "Move to …" actions): `moveTodo(id:to:)`, returning
    /// `.move(id, from:, to:)` for the caller to write (⌘Z gives `.moveBack`), `.handled` for the
    /// todo's own quadrant, `.ignored` for an unknown id or a closed flow.
    @discardableResult
    public func move(id: UUID, toQuadrant target: Quadrant) -> Outcome {
        guard phase != .closed, let source = quadrant(of: id) else { return .ignored }
        return moveTodo(id: id, to: target) ? .move(id, from: source, to: target) : .handled
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
        guard showsRows else { return false }
        return reorder(quadrant, from: source, to: destination)
    }

    /// Moves a todo (by id) to `destination` in the shown list; see `move(from:to:)`.
    @discardableResult
    public func move(id: UUID, to destination: Int) -> Bool {
        guard let source = rows.firstIndex(where: { $0.id == id }) else { return false }
        return move(from: source, to: destination)
    }

    /// A pointer drag of `id` inside the shown list begins: remembers the order, so the drag
    /// (live `move(id:to:)` steps) can be taken back with ⌘Z as one reorder.
    public func beginReorderDrag(id: UUID) {
        guard showsRows, rows.contains(where: { $0.id == id }) else { return }
        reorderDragStart = (quadrant, rows.map(\.id), id)
    }

    /// The drag begun with `beginReorderDrag` ended: `.reorder(quadrant)` to persist when the
    /// order changed (⌘Z puts the old one back), `.handled` when it didn't, `.ignored` without a
    /// drag.
    @discardableResult
    public func endReorderDrag() -> Outcome {
        guard let start = reorderDragStart else { return .ignored }
        reorderDragStart = nil
        guard phase != .closed, rows(in: start.quadrant).map(\.id) != start.ids else { return .handled }
        undoable.append(.reorder(start.quadrant, previousIDs: start.ids, moved: start.moved))
        return .reorder(start.quadrant)
    }

    public func backToPicker() {
        guard phase == .listing else { return }
        movePicker = nil
        phase = .picking
        selectedIndex = nil
    }

    /// Selects a row of the shown list (or the focused tile); other ids are ignored.
    public func select(id: UUID) {
        guard showsRows, let index = rows.firstIndex(where: { $0.id == id }) else { return }
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

    /// Takes back the most recent `complete`, `moveTodo`, drop or reorder: the todo goes back into
    /// its (old) quadrant at its old position (clamped), or the quadrant gets its old order back.
    /// The list shows that quadrant with the todo selected; the Overview focuses its tile; the
    /// picker moves its highlight onto that quadrant. Returns `.restore`, `.moveBack` or
    /// `.reorder` for the caller to write, or `nil` with nothing to undo.
    @discardableResult
    public func undo() -> Outcome? {
        guard phase != .closed, let last = undoable.popLast() else { return nil }
        let selectedID = selectedTodo?.id
        let oldIndex = selectedIndex
        let quadrant: Quadrant
        let id: UUID
        let outcome: Outcome
        switch last {
        case .completion(let snapshot, let at):
            reinsert(snapshot, at: at)
            (quadrant, id, outcome) = (snapshot.quadrant, snapshot.id, .restore(snapshot.id))
        case .move(let snapshot, let at):
            // Out of the quadrant it was moved to (unless a reload already put it back).
            for q in Quadrant.allCases where q != snapshot.quadrant {
                todos[q]?.removeAll { $0.id == snapshot.id }
            }
            reinsert(snapshot, at: at)
            (quadrant, id, outcome) = (snapshot.quadrant, snapshot.id, .moveBack(snapshot.id, to: snapshot.quadrant))
        case .reorder(let q, let previousIDs, let moved):
            let current = todos[q] ?? []
            var byID: [UUID: TodoSnapshot] = [:]
            for todo in current { byID[todo.id] = todo }
            var restored = previousIDs.compactMap { byID[$0] }
            let listed = Set(restored.map(\.id))
            restored += current.filter { !listed.contains($0.id) }
            todos[q] = restored
            (quadrant, id, outcome) = (q, moved, .reorder(q))
        }
        // The rows changed under the selection (the moved todo may have left the focused tile):
        // keep it on the same todo, or clamp, before focusing remembers it.
        if showsRows {
            if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
                selectedIndex = index
            } else {
                selectedIndex = rows.isEmpty ? nil : min(oldIndex ?? 0, rows.count - 1)
            }
        }
        movePicker = nil
        if phase == .listing {
            choose(quadrant)
            select(id: id)
        } else if phase == .overview {
            _ = focus(quadrant)
            select(id: id)
        } else {
            self.quadrant = quadrant
            isArchiveHighlighted = false
        }
        return outcome
    }

    /// Puts a todo back into its quadrant at `index` (clamped), unless it is already there.
    private func reinsert(_ todo: TodoSnapshot, at index: Int) {
        var list = todos[todo.quadrant] ?? []
        guard !list.contains(where: { $0.id == todo.id }) else { return }
        list.insert(todo, at: min(index, list.count))
        todos[todo.quadrant] = list
    }

    /// Replaces the data (e.g. after a failed write), keeping the selected todo when it is still
    /// there and clamping otherwise.
    public func reload(_ todos: [Quadrant: [TodoSnapshot]]) {
        let selectedID = selectedTodo?.id
        let oldIndex = selectedIndex
        self.todos = todos
        if let picker = movePicker, !rows.contains(where: { $0.id == picker.todo.id }) { movePicker = nil }
        guard showsRows else { return }
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
        tileEditor = nil
        reorderDragStart = nil
        return .close
    }

    /// Takes a row out of quadrant `q`. The selection stays on the same todo, or, when that one
    /// went, on the row that moves up into its place (the new last row at the end).
    private func removeRow(at index: Int, of q: Quadrant) {
        let selectedID = selectedTodo?.id
        let removedID = todos[q]?[index].id
        todos[q]?.remove(at: index)
        guard q == quadrant, showsRows else { return }
        if let selectedID, selectedID != removedID {
            selectedIndex = rows.firstIndex { $0.id == selectedID }
        } else {
            selectedIndex = rows.isEmpty ? nil : min(index, rows.count - 1)
        }
    }

    /// Moves `q`'s row at `source` to `destination` (clamped). When `q` is shown, the selection
    /// follows the todo it was on. Returns `false` when nothing moved.
    private func reorder(_ q: Quadrant, from source: Int, to destination: Int) -> Bool {
        var list = rows(in: q)
        guard list.indices.contains(source) else { return false }
        let destination = min(max(destination, 0), list.count - 1)
        guard destination != source else { return false }
        let selectedID = selectedTodo?.id
        list.insert(list.remove(at: source), at: destination)
        todos[q] = list
        if q == quadrant { selectedIndex = selectedID.flatMap { id in list.firstIndex { $0.id == id } } }
        return true
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
