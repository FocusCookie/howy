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
    /// ⌘T: the due-date dialog (the editor, and the editor in an Overview tile).
    case dueDate
    /// A plain letter key, lower-cased. Typing in the fields; a shortcut where there is nothing
    /// to type into (Browse: `a` opens the archive, `d` marks the selected todo done).
    case letter(Character)
    /// "?" (⇧/ on a US keyboard, mapped by its character so every layout works): the keys
    /// reference on Browse's grid, list and Overview and in the archive (`.showKeys`). Typing in
    /// the text fields, tile editors and dialogs, like `other`.
    case questionMark
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
    /// When it is due; `nil` for none.
    public var due: Date?

    public init(
        todoID: UUID? = nil, title: String, note: String, quadrant: Quadrant,
        attachments: [TodoAttachment] = [], due: Date? = nil
    ) {
        self.todoID = todoID
        self.title = title
        self.note = note
        self.quadrant = quadrant
        self.attachments = attachments
        self.due = due
    }

    /// Edit-mode source loaded from an existing todo and its committed attachments.
    public init(todo: Todo, attachments: [TodoAttachment] = []) {
        self.init(
            todoID: todo.id, title: todo.title, note: todo.note, quadrant: todo.quadrant,
            attachments: attachments, due: todo.due
        )
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
///   checklist items with it (`MarkdownTaskToggle`). ⌘O and ⌘E don't either: the editor opens /
///   edits the link at the caret (`NoteLinks`), the latter through `beginEditingLink`.
/// - Title, note: ⌥Enter goes to the attachments.
/// - Attachments: ←/→ (or h/l) select (clamped); Space/Enter ask to open the selected one, ⌥Enter to open
///   it the other way (`takeRequest()`); Enter with none asks to pick files; ⌫ removes the
///   selected one (and its references in the note); **I** (`insertKey`) inserts a chip for the
///   selected one into the note (see "Attachment chips"); Shift+Tab goes back to the note. Other
///   keys are swallowed (nothing to type into).
/// - Anywhere active: ⌘Enter saves if the trimmed title is non-empty (otherwise consumed and
///   blocked); Esc cancels.
/// - ⌘⌫ is never ours: the title and note delete to the start of the line, elsewhere it does nothing.
/// - Edit mode: ⌘D (any phase) saves the edits and marks the todo done (phase `.completed`), so it
///   goes to the archive. Like ⌘Enter it needs a non-empty title. Ignored in create mode.
/// - Once saved, completed or cancelled, every key is ignored.
///
/// Links (`linkDialog`, in the note): pasting a URL asks for its title (`beginAddingLink`), ⌘E on
/// a link edits its title and URL (`beginEditingLink`). While the dialog is open its keys come
/// first: ↩ (or ⌘↩) inserts / saves the link, Esc cancels and inserts nothing, ⇥ / ⇧⇥ switch
/// between title and URL, ⌘⌫ (editing) turns the link back into plain text. ⌘D and ⌥↩ are
/// swallowed; other keys type into the field. The result is handed to the note editor as
/// `pendingNoteEdit` (it applies it as one undo step and calls `noteEditApplied`), unless the
/// note changed in the meantime. A new link's title starts as the site's domain; with a
/// `LinkTitleLookup` the page's own title replaces it when it arrives, unless the user typed first.
///
/// Attachment chips (`attachmentDialog`, in the note): references to attachments are chips like
/// links (`NoteChips`); ⌘O / ⌥⌘O open the one at the caret, which the note editor handles itself.
/// - Pasting or dropping one file onto the note asks for the chip's title before anything is
///   attached (`beginAddingAttachment(fileName:token:isScreenshot:replacing:)`): ↩ asks the caller
///   to stage the file (`AttachmentRequest.stage(token:)`), which then hands the staged attachment
///   back (`attachStaged(_:token:)`) or reports failure (`stagingFailed(token:)`); Esc cancels and
///   nothing is staged. The title starts as the file name without its extension (selected); a
///   pasted screenshot starts empty with the placeholder "Screenshot". A blank title falls back to
///   the staged name without its extension. Several files, or one pasted over a one-line selection,
///   need no dialog: the editor inserts them itself (`NoteAttachments`).
/// - **I** in the attachments inserts the selected one at the note's remembered selection
///   (`noteSelectionChanged`, the editor reports it; the note shows it as `ghostNoteSelection`
///   while in the attachments), or at the note's end when none is remembered. A non-empty one-line
///   selection becomes the title and is replaced, without a dialog; any other selection gets the
///   chip after it, through the dialog (`beginAddingAttachment(_:replacing:)`, also for a thumbnail
///   dragged from the strip onto the note). Either way the note gets focus, the caret after the chip.
///   Esc inserts nothing; the attachment stays.
/// - ⌘E on an attachment chip edits its title only (`beginEditingAttachment`). ⌘⌫ there removes
///   the reference; when it was the attachment's last one in the note the dialog first asks
///   "Also delete the attachment?" (`isAskingToDeleteAttachment`): Y yes (the attachment goes
///   too), N or ↩ no (only the reference goes; the safe default), Esc back to the title. Nothing
///   else is typed while asking. ⌘Z in the note after a yes brings the reference back, and with it
///   the attachment (its file is only deleted on save).
/// - While the dialog is open its keys come first: ↩ (or ⌘↩) inserts / saves, Esc cancels, ⌘⌫ as
///   above (adding: the field's), ⌘D, ⌥↩ and ⇥ are swallowed; other keys type into the title.
/// - Every change goes to the editor as `pendingNoteEdit` (one undo step), as for links.
///
/// Due date (`dueDialog`): ⌘T anywhere (or `beginDueDate()`, the clock in the header) opens the
/// due-date dialog over the panel (`DueDateDialog`). While it is open its keys come first (the
/// dialog's rules): typing re-parses the phrase, ↩ (or ⌘↩) sets the date (only a valid one; an
/// empty field keeps the date already set), ⇥ / ⇧⇥ open or close the examples (↑↓ and ↩ pick
/// one there), Esc closes the examples first and then the dialog, ⌘⌫ removes a set date (without
/// one it is the field's). ⌘D and ⌥↩ are swallowed. The date goes into `due` and is saved with the
/// todo (`savedDraft.due`) and kept in a stashed draft.
///
/// Modes: `.create(quadrant)` starts in the title field on that quadrant (the caller chose it: N
/// on Browse's grid or list, "Add to Quadrant", a widget's quadrant label) and records the quadrant
/// it is saved into as last-used. `.edit` starts in the title field with the todo's values.
/// In both, Shift+Tab from the title reaches the picker to change the quadrant. Editing does not
/// change the last-used quadrant.
///
/// Drafts (with a `DraftStore`): closing without saving keeps what was typed, like Spotlight.
/// - Create mode: Esc and `abandon()` (focus loss, hotkey, replaced) stash quadrant, title, note
///   and field; the next create flow restores them, on its own quadrant (which overrides only the
///   stashed one) and never in the picker. An empty draft clears the stash. Saving clears it.
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
        /// The attachment dialog for a pasted / dropped file was confirmed: stage the file kept
        /// under `token` and hand it back with `attachStaged(_:token:)` (or `stagingFailed(token:)`).
        case stage(token: UUID)
    }

    /// **I** in the attachments: insert the selected one into the note.
    public static let insertKey: Character = "i"

    public enum Mode: Hashable, Sendable {
        /// A new todo in this quadrant, starting in the title; ⇧⇥ from the title reaches the picker.
        case create(Quadrant)
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
    public var note: String {
        didSet { if !deletedFromDialog.isEmpty { reattachReferencedDeletions() } }
    }
    /// Attachments "Also delete" took out of the list, with where they were. They come back when
    /// the note references them again (⌘Z in the editor); their files stay until the save.
    @ObservationIgnored private var deletedFromDialog: [(index: Int, attachment: TodoAttachment)] = []
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
    /// The todo's due date as edited here (saved with the todo).
    public private(set) var due: Date?
    /// The due-date dialog over the panel, while it is open.
    public private(set) var dueDialog: DueDateDialog?
    @ObservationIgnored private let dueContext: DueDateContext
    /// The link dialog over the note, while it is open.
    public private(set) var linkDialog: LinkDialog?
    /// A finished link dialog's change to the note, for the note editor to apply.
    public private(set) var pendingNoteEdit: PendingNoteEdit?
    /// The attachment dialog over the note (a chip's title), while it is open.
    public private(set) var attachmentDialog: AttachmentDialog?
    /// The note's selection as the editor last reported it (`noteSelectionChanged`), kept while
    /// the focus is elsewhere: where **I** in the attachments inserts.
    public private(set) var rememberedNoteSelection: NSRange?
    /// A confirmed pasted / dropped file waiting for the caller to stage it.
    @ObservationIgnored private var pendingStaging: PendingStaging?
    @ObservationIgnored private var nextDialogID = 0
    @ObservationIgnored private let linkTitles: (any LinkTitleLookup)?
    /// The running page-title lookup (tests await it).
    @ObservationIgnored private(set) var titleLookupTask: Task<Void, Never>?

    /// A save was attempted with an empty title and it is still empty.
    public var showsEmptyTitleHint: Bool { saveAttempted && !canSave }

    /// A restored draft that still has text (for a "Draft restored" hint).
    public var showsRestoredHint: Bool { isRestoredDraft && !isBlank }

    @ObservationIgnored private let lastUsed: any LastQuadrantStore
    @ObservationIgnored private let drafts: (any DraftStore)?

    /// `linkTitles` looks up the page title for a pasted link (none: the domain stays).
    public init(
        mode: Mode,
        lastUsed: any LastQuadrantStore,
        drafts: (any DraftStore)? = nil,
        linkTitles: (any LinkTitleLookup)? = nil,
        dueDates: DueDateContext = DueDateContext()
    ) {
        self.mode = mode
        self.lastUsed = lastUsed
        self.drafts = drafts
        self.linkTitles = linkTitles
        self.dueContext = dueDates
        switch mode {
        case .create(let start):
            quadrant = start
            if let stashed = drafts?.createDraft() {
                phase = Self.phase(for: stashed.field)
                title = stashed.title
                note = stashed.note
                attachments = stashed.attachments
                due = stashed.due
                isRestoredDraft = true
            } else {
                phase = .editingTitle
                title = ""
                note = ""
                attachments = []
            }
            // The quadrant came with the request, so the picker has nothing left to ask.
            if phase == .pickingQuadrant { phase = .editingTitle }
        case .edit(let draft):
            if let id = draft.todoID, let stashed = drafts?.editDraft(for: id) {
                phase = Self.phase(for: stashed.field)
                quadrant = stashed.quadrant
                title = stashed.title
                note = stashed.note
                attachments = stashed.attachments
                due = stashed.due
                isRestoredDraft = true
            } else {
                phase = .editingTitle
                quadrant = draft.quadrant
                title = draft.title
                note = draft.note
                attachments = draft.attachments
                due = draft.due
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
        if attachmentDialog != nil { return handleAttachmentDialogKey(key) }
        if linkDialog != nil { return handleLinkDialogKey(key) }
        if dueDialog != nil { return handleDueDialogKey(key) }
        switch key {
        case .dueDate:
            beginDueDate()
            return true
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
            case .other, .questionMark, .letter, .space, .optionEnter, .optionDigit, .backspace, .commandDelete, .undo:
                break // nothing to type into
            case .escape, .closePanel, .commandEnter, .commandDone, .dueDate: break
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
        switch key.vimArrow() {
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
        case .letter(Self.insertKey):
            if let attachment = selectedAttachment { insertIntoNote(attachment) }
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

    /// Adds an attachment (its file is already staged). The caller puts a reference in the note
    /// where it belongs (`NoteAttachments`) or leaves the attachment without one.
    public func attach(_ attachment: TodoAttachment) {
        guard !isFinished else { return }
        // With Add selected, its index now points at the first new file, which gets selected.
        attachments.append(attachment)
    }

    /// Removes an attachment and its references in the note. The selection stays in place (clamped).
    public func removeAttachment(id: UUID) {
        removeAttachment(id: id, updatingNote: true)
    }

    private func removeAttachment(id: UUID, updatingNote: Bool) {
        guard !isFinished, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let removed = attachments.remove(at: index)
        if updatingNote, !attachments.contains(where: { $0.name == removed.name }) {
            note = NoteAttachments.removeReferences(to: removed.name, in: note)
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
        closeLinkDialog()
        closeAttachmentDialog()
        dueDialog = nil
        savedDraft = QuickEntryDraft(
            todoID: todoID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note,
            quadrant: quadrant,
            attachments: attachments,
            due: due
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
        closeLinkDialog()
        closeAttachmentDialog()
        dueDialog = nil
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
        let current = StashedDraft(quadrant: quadrant, title: title, note: note, field: field, attachments: attachments, due: due)
        if case .edit(let original) = mode {
            let unchanged = original.title == title && original.note == note && original.quadrant == quadrant
                && original.attachments == attachments && original.due == due
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

    // MARK: Due date

    /// ⌘T or the clock in the header: opens the due-date dialog, starting from the current date.
    public func beginDueDate() {
        guard !isFinished, !isAbandoned, !hasDialog else { return }
        dueDialog = DueDateDialog(current: due)
    }

    /// The dialog's field changed.
    public func setDueText(_ text: String) {
        dueDialog?.setText(text, context: dueContext)
    }

    /// ↩ or Set: takes the typed date (or keeps the set one on an empty field) and closes.
    /// Does nothing while the text isn't a date. Returns whether it closed.
    @discardableResult
    public func confirmDue() -> Bool {
        guard let confirmation = dueDialog?.confirmation else { return false }
        if case .set(let date) = confirmation { due = date }
        dueDialog = nil
        return true
    }

    /// ⌘⌫ or Remove: clears the date and closes (only when one was set).
    public func removeDue() {
        guard dueDialog?.canRemove == true else { return }
        due = nil
        dueDialog = nil
    }

    /// Esc: closes the examples panel if open, else the dialog (nothing changes).
    public func cancelDue() {
        if dueDialog?.closeExamples() != true { dueDialog = nil }
    }

    /// The **?** button (and ⇥ / ⇧⇥).
    public func toggleDueExamples() {
        dueDialog?.toggleExamples()
    }

    /// A click on an example: it goes into the field.
    public func pickDueExample(_ phrase: String) {
        setDueText(phrase)
    }

    /// The current time from the injected clock (for previews and labels).
    public var now: Date { dueContext.now() }

    private func handleDueDialogKey(_ key: QuickEntryKey) -> Bool {
        switch dueDialog?.handle(key, context: dueContext) {
        case .handled: return true
        case .confirm: confirmDue()
        case .remove: removeDue()
        case .close: dueDialog = nil
        case .notOurs, nil: return false
        }
        return true
    }

    // MARK: Links

    /// The dialog for a new link's title or an existing link's title and URL.
    public struct LinkDialog: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// A pasted URL: only the title is asked for.
            case add
            /// ⌘E on a link: title and URL.
            case edit(NoteLink)
        }

        public enum Field: Hashable, Sendable { case title, url }

        public let kind: Kind
        public fileprivate(set) var title: String
        public fileprivate(set) var url: String
        /// The field with focus (only `.title` when adding).
        public fileprivate(set) var field: Field = .title
        /// The page title is being looked up (the domain is in the field meanwhile).
        public fileprivate(set) var isLookingUpTitle = false
        /// The note range the link goes into (the paste's selection, the edited link).
        let range: NSRange
        /// The note when the dialog opened; if it differs on confirm, nothing is applied.
        let note: String
        let id: Int
        fileprivate var titleWasTyped = false

        public var isEditing: Bool {
            if case .edit = kind { true } else { false }
        }
    }

    /// A change to the note from the link or attachment dialog (or **I**). `id` tells one from the next.
    public struct PendingNoteEdit: Hashable, Sendable {
        public let id: Int
        public let edit: NoteLinks.Edit
        /// For the editor's Undo menu item ("Undo Add Attachment").
        public let actionName: String
    }

    /// A URL was pasted over `range` (the selection) in the note: ask for its title.
    public func beginAddingLink(url: String, replacing range: NSRange) {
        guard canOpenLinkDialog else { return }
        nextDialogID += 1
        let id = nextDialogID
        var dialog = LinkDialog(kind: .add, title: NoteLinks.domain(of: url), url: url, range: range, note: note, id: id)
        if let linkTitles, let pageURL = URL(string: url) {
            dialog.isLookingUpTitle = true
            titleLookupTask = Task { [weak self] in
                let title = await linkTitles.title(for: pageURL)
                self?.receiveLookedUpTitle(title, dialogID: id)
            }
        }
        linkDialog = dialog
    }

    /// ⌘E (or the popover's Edit) on a link in the note.
    public func beginEditingLink(_ link: NoteLink) {
        guard canOpenLinkDialog else { return }
        nextDialogID += 1
        linkDialog = LinkDialog(
            kind: .edit(link), title: link.isBare ? "" : link.title, url: link.url,
            range: link.range, note: note, id: nextDialogID
        )
    }

    private var canOpenLinkDialog: Bool {
        !isFinished && !isAbandoned && phase == .editingNote && !hasDialog
    }

    /// A link, attachment or due-date dialog is open (its keys come first).
    public var hasDialog: Bool { linkDialog != nil || attachmentDialog != nil || dueDialog != nil }

    public func setLinkTitle(_ title: String) {
        guard var dialog = linkDialog, dialog.title != title else { return }
        dialog.title = title
        dialog.titleWasTyped = true
        linkDialog = dialog
    }

    public func setLinkURL(_ url: String) {
        guard linkDialog?.isEditing == true, linkDialog?.url != url else { return }
        linkDialog?.url = url
    }

    /// A click into a field of the dialog.
    public func focusLinkField(_ field: LinkDialog.Field) {
        guard let dialog = linkDialog, field == .title || dialog.isEditing else { return }
        linkDialog?.field = field
    }

    /// ↩: inserts the new link or saves the edited one. A blank URL (editing) removes the link.
    public func confirmLink() {
        guard let dialog = linkDialog else { return }
        switch dialog.kind {
        case .add:
            finishLinkDialog(NoteLinks.insert(title: dialog.title, url: dialog.url, replacing: dialog.range))
        case .edit(let link):
            let url = dialog.url.trimmingCharacters(in: .whitespacesAndNewlines)
            finishLinkDialog(url.isEmpty ? NoteLinks.unlink(link) : NoteLinks.replace(link, title: dialog.title, url: url))
        }
    }

    /// ⌘⌫ while editing: the link becomes its title as plain text.
    public func removeLink() {
        guard let dialog = linkDialog, case .edit(let link) = dialog.kind else { return }
        finishLinkDialog(NoteLinks.unlink(link))
    }

    /// Esc: closes the dialog without touching the note.
    public func cancelLink() {
        closeLinkDialog()
    }

    /// The note editor applied `pendingNoteEdit` with this id.
    public func noteEditApplied(id: Int) {
        if pendingNoteEdit?.id == id { pendingNoteEdit = nil }
    }

    private func finishLinkDialog(_ edit: NoteLinks.Edit) {
        guard let dialog = linkDialog else { return }
        closeLinkDialog()
        // The editor's text is the dialog's base only while the note is unchanged.
        guard note == dialog.note else { return }
        pendingNoteEdit = PendingNoteEdit(id: dialog.id, edit: edit, actionName: dialog.isEditing ? "Edit Link" : "Add Link")
    }

    private func closeLinkDialog() {
        titleLookupTask?.cancel()
        titleLookupTask = nil
        linkDialog = nil
    }

    private func receiveLookedUpTitle(_ title: String?, dialogID: Int) {
        guard var dialog = linkDialog, dialog.id == dialogID else { return }
        dialog.isLookingUpTitle = false
        if let title, !dialog.titleWasTyped { dialog.title = title }
        linkDialog = dialog
    }

    private func handleLinkDialogKey(_ key: QuickEntryKey) -> Bool {
        switch key {
        case .escape: cancelLink()
        case .enter, .commandEnter: confirmLink()
        case .tab, .shiftTab:
            if let field = linkDialog?.field, linkDialog?.isEditing == true { linkDialog?.field = field == .title ? .url : .title }
        case .commandDelete:
            guard linkDialog?.isEditing == true else { return false } // the field deletes to the line start
            removeLink()
        case .commandDone, .optionEnter: break
        default: return false
        }
        return true
    }

    // MARK: Attachment chips

    /// The dialog for an attachment chip's title: a new chip (a pasted or dropped file, **I**, a
    /// thumbnail dragged onto the note) or an existing one (⌘E).
    public struct AttachmentDialog: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// A pasted or dropped file, not attached yet: the caller keeps it under `token` and
            /// stages it only when asked (`AttachmentRequest.stage`).
            case addIncoming(token: UUID)
            /// An attachment the todo already has (**I**, a thumbnail dragged from the strip).
            case addAttached(TodoAttachment)
            /// ⌘E on a chip: only its title changes.
            case edit(AttachmentChip)
        }

        public let kind: Kind
        /// The file's name with its extension (the subtitle; never edited here).
        public let fileName: String
        public fileprivate(set) var title: String
        /// Shown while the title field is empty ("Screenshot" for a pasted screenshot); a blank
        /// title falls back to the file name without its extension.
        public let placeholder: String
        /// ⌘⌫ removed the attachment's last reference: "Also delete the attachment?" (Yes / No).
        public fileprivate(set) var isAskingToDeleteAttachment = false
        /// The note range the chip goes into (the paste's selection, the edited chip).
        let range: NSRange
        /// The note when the dialog opened; if it differs on confirm, nothing is applied.
        let note: String
        let id: Int

        /// A thumbnail rather than a file icon.
        public var isImage: Bool { AttachmentNaming.isImage(fileName) }

        public var isEditing: Bool {
            if case .edit = kind { true } else { false }
        }
    }

    /// A confirmed pasted / dropped file the caller is staging.
    private struct PendingStaging {
        let token: UUID
        let title: String
        let range: NSRange
        let note: String
        let id: Int
    }

    /// The note editor's selection changed (it reports every change): remembered for **I** and
    /// the ghost caret.
    public func noteSelectionChanged(_ selection: NSRange) {
        guard selection.location != NSNotFound, selection != rememberedNoteSelection else { return }
        rememberedNoteSelection = selection
    }

    /// While in the attachments: where **I** would insert, for the note to show as a ghost caret
    /// (or a tinted selection). The note's end when nothing is remembered. Nil elsewhere.
    public var ghostNoteSelection: NSRange? {
        phase == .browsingAttachments ? clampedNoteSelection : nil
    }

    private var clampedNoteSelection: NSRange {
        let length = (note as NSString).length
        guard let remembered = rememberedNoteSelection else { return NSRange(location: length, length: 0) }
        let location = min(remembered.location, length)
        return NSRange(location: location, length: min(remembered.length, length - location))
    }

    private var attachmentNameSet: Set<String> { Set(attachments.map(\.name)) }

    /// A file pasted or dropped over `range` in the note: ask for the chip's title. Nothing is
    /// attached until ↩ (then `AttachmentRequest.stage(token:)`); Esc drops it.
    public func beginAddingAttachment(fileName: String, token: UUID, isScreenshot: Bool = false, replacing range: NSRange) {
        guard canOpenAttachmentDialog else { return }
        let defaultTitle = NoteAttachments.defaultTitle(for: fileName)
        openAttachmentDialog(
            kind: .addIncoming(token: token), fileName: fileName, title: isScreenshot ? "" : defaultTitle,
            placeholder: isScreenshot ? "Screenshot" : defaultTitle, range: range
        )
    }

    /// An attachment the todo already has goes into the note over `range` (a thumbnail dropped
    /// onto the note, **I**): ask for the chip's title.
    public func beginAddingAttachment(_ attachment: TodoAttachment, replacing range: NSRange) {
        guard canOpenAttachmentDialog else { return }
        let defaultTitle = NoteAttachments.defaultTitle(for: attachment.name)
        openAttachmentDialog(kind: .addAttached(attachment), fileName: attachment.name, title: defaultTitle,
                             placeholder: defaultTitle, range: range)
    }

    /// ⌘E (or the popover's Edit) on an attachment chip: its title.
    public func beginEditingAttachment(_ chip: AttachmentChip) {
        guard canOpenAttachmentDialog else { return }
        openAttachmentDialog(kind: .edit(chip), fileName: chip.name, title: chip.title,
                             placeholder: NoteAttachments.defaultTitle(for: chip.name), range: chip.range)
    }

    private var canOpenAttachmentDialog: Bool {
        !isFinished && !isAbandoned && phase == .editingNote && !hasDialog
    }

    private func openAttachmentDialog(kind: AttachmentDialog.Kind, fileName: String, title: String, placeholder: String, range: NSRange) {
        nextDialogID += 1
        attachmentDialog = AttachmentDialog(kind: kind, fileName: fileName, title: title, placeholder: placeholder,
                                            range: range, note: note, id: nextDialogID)
    }

    public func setAttachmentTitle(_ title: String) {
        guard attachmentDialog?.isAskingToDeleteAttachment == false, attachmentDialog?.title != title else { return }
        attachmentDialog?.title = title
    }

    /// ↩ (or Add / Save): inserts the chip, saves the title, or for a pasted file asks for it to be
    /// staged first. While asking about the attachment, ↩ is No.
    public func confirmAttachment() {
        guard let dialog = attachmentDialog else { return }
        if dialog.isAskingToDeleteAttachment { return answerDeleteAttachment(false) }
        switch dialog.kind {
        case .addIncoming(let token):
            closeAttachmentDialog()
            pendingStaging = PendingStaging(token: token, title: dialog.title, range: dialog.range, note: dialog.note, id: dialog.id)
            request = .stage(token: token)
        case .addAttached(let attachment):
            finishAttachmentDialog(NoteAttachments.insert(attachment, title: dialog.title, replacing: dialog.range, in: dialog.note))
        case .edit(let chip):
            finishAttachmentDialog(NoteAttachments.retitle(chip, title: dialog.title))
        }
    }

    /// The caller staged the confirmed file (`AttachmentRequest.stage`): it is attached and its
    /// chip goes into the note, unless the note changed meanwhile (then it is only attached).
    /// Ignored for any other token (e.g. a cancelled dialog).
    public func attachStaged(_ attachment: TodoAttachment, token: UUID) {
        guard let staging = pendingStaging, staging.token == token, !isFinished else { return }
        pendingStaging = nil
        attach(attachment)
        guard note == staging.note else { return }
        let edit = NoteAttachments.insert(attachment, title: staging.title, replacing: staging.range, in: staging.note)
        pendingNoteEdit = PendingNoteEdit(id: staging.id, edit: edit, actionName: "Add Attachment")
    }

    /// Staging the confirmed file failed: nothing goes into the note.
    public func stagingFailed(token: UUID) {
        if pendingStaging?.token == token { pendingStaging = nil }
    }

    /// ⌘⌫ (or Remove) while editing a chip: removes the reference, or first asks about the
    /// attachment when this is its last reference in the note.
    public func removeAttachmentReference() {
        guard let dialog = attachmentDialog, case .edit(let chip) = dialog.kind, !dialog.isAskingToDeleteAttachment else { return }
        if NoteAttachments.isLastReference(chip, in: dialog.note, attachmentNames: attachmentNameSet) {
            attachmentDialog?.isAskingToDeleteAttachment = true
        } else {
            finishAttachmentDialog(NoteAttachments.remove(chip, in: dialog.note))
        }
    }

    /// The answer to "Also delete the attachment?": the reference goes either way; yes removes
    /// the attachment too (only if the note is still the one the dialog opened on).
    public func answerDeleteAttachment(_ alsoDelete: Bool) {
        guard let dialog = attachmentDialog, dialog.isAskingToDeleteAttachment, case .edit(let chip) = dialog.kind else { return }
        let applies = note == dialog.note
        finishAttachmentDialog(NoteAttachments.remove(chip, in: dialog.note))
        guard alsoDelete, applies else { return }
        // The editor takes the chip out with the pending edit (one undo step), so the note stays.
        for attachment in attachments where attachment.name == chip.name {
            if let index = attachments.firstIndex(of: attachment) { deletedFromDialog.append((index, attachment)) }
            removeAttachment(id: attachment.id, updatingNote: false)
        }
    }

    /// The note references a deleted attachment again (⌘Z took the removal back): it is attached
    /// again, at its old place. Its file is still there; the save is what deletes files.
    private func reattachReferencedDeletions() {
        let names = Set(deletedFromDialog.map(\.attachment.name))
        let referenced = Set(AttachmentReference.matches(in: note, names: names).map(\.name))
        guard !referenced.isEmpty, !isFinished else { return }
        for entry in deletedFromDialog where referenced.contains(entry.attachment.name) {
            if !attachments.contains(where: { $0.name == entry.attachment.name }) {
                attachments.insert(entry.attachment, at: min(entry.index, attachments.count))
            }
        }
        deletedFromDialog.removeAll { referenced.contains($0.attachment.name) }
    }

    /// Esc: back from the question to the title, else closes the dialog without touching the note.
    public func cancelAttachment() {
        if attachmentDialog?.isAskingToDeleteAttachment == true {
            attachmentDialog?.isAskingToDeleteAttachment = false
        } else {
            closeAttachmentDialog()
        }
    }

    /// **I**: the attachment into the note at the remembered selection (see the type's doc).
    private func insertIntoNote(_ attachment: TodoAttachment) {
        let selection = clampedNoteSelection
        phase = .editingNote
        if let edit = NoteAttachments.insert(attachment, titledBySelection: selection, in: note, attachmentNames: attachmentNameSet) {
            nextDialogID += 1
            pendingNoteEdit = PendingNoteEdit(id: nextDialogID, edit: edit, actionName: "Add Attachment")
            return
        }
        // After the selection, and never inside a chip.
        let end = NSRange(location: NSMaxRange(selection), length: 0)
        let widened = NoteChips.widen(end, in: note, attachmentNames: attachmentNameSet)
        beginAddingAttachment(attachment, replacing: NSRange(location: NSMaxRange(widened), length: 0))
    }

    private func finishAttachmentDialog(_ edit: NoteLinks.Edit) {
        guard let dialog = attachmentDialog else { return }
        closeAttachmentDialog()
        guard note == dialog.note else { return }
        let action = switch dialog.kind {
        case .edit: edit.replacement.isEmpty ? "Remove Attachment" : "Edit Attachment"
        case .addIncoming, .addAttached: "Add Attachment"
        }
        pendingNoteEdit = PendingNoteEdit(id: dialog.id, edit: edit, actionName: action)
    }

    private func closeAttachmentDialog() {
        attachmentDialog = nil
    }

    private func handleAttachmentDialogKey(_ key: QuickEntryKey) -> Bool {
        if attachmentDialog?.isAskingToDeleteAttachment == true {
            switch key {
            case .letter("y"): answerDeleteAttachment(true)
            case .enter, .letter("n"): answerDeleteAttachment(false) // ↩ is the safe answer
            case .escape: cancelAttachment()
            default: break // nothing to type into
            }
            return true
        }
        switch key {
        case .escape: cancelAttachment()
        case .enter, .commandEnter: confirmAttachment()
        case .commandDelete:
            guard attachmentDialog?.isEditing == true else { return false } // the field deletes to the line start
            removeAttachmentReference()
        case .commandDone, .optionEnter, .tab, .shiftTab: break
        default: return false
        }
        return true
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
