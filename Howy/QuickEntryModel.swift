import AppKit
import Foundation
import HowyCore
import Observation
import SwiftUI

/// Glue between the quick-entry / edit panel, `QuickEntryFlow` and `TodoStore`.
/// Rules (keys, delete prompt, empty-title hint) live in the flow; this only performs the I/O
/// the flow asks for and reports failures instead of closing over them.
@MainActor
@Observable
final class QuickEntryModel {
    /// What can be attached: a file (pasted from Finder, dropped, picked) or image data (a pasted screenshot).
    enum AttachmentSource {
        case file(URL)
        case image(Data)
    }

    let flow: QuickEntryFlow
    @ObservationIgnored private let store: TodoStore
    @ObservationIgnored var close: () -> Void = {}
    /// Esc goes back to the screen this was opened from (Browse, an Overview tile's list, the
    /// launcher) instead of closing the panel; the key hints say "back" then (set by the opener).
    @ObservationIgnored var escapeReturns = false
    /// Runs once the flow has finished (saved, cancelled, deleted), e.g. to clear unused staged files.
    @ObservationIgnored var didFinish: () -> Void = {}
    /// Opens attachments and file pickers for this panel (set by the app controller).
    @ObservationIgnored var presenter: AttachmentPresenter?

    /// Set when saving or deleting failed; the panel stays open so nothing typed is lost.
    private(set) var errorMessage: String?
    /// Create mode: the id of the todo the save added (Browse selects it on the way back).
    @ObservationIgnored private(set) var createdTodoID: UUID?
    /// The thumbnail under the pointer.
    var hoveredAttachmentID: UUID?
    /// The attachment whose reference the caret is on, or the pointer hovers, in the note.
    var noteReferenceName: String?
    /// The link at the caret in the note, and where its chip is (for the popover).
    var noteLink: NoteLinkAnchor?

    init(flow: QuickEntryFlow, store: TodoStore) {
        self.flow = flow
        self.store = store
    }

    /// Returns `true` when the key was consumed.
    func handle(_ key: QuickEntryKey) -> Bool {
        let consumed = flow.handle(key)
        performRequest()
        finishIfNeeded()
        return consumed
    }

    // MARK: Attachments

    var hoveredAttachment: TodoAttachment? {
        hoveredAttachmentID.flatMap { id in flow.attachments.first { $0.id == id } }
    }

    /// The name shown in the divider above the attachments: hovered, selected, or referenced at the caret.
    var spotlightName: String? {
        hoveredAttachment?.name ?? flow.selectedAttachment?.name ?? noteReferenceName
    }

    /// The attachment whose references the note highlights: hovered or selected.
    var highlightedName: String? {
        hoveredAttachment?.name ?? flow.selectedAttachment?.name
    }

    func url(for attachment: TodoAttachment) -> URL? {
        store.attachments?.url(for: attachment, todoID: flow.todoID)
    }

    /// Copies the sources into staging and attaches them. Returns the note references, in order.
    @discardableResult
    func attach(_ sources: [AttachmentSource]) -> [String] {
        guard let files = store.attachments else { return [] }
        var references: [String] = []
        for source in sources {
            do {
                let attachment: TodoAttachment
                switch source {
                case .file(let url):
                    let name = AttachmentNaming.unique(url.lastPathComponent, existing: flow.attachmentNames)
                    attachment = try files.stage(copying: url, as: name)
                case .image(let data):
                    attachment = try files.stage(data: data, as: AttachmentNaming.pastedName(extension: "png", existing: flow.attachmentNames))
                }
                withAnimation(.snappy(duration: 0.2)) { references.append(flow.attach(attachment)) }
                errorMessage = nil
            } catch {
                log.error("Attaching failed: \(error, privacy: .public)")
                errorMessage = "Couldn't attach that file."
            }
        }
        return references
    }

    func remove(_ attachment: TodoAttachment) {
        if hoveredAttachmentID == attachment.id { hoveredAttachmentID = nil }
        withAnimation(.snappy(duration: 0.2)) { flow.removeAttachment(id: attachment.id) }
    }

    /// Opens an attachment as Settings says, or the other way (`alternate`, ⌥).
    func open(_ attachment: TodoAttachment, alternate: Bool) {
        let mode = AttachmentOpenMode.load()
        presenterOpen(attachment, mode: alternate ? mode.other : mode)
    }

