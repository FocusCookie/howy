import Foundation
import Observation

/// A key event the quick-entry modal forwards to `QuickEntryFlow.handle(_:)`.
public enum QuickEntryKey: Hashable, Sendable {
    case up, down, left, right
    /// A digit key (0–9). Only 1–4 mean something, and only in the picker.
    case digit(Int)
    /// ⌘ + a digit key (0–9): move the selected todo to that quadrant (Browse list, 1–4 only).
    case commandDigit(Int)
    /// ⌥1–4 (mapped by key code): focus that quadrant in Browse's Overview, also from its tile
    /// editor. Everywhere else it is plain typing (the Option character) for the text fields.
    case optionDigit(Int)
    case enter
    case tab
    case shiftTab
    case commandEnter
    /// ⌘⌫: delete the selected todo for good (archive only). Text fields delete to the line start.
    case commandDelete
    /// ⌘D: mark the edited todo done (edit mode only), which moves it to the archive.
    case commandDone
    case escape
    /// ⌘W (or ⌘Esc): close the whole panel from any screen. The panel handles it before any flow does.
    case closePanel
    /// A plain Space. Text in the fields; "open" in the attachments.
    case space
    /// ⌘↑ or ⌘K: move the selected row up (browse list). Text fields keep their own meaning.
    case moveUp
    /// ⌘↓ or ⌘J: move the selected row down (browse list).
    case moveDown
    /// ⌘Z: take back the last "done" (browse). Text fields keep their own undo.
    case undo
    /// ⌥↩: into the attachments (title, note); open the other way (attachments).
    case optionEnter
    /// ⌘+ or ⌘= (also ⌘⇧=): make the panel bigger. The panel handles it before any flow does.
    case zoomIn
    /// ⌘-: make the panel smaller. The panel handles it before any flow does.
    case zoomOut
    /// ⌘0: the panel back to 100 %. The panel handles it before any flow does.
    case zoomReset
    /// A plain ⌫. Deletes text in the fields; removes the selected attachment.
    case backspace
    /// A plain letter key, lower-cased. Typing in the fields; a shortcut where there is nothing
    /// to type into (Browse: `a` opens the archive, `d` marks the selected todo done).
    case letter(Character)
    /// Any other key that is plain typing (letters, shifted keys, backspace...). The text field
    /// handles it, except where the flow has nothing to type into (picker, delete prompt).
    case other
}

/// The values the modal produces (and, in edit mode, starts from).
public struct QuickEntryDraft: Hashable, Sendable {
    /// `nil` for a new todo; the edited todo's id in edit mode.
    public var todoID: UUID?
    public var title: String
    public var note: String
    public var quadrant: Quadrant
    public var attachments: [TodoAttachment]

    public init(todoID: UUID? = nil, title: String, note: String, quadrant: Quadrant, attachments: [TodoAttachment] = []) {
        self.todoID = todoID
        self.title = title
        self.note = note
        self.quadrant = quadrant
        self.attachments = attachments
    }

    /// Edit-mode source loaded from an existing todo and its committed attachments.
    public init(todo: Todo, attachments: [TodoAttachment] = []) {
        self.init(todoID: todo.id, title: todo.title, note: todo.note, quadrant: todo.quadrant, attachments: attachments)
    }
}

/// Remembers the quadrant last used to create a todo.
public protocol LastQuadrantStore: AnyObject {
    func load() -> Quadrant?
    func save(_ quadrant: Quadrant)
}

/// `LastQuadrantStore` backed by `UserDefaults`.
public final class UserDefaultsLastQuadrantStore: LastQuadrantStore {
    public static let defaultKey = "lastUsedQuadrant"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsLastQuadrantStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> Quadrant? {
        Quadrant(rawValue: defaults.integer(forKey: key))
    }

    public func save(_ quadrant: Quadrant) {
        defaults.set(quadrant.rawValue, forKey: key)
    }
}

