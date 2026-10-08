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
    /// Runs once the flow has finished (saved, cancelled, deleted), e.g. to clear unused staged files.
    @ObservationIgnored var didFinish: () -> Void = {}
    /// Opens attachments and file pickers for this panel (set by the app controller).
    @ObservationIgnored var presenter: AttachmentPresenter?

    /// Set when saving or deleting failed; the panel stays open so nothing typed is lost.
    private(set) var errorMessage: String?
    /// The thumbnail under the pointer.
    var hoveredAttachmentID: UUID?
    /// The attachment whose reference the caret is on, or the pointer hovers, in the note.
    var noteReferenceName: String?

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

    func requestDelete() { flow.requestDelete() }
    func cancelDelete() { flow.cancelDelete() }

    func confirmDelete() {
        flow.confirmDelete()
        finishIfNeeded()
    }

    private func finishIfNeeded() {
        switch flow.phase {
        case .saved:
            if persist() { close() } else { flow.reopen() }
        case .deleted:
            if deleteTodo() { close() } else { flow.reopen() }
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

    private func deleteTodo() -> Bool {
        guard let id = flow.todoID else { return true }
        do {
            try store.delete(id: id)
            errorMessage = nil
            return true
        } catch {
            log.error("Delete failed: \(error, privacy: .public)")
            errorMessage = "Couldn't delete this todo."
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
/// completions, moves to another quadrant, undos (⌘Z) and reorders the flow asks for.
@MainActor
@Observable
final class BrowseModel {
    let flow: BrowseFlow
    @ObservationIgnored private let store: TodoStore
    @ObservationIgnored var close: () -> Void = {}
    /// Opens a todo in the edit modal (replaces this panel).
    @ObservationIgnored var openTodo: (UUID) -> Void = { _ in }
    /// Shows the archive (replaces this panel).
    @ObservationIgnored var openArchive: () -> Void = {}

    private(set) var errorMessage: String?

    /// A todo marked done, for the view's emoji burst. `sequence` makes two in a row observable.
    struct DoneEvent: Hashable {
        let id: UUID
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
        if key == .letter(BrowseFlow.doneKey), flow.phase == .listing, let todo = flow.selectedTodo { celebrate(todo.id) }
        var outcome = BrowseFlow.Outcome.ignored
        withAnimation(.snappy(duration: 0.25)) { outcome = flow.handle(key) }
        return perform(outcome)
    }

    private func celebrate(_ id: UUID) {
        lastDone = DoneEvent(id: id, emoji: doneEmoji.next(), sequence: (lastDone?.sequence ?? 0) + 1)
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

    /// The row's move button: opens the "Move to…" picker for that todo.
    func openMovePicker(_ id: UUID) {
        withAnimation(.snappy(duration: 0.18)) { flow.openMovePicker(id: id) }
    }

    func closeMovePicker() {
        withAnimation(.snappy(duration: 0.18)) { flow.closeMovePicker() }
    }

    /// A click on a move-picker tile (or a VoiceOver "Move to" action).
    func move(_ id: UUID, to quadrant: Quadrant) {
        guard let from = flow.rows.first(where: { $0.id == id })?.quadrant else { return }
        var moved = false
        withAnimation(.snappy(duration: 0.25)) { moved = flow.moveTodo(id: id, to: quadrant) }
        if moved { _ = perform(.move(id, from: from, to: quadrant)) }
    }

    /// Moves a row while it is dragged; the order is written once the drag ends (`persistOrder`).
    func drag(_ id: UUID, to index: Int) {
        withAnimation(.snappy(duration: 0.2)) { _ = flow.move(id: id, to: index) }
    }

    /// Writes the shown list's current order.
    func persistOrder() {
        persistOrder(of: flow.quadrant)
    }

    private func perform(_ outcome: BrowseFlow.Outcome) -> Bool {
        switch outcome {
        case .ignored: return false
        case .handled: return true
        case .open(let id): openTodo(id)
        case .complete(let id), .archive(let id): persistCompletion(id)
        case .restore(let id): persistRestore(id)
        case .move(let id, _, let to): persistMove(id, to: to)
        case .moveBack(let id, let to): persistMoveBack(id, to: to)
        case .reorder(let quadrant): persistOrder(of: quadrant)
        case .openArchive: openArchive()
        case .close: close()
        }
        return true
    }

    private func persistOrder(of quadrant: Quadrant) {
        do {
            try store.reorder(flow.rows.map(\.id), in: quadrant)
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