    /// Opens an attachment in a given way (context menu). Quick Look gets all of them, so ←/→ browse.
    func presenterOpen(_ attachment: TodoAttachment, mode: AttachmentOpenMode) {
        let available = flow.attachments.compactMap { item in url(for: item).map { (item.id, $0) } }
        guard let index = available.firstIndex(where: { $0.0 == attachment.id }) else {
            errorMessage = "That file is missing."
            return
        }
        flow.selectAttachment(id: attachment.id)
        presenter?.open(available.map(\.1), at: index, mode: mode)
    }

    func chooseFiles() {
        presenter?.chooseFiles { [weak self] urls in
            self?.attach(urls.map { .file($0) })
        }
    }

    // MARK: Links

    /// Opens a note link in the default browser (the panel then loses focus and closes).
    func openLink(_ link: NoteLink) {
        let url = URL(string: link.url)
            ?? link.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        guard let url else {
            errorMessage = "That link isn't a valid web address."
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func performRequest() {
        switch flow.takeRequest() {
        case .open(let attachment, let alternate): open(attachment, alternate: alternate)
        case .chooseFiles: chooseFiles()
        case nil: break
        }
    }

    func save() {
        flow.save()
        finishIfNeeded()
    }

    func complete() {
        flow.complete()
        finishIfNeeded()
    }

    private func finishIfNeeded() {
        switch flow.phase {
        case .saved:
            if persist() { close() } else { flow.reopen() }
        case .completed:
            if persist(), completeTodo() { close() } else { flow.reopen() }
        case .cancelled:
            close()
        default:
            return
        }
        if flow.isFinished { didFinish() }
    }

    private func persist() -> Bool {
        guard let draft = flow.savedDraft else { return true }
        do {
            if let id = draft.todoID {
                try store.update(id: id, title: draft.title, note: draft.note, quadrant: draft.quadrant)
                try store.setAttachments(draft.attachments, for: id) // a retry after a failure redoes only this
            } else {
                // Files first: if they fail, no todo exists yet that a retry would duplicate.
                let id = UUID()
                try store.setAttachments(draft.attachments, for: id)
                do {
                    try store.add(id: id, title: draft.title, note: draft.note, quadrant: draft.quadrant)
                    createdTodoID = id
                } catch {
                    store.attachments?.removeAll(for: id)
                    throw error
                }
            }
            errorMessage = nil
            return true
        } catch {
            log.error("Save failed: \(error, privacy: .public)")
            errorMessage = "Couldn't save. Your text is still here."
            return false
        }
    }

    private func completeTodo() -> Bool {
        guard let id = flow.todoID else { return true }
        do {
            try store.complete(id: id)
            errorMessage = nil
            return true
        } catch {
            log.error("Complete failed: \(error, privacy: .public)")
            errorMessage = "Couldn't mark this todo done."
            return false
        }
    }
}

/// Archived todos for the archive panel, reloaded after every action. Keys arrive via
/// `FloatingPanel.keyHandler` and go through `ArchiveFlow` (selection, `r`, ⌫, Esc).
@MainActor
@Observable
final class ArchiveModel {
    struct Item: Identifiable, Hashable {
        let id: UUID
        let title: String
        let quadrant: Quadrant
        let completedAt: Date
        let attachmentCount: Int
    }

    private(set) var items: [Item] = []
    let flow: ArchiveFlow
    @ObservationIgnored private let store: TodoStore
    @ObservationIgnored var close: () -> Void = {}

    init(store: TodoStore) {
        self.store = store
        flow = ArchiveFlow(ids: [])
        reload()
    }

    var selectedItem: Item? { flow.selectedID.flatMap { id in items.first { $0.id == id } } }

    /// Returns `true` when the key was consumed (every key, bar the ones that are not ours).
    func handle(_ key: QuickEntryKey) -> Bool {
        var outcome = ArchiveFlow.Outcome.handled
        withAnimation(.snappy(duration: 0.25)) { outcome = flow.handle(key) }
        switch outcome {
        case .handled: break
        case .restore(let id): write { try store.restore(id: id) }
        case .delete(let id): write { try store.delete(id: id) }
        case .close: close()
        }
        return true
    }

    func select(_ id: UUID) {
        flow.select(id: id)
    }

    func restore(_ item: Item) {
        withAnimation(.snappy(duration: 0.25)) { flow.remove(id: item.id) }
        write { try store.restore(id: item.id) }
    }

    func delete(_ item: Item) {
        withAnimation(.snappy(duration: 0.25)) { flow.remove(id: item.id) }
        write { try store.delete(id: item.id) }
    }

    /// Runs a store write and reloads the list (which also brings a row back after a failure).
    private func write(_ action: () throws -> Void) {
        do { try action() } catch { log.error("Archive write failed: \(error, privacy: .public)") }
        withAnimation(.snappy(duration: 0.25)) { reload() }
    }

    private func reload() {
        do {
            items = try store.archivedTodos().map {
                Item(
                    id: $0.id, title: $0.title, quadrant: $0.quadrant, completedAt: $0.completedAt ?? .now,
                    attachmentCount: store.attachmentList(for: $0.id).count
                )
            }
        } catch {
            log.error("Archive fetch failed: \(error, privacy: .public)")
            items = []
        }
        flow.reload(ids: items.map(\.id))
    }
}

/// Glue between the browse panel, `BrowseFlow` and `TodoStore`: performs the opens,
/// completions, moves to another quadrant, undos (⌘Z) and reorders the flow asks for, and runs
/// the Overview: the panel's resize and the editor inside the focused tile.
@MainActor
@Observable
final class BrowseModel {
    let flow: BrowseFlow
    @ObservationIgnored private let store: TodoStore
    @ObservationIgnored var close: () -> Void = {}
    /// Opens a todo in the edit modal (replaces this panel).
    @ObservationIgnored var openTodo: (UUID) -> Void = { _ in }
    /// `n` in the list: opens the create screen for a new todo in this quadrant (replaces this panel).
    @ObservationIgnored var createTodo: (Quadrant) -> Void = { _ in }
    /// Shows the archive (replaces this panel).
    @ObservationIgnored var openArchive: () -> Void = {}
    /// Grows the panel to the Overview (`true`) or shrinks it back, running `changes` inside the
    /// resize animation (or in one step, `animated: false`) and `completion` once the card has its
    /// new size (set by the app controller to `FloatingPanel.setOverview`).
    @ObservationIgnored var resizeForOverview: (
        _ expanded: Bool, _ animated: Bool, _ changes: @escaping () -> Void, _ completion: @escaping () -> Void
    ) -> Void = { _, _, changes, completion in
        changes()
        completion()
    }
    /// Makes the editor for an Overview tile: a todo opened there (`nil` when it can't be read),
    /// or a new todo (`n`).
    @ObservationIgnored var makeTileEditor: (BrowseFlow.TileEditor) -> QuickEntryModel? = { _ in nil }

    /// Where the grow into the Overview (or the shrink back) is; the view lays the tiles out from
    /// it. It lags the flow's phase while a transition runs.
    private(set) var morph = OverviewMorph()
    /// The editor open in the focused Overview tile (an edit or a new todo).
    private(set) var tileEditor: QuickEntryModel?

    private(set) var errorMessage: String?

    /// A todo marked done, for the view's emoji burst. `sequence` makes two in a row observable.
    struct DoneEvent: Hashable {
        let id: UUID
        /// The quadrant it was in (the Overview launches the emoji over that tile).
        let quadrant: Quadrant?
        let emoji: String
        let sequence: Int
    }

    private(set) var lastDone: DoneEvent?
    @ObservationIgnored private var doneEmoji = DoneEmoji()

    /// A todo moved to another quadrant (or back, on ⌘Z), for the view's badge.
    struct MoveEvent: Hashable {
        let quadrant: Quadrant
        /// ⌘Z took a move back ("Back to" instead of "Moved to").
        let isUndo: Bool
        let sequence: Int
    }

    private(set) var lastMove: MoveEvent?
    /// Each moved todo's `sortDate`s from before its moves, newest last, so ⌘Z can put it back
    /// where it was (`TodoStore.moveBack`).
    @ObservationIgnored private var sortDatesBeforeMove: [UUID: [Date]] = [:]

    init(flow: BrowseFlow, store: TodoStore) {
        self.flow = flow
        self.store = store
    }

    /// Returns `true` when the key was consumed.
    func handle(_ key: QuickEntryKey) -> Bool {
        // `d` removes the selected row inside the flow; fire the burst first so the view can
        // still measure that row.
        // A tile editor's link dialog takes every key first (Esc closes only the dialog).
        if let tileEditor, tileEditor.flow.linkDialog != nil { return tileEditor.handle(key) }
        if key == .letter(BrowseFlow.doneKey), flow.phase == .listing || flow.phase == .overview && flow.tileEditor == nil,
           let todo = flow.selectedTodo { celebrate(todo.id) }
        var outcome = BrowseFlow.Outcome.ignored
        withAnimation(.snappy(duration: 0.25)) { outcome = flow.handle(key) }
        // With a tile editor open, the keys the flow leaves alone are the editor's.
        if outcome == .ignored, let tileEditor { return tileEditor.handle(key) }
        return perform(outcome)
    }

    // MARK: Overview

    /// The middle button between the cards (or tiles).
    func toggleOverview() {
        _ = perform(flow.toggleOverview())
    }

    /// A click on a tile's header.
    func focus(_ quadrant: Quadrant) {
        var outcome = BrowseFlow.Outcome.handled
        withAnimation(.snappy(duration: 0.25)) { outcome = flow.focus(quadrant) }
        _ = perform(outcome)
    }

    /// A click on a row in any tile: opens it in that tile's editor (a new todo being written in
    /// the focused tile is kept as a draft).
    func openInTile(_ id: UUID) {
        var outcome = BrowseFlow.Outcome.handled
        withAnimation(.snappy(duration: 0.25)) { outcome = flow.openEditor(id: id) }
        _ = perform(outcome)
    }

    /// A todo dropped at insertion point `index` of a tile (0 on its header).
    func drop(_ id: UUID, on quadrant: Quadrant, at index: Int) {
        var outcome = BrowseFlow.Outcome.handled
        withAnimation(.snappy(duration: 0.25)) { outcome = flow.drop(id: id, on: quadrant, at: index) }
        _ = perform(outcome)
    }

    /// The accessibility Move Up (−1) / Move Down (+1) actions, in the list and the Overview.
    func nudge(_ id: UUID, by delta: Int) {
        var outcome = BrowseFlow.Outcome.handled
        withAnimation(.snappy(duration: 0.25)) { outcome = flow.nudge(id: id, by: delta) }
        _ = perform(outcome)
    }

    /// The panel is going away or showing another screen: keep an open tile edit as a draft.
    func stashTileEditor() {
        tileEditor?.flow.abandon()
        tileEditor = nil
    }

    private func showOverview() {
        changeMorph { $0.expand() }
    }

    private func hideOverview() {
        // Kept as a draft; it fades out with the rows.
        withAnimation(.easeIn(duration: Self.contentFadeOut)) { stashTileEditor() }
        changeMorph { $0.collapse() }
    }

    // MARK: Grow and shrink

    /// How long the content fades take: out quickly before the card changes size, in after it.
    private static let contentFadeOut: TimeInterval = 0.1
    private static let contentFadeIn: TimeInterval = 0.18

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Applies a change of `morph` (`expand`, `collapse`, or `finish` of a completed stage) inside
    /// the animation of the stage it leads to, and has that animation's completion finish it, so
    /// the stages run one after the other. A completion of a stage that was since turned around
    /// carries an old generation and does nothing (`OverviewMorph.finish`).
    private func changeMorph(_ change: (inout OverviewMorph) -> Bool) {
        var next = morph
        guard change(&next) else { return }
        let generation = next.generation
        let finish: @MainActor @Sendable () -> Void = { [weak self] in self?.changeMorph { $0.finish(generation) } }
        switch next.stage {
        case .growing, .shrinking:
            // Shells and card in one spring: the panel animates the card's frame and runs the
            // layout change in the same transaction.
            resizeForOverview(next.stage == .growing, !Self.reduceMotion, { [weak self] in self?.morph = next }, finish)
        case .hidingCounts, .hidingRows, .revealingRows, .revealingCounts:
            let reveals = next.stage == .revealingRows || next.stage == .revealingCounts
            let duration = reveals ? Self.contentFadeIn : Self.contentFadeOut
            withAnimation(reveals ? .easeOut(duration: duration) : .easeIn(duration: duration)) {
                morph = next
            } completion: {
                finish()
            }
            // A fade that changes nothing on screen might never report its completion.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1, execute: finish)
        case .compact, .expanded:
            morph = next
        }
    }

    /// Opens the tile editor for a todo (`.edit`) or a new todo (`.create`), keeping any other
    /// one still open as a draft.
    private func openTileEditor(_ kind: BrowseFlow.TileEditor) {
        if let open = tileEditor {
            if case .edit(let id) = kind, open.flow.todoID == id { return } // a click on the row being edited
            open.flow.abandon()
        }
        guard let editor = makeTileEditor(kind) else {
            tileEditor = nil
            flow.closeEditor()
            return
        }
        editor.close = { [weak self, weak editor] in
            guard let self, let editor, self.tileEditor === editor else { return }
            self.tileEditorSaved(editor)
        }
        withAnimation(.snappy(duration: 0.22)) { tileEditor = editor }
    }

    /// Esc on an edit (`stash` false: discarded), or Esc on a new todo / focus moved to another
    /// tile (kept as a draft).
    private func dismissTileEditor(stash: Bool) {
        guard let editor = tileEditor else { return }
        if stash {
            editor.flow.abandon()
        } else {
            editor.flow.cancel()
            editor.didFinish()
        }
        withAnimation(.snappy(duration: 0.22)) { tileEditor = nil }
    }

    /// ⌘↩ / ⌘D / Save / Done in the tile editor wrote the todo: back to the tile's list with the
    /// new data, the todo (or the row now in its place) selected. A new todo: focus moves to the
    /// tile it was saved into, with it selected. The write is done; when the list can't be read
    /// back (so a new todo would silently be missing from it), say so.
    private func tileEditorSaved(_ editor: QuickEntryModel) {
        withAnimation(.snappy(duration: 0.22)) {
            var refreshed = true
            do {
                flow.reload(try store.openSnapshots())
            } catch {
                log.error("Browse refresh after save failed: \(error, privacy: .public)")
                refreshed = false
            }
            let shown = flow.closeEditor(created: editor.createdTodoID)
            errorMessage = refreshed && shown ? nil : "Saved, but the list couldn't be refreshed."
            tileEditor = nil
        }
    }

    private func celebrate(_ id: UUID) {
        let quadrant = Quadrant.allCases.first { q in flow.rows(in: q).contains { $0.id == id } }
        lastDone = DoneEvent(id: id, quadrant: quadrant, emoji: doneEmoji.next(), sequence: (lastDone?.sequence ?? 0) + 1)
    }

    func choose(_ quadrant: Quadrant) {
        withAnimation(.snappy(duration: 0.25)) { flow.choose(quadrant) }
    }

    func open(_ id: UUID) {
        flow.select(id: id)
        openTodo(id)
    }

    func complete(_ id: UUID) {
        celebrate(id) // before the row goes, so the view can still find it
        var removed = false
        withAnimation(.snappy(duration: 0.25)) { removed = flow.complete(id: id) }
        if removed { persistCompletion(id) }
    }

    func select(_ id: UUID) {
        flow.select(id: id)
    }

    func closeMovePicker() {
        withAnimation(.snappy(duration: 0.18)) { flow.closeMovePicker() }
    }

    /// A click on a move-picker tile or a row's quadrant dot, or a VoiceOver "Move to" action
    /// (the flow's one "Move to" path, in the list and the Overview).
    func move(_ id: UUID, to quadrant: Quadrant) {
        var outcome = BrowseFlow.Outcome.handled
        withAnimation(.snappy(duration: 0.25)) { outcome = flow.move(id: id, toQuadrant: quadrant) }
        _ = perform(outcome)
    }

    /// A row's grip was grabbed in the list: the drag's live steps (`drag`) become one reorder
    /// that ⌘Z takes back.
    func beginReorderDrag(_ id: UUID) {
        flow.select(id: id)
        flow.beginReorderDrag(id: id)
    }

    /// Moves a row while it is dragged; the order is written once the drag ends (`endReorderDrag`).
    func drag(_ id: UUID, to index: Int) {
        withAnimation(.snappy(duration: 0.2)) { _ = flow.move(id: id, to: index) }
    }

    /// The grip was let go: writes the new order, if it changed.
    func endReorderDrag() {
        _ = perform(flow.endReorderDrag())
    }

    private func perform(_ outcome: BrowseFlow.Outcome) -> Bool {
        defer {
            // In the Overview the tile editor always matches the flow's: the same todo, or both a
            // new todo, or both gone.
            assert(
                flow.phase != .overview
                    || (tileEditor == nil) == (flow.tileEditor == nil) && tileEditor?.flow.todoID == flow.editingTodoID,
                "Tile editor out of step with BrowseFlow.tileEditor"
            )
        }
        switch outcome {
        case .ignored: return false
        case .handled: return true
        case .open(let id): openTodo(id)
        case .newTodo(let quadrant): createTodo(quadrant)
        case .complete(let id), .archive(let id): persistCompletion(id)
        case .restore(let id): persistRestore(id)
        case .move(let id, _, let to): persistMove(id, to: to)
        case .moveBack(let id, let to): persistMoveBack(id, to: to)
        case .reorder(let quadrant): persistOrder(of: quadrant)
        case .place(let id, _, let to, let index): persistPlace(id, to: to, at: index)
        case .showOverview: showOverview()
        case .hideOverview: hideOverview()
        case .editInTile(let id): openTileEditor(.edit(id))
        case .createInTile(let quadrant): openTileEditor(.create(quadrant))
        case .dismissEditor(_, let stash): dismissTileEditor(stash: stash)
        case .openArchive: openArchive()
        case .close: close()
        }
        return true
    }

    private func persistOrder(of quadrant: Quadrant) {
        do {
            // Not `rows`: an Overview drop can reorder a tile other than the focused one.
            try store.reorder(flow.rows(in: quadrant).map(\.id), in: quadrant)
            errorMessage = nil
        } catch {
            log.error("Reorder failed: \(error, privacy: .public)")
            errorMessage = "Couldn't save the new order."
            if let todos = try? store.openSnapshots() {
                withAnimation(.snappy(duration: 0.25)) { flow.reload(todos) }
            }
        }
    }

    private func persistCompletion(_ id: UUID) {
        do {
            try store.complete(id: id)
            errorMessage = nil
        } catch {
            log.error("Complete failed: \(error, privacy: .public)")
            errorMessage = "Couldn't mark this todo done."
            if let todos = try? store.openSnapshots() {
                withAnimation(.snappy(duration: 0.25)) { flow.reload(todos) }
            }
        }
    }

    private func persistMove(_ id: UUID, to quadrant: Quadrant) {
        do {
            let previous = try store.move(id: id, to: quadrant)
            sortDatesBeforeMove[id, default: []].append(previous)
            errorMessage = nil
            announceMove(to: quadrant, isUndo: false)
        } catch {
            log.error("Move failed: \(error, privacy: .public)")
            errorMessage = "Couldn't move this todo."
            if let todos = try? store.openSnapshots() {
                withAnimation(.snappy(duration: 0.25)) { flow.reload(todos) }
            }
        }
    }

    /// An Overview drop into another quadrant, at a position there; ⌘Z takes it back like a move.
    private func persistPlace(_ id: UUID, to quadrant: Quadrant, at index: Int) {
        do {
            let previous = try store.move(id: id, to: quadrant, at: index)
            sortDatesBeforeMove[id, default: []].append(previous)
            errorMessage = nil
            announceMove(to: quadrant, isUndo: false)
        } catch {
            log.error("Drop failed: \(error, privacy: .public)")
            errorMessage = "Couldn't move this todo."
            if let todos = try? store.openSnapshots() {
                withAnimation(.snappy(duration: 0.25)) { flow.reload(todos) }
            }
        }
    }

    /// ⌘Z of a move: back to the old quadrant with its old `sortDate`, so at its old position.
    private func persistMoveBack(_ id: UUID, to quadrant: Quadrant) {
        do {
            // No saved date: that move's write failed, so the store never moved it.
            if let sortDate = sortDatesBeforeMove[id]?.popLast() {
                try store.moveBack(id: id, to: quadrant, sortDate: sortDate)
            }
            errorMessage = nil
            announceMove(to: quadrant, isUndo: true)
        } catch {
            log.error("Undo move failed: \(error, privacy: .public)")
            errorMessage = "Couldn't move this todo back."
            if let todos = try? store.openSnapshots() {
                withAnimation(.snappy(duration: 0.25)) { flow.reload(todos) }
            }
        }
    }

    /// The badge over the card, and the same news for VoiceOver.
    private func announceMove(to quadrant: Quadrant, isUndo: Bool) {
        lastMove = MoveEvent(quadrant: quadrant, isUndo: isUndo, sequence: (lastMove?.sequence ?? 0) + 1)
        let verb = isUndo ? "Back to" : "Moved to"
        AccessibilityNotification.Announcement("\(verb) \(quadrant.displayName)").post()
    }

    /// ⌘Z: clears the done mark the flow just took back, keeping the todo's old position.
    private func persistRestore(_ id: UUID) {
        do {
            try store.restore(id: id, onTop: false)
            errorMessage = nil
        } catch {
            log.error("Undo done failed: \(error, privacy: .public)")
            errorMessage = "Couldn't bring this todo back."
            if let todos = try? store.openSnapshots() {
                withAnimation(.snappy(duration: 0.25)) { flow.reload(todos) }
            }
        }
    }
}