/// UI-independent state machine behind the quick-entry and edit modal.
///
/// Phases: `pickingQuadrant → editingTitle → editingNote (↔ browsingAttachments) → saved | cancelled`.
///
/// Key handling (`handle(_:)` returns `true` when the key was consumed; `false` means
/// "let the focused control do its default", e.g. type the character):
/// - Picker: arrows move on the 2×2 grid and **clamp** at the edges (no wrap);
///   1–4 choose a quadrant and jump to the title; Enter/Tab go to the title.
/// - Title: Enter/Tab go to the note; Shift+Tab goes back to the picker.
/// - Note: Enter is a line break (not consumed); Tab not consumed; Shift+Tab goes to the title.
///   ⇧⌘L never reaches the flow (`KeyMapping` leaves it unmapped): the note editor toggles
///   checklist items with it (`MarkdownTaskToggle`).
/// - Title, note: ⌥Enter goes to the attachments.
/// - Attachments: ←/→ select (clamped); Space/Enter ask to open the selected one, ⌥Enter to open
///   it the other way (`takeRequest()`); Enter with none asks to pick files; ⌫ removes the
///   selected one (and its references in the note); Shift+Tab goes back to the note. Other keys
///   are swallowed (nothing to type into).
/// - Anywhere active: ⌘Enter saves if the trimmed title is non-empty (otherwise consumed and
///   blocked); Esc cancels.
/// - ⌘⌫ is never ours: the title and note delete to the start of the line, elsewhere it does nothing.
/// - Edit mode: ⌘D (any phase) saves the edits and marks the todo done (phase `.completed`), so it
///   goes to the archive. Like ⌘Enter it needs a non-empty title. Ignored in create mode.
/// - Once saved, completed or cancelled, every key is ignored.
///
/// Modes: `.create` starts in the picker on the preselected / last-used quadrant and records the
/// chosen quadrant as last-used on save. With `startingInTitle` it starts in the title instead,
/// for callers that picked the quadrant themselves. `.edit` starts in the title field with the
/// todo's values; Shift+Tab from the title reaches the picker to change the quadrant. Editing
/// does not change the last-used quadrant.
///
/// Drafts (with a `DraftStore`): closing without saving keeps what was typed, like Spotlight.
/// - Create mode: Esc and `abandon()` (focus loss, hotkey, replaced) stash quadrant, title, note
///   and field; the next create flow restores them. A `preselected` quadrant overrides only the
///   stashed quadrant. An empty draft clears the stash. Saving clears it.
/// - Edit mode: `abandon()` stashes a changed edit for that todo id and the next edit of the same
///   todo restores it. Esc discards (and clears the stash), as do saving and deleting.
@MainActor
@Observable
public final class QuickEntryFlow {
    /// What the attachment keys ask the caller to do.
    public enum AttachmentRequest: Hashable, Sendable {
        /// Open this attachment the way Settings says, or the other way (`alternate`, ⌥).
        case open(TodoAttachment, alternate: Bool)
        /// Show a file picker; the chosen files are attached without a note reference.
        case chooseFiles
    }

    public enum Mode: Hashable, Sendable {
        /// `preselected` overrides the last-used quadrant (e.g. a widget's quadrant label tap).
        /// `startingInTitle` skips the picker for a caller that already chose the quadrant
        /// (e.g. the menu bar's "Add to Quadrant"); ⇧⇥ from the title still reaches the picker.
        case create(preselected: Quadrant? = nil, startingInTitle: Bool = false)
        case edit(QuickEntryDraft)
    }

    public enum Phase: Hashable, Sendable {
        case pickingQuadrant, editingTitle, editingNote, browsingAttachments, saved, cancelled
        /// Edit mode: ⌘D marked the todo done. `savedDraft` holds the edits to save first.
        case completed
    }

    public let mode: Mode
    public private(set) var phase: Phase
    /// The highlighted / chosen quadrant.
    public var quadrant: Quadrant
    public var title: String
    public var note: String
    /// The attachments, in the order they were added. Changed via `attach` / `removeAttachment`.
    public private(set) var attachments: [TodoAttachment]
    /// The selection while `phase == .browsingAttachments`: an attachment, or `attachments.count`
    /// for the Add button after them (the only stop when there are none).
    public private(set) var selectedAttachmentIndex: Int?
    /// Something for the caller to do with attachments (open one, pick files); see `takeRequest()`.
    public private(set) var request: AttachmentRequest?
    /// Set once `phase == .saved` or `.completed`.
    public private(set) var savedDraft: QuickEntryDraft?
    @ObservationIgnored private var saveAttempted = false
    /// The values came from a stashed draft, not from scratch / the stored todo.
    public private(set) var isRestoredDraft = false
    /// `abandon()` ran: the modal is gone.
    @ObservationIgnored private var isAbandoned = false

    /// A save was attempted with an empty title and it is still empty.
    public var showsEmptyTitleHint: Bool { saveAttempted && !canSave }

    /// A restored draft that still has text (for a "Draft restored" hint).
    public var showsRestoredHint: Bool { isRestoredDraft && !isBlank }

    @ObservationIgnored private let lastUsed: any LastQuadrantStore
    @ObservationIgnored private let drafts: (any DraftStore)?

    /// `startQuadrant` (Settings) decides where a fresh create flow starts when nothing is preselected.
    public init(
        mode: Mode,
        lastUsed: any LastQuadrantStore,
        drafts: (any DraftStore)? = nil,
        startQuadrant: NewTodoQuadrant = .lastUsed
    ) {
        self.mode = mode
        self.lastUsed = lastUsed
        self.drafts = drafts
        switch mode {
        case .create(let preselected, let startingInTitle):
            if let stashed = drafts?.createDraft() {
                phase = Self.phase(for: stashed.field)
                quadrant = preselected ?? stashed.quadrant
                title = stashed.title
                note = stashed.note
                attachments = stashed.attachments
                isRestoredDraft = true
            } else {
                phase = .pickingQuadrant
                quadrant = preselected ?? startQuadrant.resolve(lastUsed: lastUsed.load())
                title = ""
                note = ""
                attachments = []
            }
            // The quadrant came with the request, so the picker has nothing left to ask.
            if startingInTitle, phase == .pickingQuadrant { phase = .editingTitle }
        case .edit(let draft):
            if let id = draft.todoID, let stashed = drafts?.editDraft(for: id) {
                phase = Self.phase(for: stashed.field)
                quadrant = stashed.quadrant
                title = stashed.title
                note = stashed.note
                attachments = stashed.attachments
                isRestoredDraft = true
            } else {
                phase = .editingTitle
                quadrant = draft.quadrant
                title = draft.title
                note = draft.note
                attachments = draft.attachments
            }
        }
    }

    public var todoID: UUID? {
        if case .edit(let draft) = mode { draft.todoID } else { nil }
    }

    public var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    public var isFinished: Bool { phase == .saved || phase == .cancelled || phase == .completed }

    public var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Keys

    @discardableResult
    public func handle(_ key: QuickEntryKey) -> Bool {
        guard !isFinished, !isAbandoned else { return false }
        switch key {
        case .escape:
            cancel()
            return true
        case .commandEnter:
            save()
            return true
        case .commandDone:
            complete()
            return true
        default:
            break
        }

        switch phase {
        case .pickingQuadrant:
            switch key {
            case .up: move(rows: -1, columns: 0)
            case .down: move(rows: 1, columns: 0)
            case .left: move(rows: 0, columns: -1)
            case .right: move(rows: 0, columns: 1)
            case .digit(let n):
                if let picked = Quadrant(shortcutNumber: n) { choose(picked) }
            case .enter, .tab: phase = .editingTitle
            case .shiftTab, .moveUp, .moveDown, .commandDigit: return false
            case .other, .letter, .space, .optionEnter, .optionDigit, .backspace, .commandDelete, .undo:
                break // nothing to type into
            case .escape, .closePanel, .commandEnter, .commandDone: break
            case .zoomIn, .zoomOut, .zoomReset: return false // the panel's, not the flow's
            }
            return true
        case .editingTitle:
            switch key {
            case .enter, .tab: phase = .editingNote
            case .shiftTab: phase = .pickingQuadrant
            case .optionEnter: enterAttachments()
            default: return false
            }
            return true
        case .editingNote:
            switch key {
            case .shiftTab: phase = .editingTitle
            case .optionEnter: enterAttachments()
            default: return false
            }
            return true
        case .browsingAttachments:
            handleAttachmentKey(key)
            return true
        case .saved, .cancelled, .completed:
            return false
        }
    }

    private func handleAttachmentKey(_ key: QuickEntryKey) {
        switch key {
        case .left: moveAttachmentSelection(by: -1)
        case .right: moveAttachmentSelection(by: 1)
        case .space, .enter, .optionEnter:
            if let attachment = selectedAttachment {
                request = .open(attachment, alternate: key == .optionEnter)
            } else if key != .optionEnter {
                request = .chooseFiles
            }
        case .backspace:
            if let attachment = selectedAttachment { removeAttachment(id: attachment.id) }
        case .shiftTab: phase = .editingNote
        default: break
        }
    }

    private func enterAttachments() {
        if selectedAttachmentIndex == nil { selectedAttachmentIndex = 0 }
        phase = .browsingAttachments
    }

    /// ←/→ through the attachments and then the Add button, clamped at both ends.
    private func moveAttachmentSelection(by delta: Int) {
        let index = selectedAttachmentIndex ?? 0
        selectedAttachmentIndex = min(max(index + delta, 0), attachments.count)
    }

    // MARK: Attachments

    /// The names already used, for naming a new attachment (`AttachmentNaming`).
    public var attachmentNames: [String] { attachments.map(\.name) }

    /// Adds an attachment (its file is already staged). Returns the Markdown reference for the
    /// note; the caller inserts it where it belongs (paste, drop on the note) or ignores it.
    @discardableResult
    public func attach(_ attachment: TodoAttachment) -> String {
        guard !isFinished else { return "" }
        // With Add selected, its index now points at the first new file, which gets selected.
        attachments.append(attachment)
        return AttachmentReference.markdown(for: attachment)
    }

    /// Removes an attachment and its references in the note. The selection stays in place (clamped).
    public func removeAttachment(id: UUID) {
        guard !isFinished, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments.remove(at: index)
        if !attachments.contains(where: { $0.name == removed.name }) {
            note = AttachmentReference.removing(name: removed.name, from: note)
        }
        if let selected = selectedAttachmentIndex, selected > index || selected == attachments.count {
            // Keep the same attachment selected, or stay on the last one (Add once none are left).
            selectedAttachmentIndex = selected > index ? selected - 1 : max(attachments.count - 1, 0)
        }
    }

    /// Selects an attachment (e.g. a click) without changing the phase.
    public func selectAttachment(id: UUID) {
        selectedAttachmentIndex = attachments.firstIndex { $0.id == id } ?? selectedAttachmentIndex
    }

    /// The selected attachment while browsing them (`nil` on the Add button).
    public var selectedAttachment: TodoAttachment? {
        guard phase == .browsingAttachments, let index = selectedAttachmentIndex,
              attachments.indices.contains(index) else { return nil }
        return attachments[index]
    }

    /// True while browsing the attachments with the Add button selected.
    public var isAddSelected: Bool {
        phase == .browsingAttachments && selectedAttachmentIndex == attachments.count
    }

    /// Hands over the pending request (once).
    public func takeRequest() -> AttachmentRequest? {
        defer { request = nil }
        return request
    }

    // MARK: Pointer / programmatic actions

    /// Chooses a quadrant and jumps to the title (same as pressing its digit).
    public func choose(_ quadrant: Quadrant) {
        guard !isFinished else { return }
        self.quadrant = quadrant
        phase = .editingTitle
    }

    /// Moves focus to a phase, e.g. when a field is clicked. Ignores finished phases.
    public func focus(_ phase: Phase) {
        guard !isFinished, phase != .saved, phase != .cancelled, phase != .completed else { return }
        if phase == .browsingAttachments { return enterAttachments() }
        self.phase = phase
    }

    /// Saves if the title is non-empty. Returns whether it saved.
    @discardableResult
    public func save() -> Bool {
        finish(as: .saved)
    }

    /// Edit mode: saves the edits and marks the todo done (phase `.completed`) if the title is
    /// non-empty. Returns whether it finished.
    @discardableResult
    public func complete() -> Bool {
        guard isEditing else { return false }
        return finish(as: .completed)
    }

    private func finish(as finished: Phase) -> Bool {
        guard !isFinished else { return false }
        guard canSave else {
            saveAttempted = true
            return false
        }
        savedDraft = QuickEntryDraft(
            todoID: todoID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note,
            quadrant: quadrant,
            attachments: attachments
        )
        if !isEditing { lastUsed.save(quadrant) }
        setStash(nil)
        phase = finished
        return true
    }

    /// Undoes `.saved` / `.completed` when the caller could not carry it out (e.g. the store threw),
    /// so the user keeps what they typed. Back in the title field of an unfinished flow.
    public func reopen() {
        guard phase == .saved || phase == .completed else { return }
        savedDraft = nil
        phase = .editingTitle
    }

    /// Esc: create mode keeps the draft for next time, edit mode discards the changes.
    public func cancel() {
        guard !isFinished else { return }
        if isEditing { setStash(nil) } else { stashCurrent() }
        phase = .cancelled
    }

    /// The modal went away without Esc or save (focus loss, hotkey, replaced by another panel):
    /// keep what was typed for the next open. The phase stays as it was (the view may still be
    /// fading out), but the flow takes no further input. Ignored once the flow has finished.
    public func abandon() {
        guard !isFinished, !isAbandoned else { return }
        stashCurrent()
        isAbandoned = true
    }

    // MARK: Drafts

    private var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
    }

    private func stashCurrent() {
        let field: StashedDraft.Field = switch phase {
        case .editingTitle: .title
        case .editingNote, .browsingAttachments: .note
        default: .quadrant
        }
        let current = StashedDraft(quadrant: quadrant, title: title, note: note, field: field, attachments: attachments)
        if case .edit(let original) = mode {
            let unchanged = original.title == title && original.note == note && original.quadrant == quadrant
                && original.attachments == attachments
            setStash(unchanged ? nil : current)
        } else {
            setStash(isBlank ? nil : current)
        }
    }

    private func setStash(_ draft: StashedDraft?) {
        guard let drafts else { return }
        switch mode {
        case .create: drafts.setCreateDraft(draft)
        case .edit(let original):
            if let id = original.todoID { drafts.setEditDraft(draft, for: id) }
        }
    }

    private static func phase(for field: StashedDraft.Field) -> Phase {
        switch field {
        case .quadrant: .pickingQuadrant
        case .title: .editingTitle
        case .note: .editingNote
        }
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
