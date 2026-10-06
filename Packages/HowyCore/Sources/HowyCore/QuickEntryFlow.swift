import Foundation
import Observation

/// A key event the quick-entry modal forwards to `QuickEntryFlow.handle(_:)`.
public enum QuickEntryKey: Hashable, Sendable {
    case up, down, left, right
    /// A digit key (0–9). Only 1–4 mean something, and only in the picker.
    case digit(Int)
    case enter
    case tab
    case shiftTab
    case commandEnter
    /// ⌘⌫: ask to delete the edited todo (edit mode only).
    case commandDelete
    case escape
    /// A plain Space. Text in the fields; "complete" in the browse list.
    case space
    /// ⌘↑ or ⌘K: move the selected row up (browse list). Text fields keep their own meaning.
    case moveUp
    /// ⌘↓ or ⌘J: move the selected row down (browse list).
    case moveDown
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

    public init(todoID: UUID? = nil, title: String, note: String, quadrant: Quadrant) {
        self.todoID = todoID
        self.title = title
        self.note = note
        self.quadrant = quadrant
    }

    /// Edit-mode source loaded from an existing todo.
    public init(todo: Todo) {
        self.init(todoID: todo.id, title: todo.title, note: todo.note, quadrant: todo.quadrant)
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
/// Phases: `pickingQuadrant → editingTitle → editingNote → saved | cancelled`.
///
/// Key handling (`handle(_:)` returns `true` when the key was consumed; `false` means
/// "let the focused control do its default", e.g. type the character):
/// - Picker: arrows move on the 2×2 grid and **clamp** at the edges (no wrap);
///   1–4 choose a quadrant and jump to the title; Enter/Tab go to the title.
/// - Title: Enter/Tab go to the note; Shift+Tab goes back to the picker.
/// - Note: Enter is a line break (not consumed); Tab not consumed; Shift+Tab goes to the title.
/// - Anywhere active: ⌘Enter saves if the trimmed title is non-empty (otherwise consumed and
///   blocked); Esc cancels.
/// - Create mode: ⌘⌫ (any phase) clears the draft (title and note) and returns to the picker.
/// - Edit mode: ⌘⌫ (any phase) shows a delete prompt. While it is shown, Enter or ⌘⌫ confirms
///   (phase `.deleted`), ⌘Enter is ignored, and every other key only dismisses the prompt. All keys
///   are consumed, so nothing changes behind the prompt.
/// - Once saved, deleted or cancelled, every key is ignored.
///
/// Modes: `.create` starts in the picker on the preselected / last-used quadrant and records the
/// chosen quadrant as last-used on save. `.edit` starts in the title field with the todo's values;
/// Shift+Tab from the title reaches the picker to change the quadrant. Editing does not change
/// the last-used quadrant.
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
    public enum Mode: Hashable, Sendable {
        /// `preselected` overrides the last-used quadrant (e.g. a widget's quadrant label tap).
        case create(preselected: Quadrant? = nil)
        case edit(QuickEntryDraft)
    }

    public enum Phase: Hashable, Sendable {
        case pickingQuadrant, editingTitle, editingNote, saved, cancelled
        /// Edit mode: the user confirmed deleting the todo.
        case deleted
    }

    public let mode: Mode
    public private(set) var phase: Phase
    /// The highlighted / chosen quadrant.
    public var quadrant: Quadrant
    public var title: String
    public var note: String
    /// Set once `phase == .saved`.
    public private(set) var savedDraft: QuickEntryDraft?
    /// The "Delete this todo?" prompt is showing (edit mode only).
    public private(set) var isConfirmingDelete = false
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
        case .create(let preselected):
            if let stashed = drafts?.createDraft() {
                phase = Self.phase(for: stashed.field)
                quadrant = preselected ?? stashed.quadrant
                title = stashed.title
                note = stashed.note
                isRestoredDraft = true
            } else {
                phase = .pickingQuadrant
                quadrant = preselected ?? startQuadrant.resolve(lastUsed: lastUsed.load())
                title = ""
                note = ""
            }
        case .edit(let draft):
            if let id = draft.todoID, let stashed = drafts?.editDraft(for: id) {
                phase = Self.phase(for: stashed.field)
                quadrant = stashed.quadrant
                title = stashed.title
                note = stashed.note
                isRestoredDraft = true
            } else {
                phase = .editingTitle
                quadrant = draft.quadrant
                title = draft.title
                note = draft.note
            }
        }
    }

    public var todoID: UUID? {
        if case .edit(let draft) = mode { draft.todoID } else { nil }
    }

    public var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    public var isFinished: Bool { phase == .saved || phase == .cancelled || phase == .deleted }

    public var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Keys

    @discardableResult
    public func handle(_ key: QuickEntryKey) -> Bool {
        guard !isFinished, !isAbandoned else { return false }
        if isConfirmingDelete {
            switch key {
            case .enter, .commandDelete: confirmDelete()
            case .commandEnter: break
            default: cancelDelete()
            }
            return true
        }
        switch key {
        case .escape:
            cancel()
            return true
        case .commandEnter:
            save()
            return true
        case .commandDelete:
            if isEditing { requestDelete() } else { clearDraft() }
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
            case .shiftTab, .moveUp, .moveDown: return false
            case .other, .space: break // nothing to type into
            case .escape, .commandEnter, .commandDelete: break
            }
            return true
        case .editingTitle:
            switch key {
            case .enter, .tab: phase = .editingNote
            case .shiftTab: phase = .pickingQuadrant
            default: return false
            }
            return true
        case .editingNote:
            if key == .shiftTab {
                phase = .editingTitle
                return true
            }
            return false
        case .saved, .cancelled, .deleted:
            return false
        }
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
        guard !isFinished, phase != .saved, phase != .cancelled, phase != .deleted else { return }
        self.phase = phase
    }

    /// Saves if the title is non-empty. Returns whether it saved.
    @discardableResult
    public func save() -> Bool {
        guard !isFinished else { return false }
        guard canSave else {
            saveAttempted = true
            return false
        }
        savedDraft = QuickEntryDraft(
            todoID: todoID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note,
            quadrant: quadrant
        )
        if !isEditing { lastUsed.save(quadrant) }
        setStash(nil)
        phase = .saved
        return true
    }

    // MARK: Delete confirmation

    /// Shows the delete prompt (edit mode only).
    public func requestDelete() {
        guard !isFinished, isEditing else { return }
        isConfirmingDelete = true
    }

    public func cancelDelete() { isConfirmingDelete = false }

    /// Confirms a shown delete prompt: phase becomes `.deleted`. Ignored without a prompt.
    public func confirmDelete() {
        guard !isFinished, isConfirmingDelete else { return }
        isConfirmingDelete = false
        setStash(nil)
        phase = .deleted
    }

    /// Undoes `.saved` / `.deleted` when the caller could not carry it out (e.g. the store threw),
    /// so the user keeps what they typed. Back in the title field of an unfinished flow.
    public func reopen() {
        guard phase == .saved || phase == .deleted else { return }
        savedDraft = nil
        isConfirmingDelete = false
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

    /// Create mode: drop the draft (title and note) and start over in the picker.
    public func clearDraft() {
        guard !isFinished, !isEditing else { return }
        title = ""
        note = ""
        saveAttempted = false
        isRestoredDraft = false
        setStash(nil)
        phase = .pickingQuadrant
    }

    // MARK: Drafts

    private var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func stashCurrent() {
        let field: StashedDraft.Field = switch phase {
        case .editingTitle: .title
        case .editingNote: .note
        default: .quadrant
        }
        let current = StashedDraft(quadrant: quadrant, title: title, note: note, field: field)
        if case .edit(let original) = mode {
            let unchanged = original.title == title && original.note == note && original.quadrant == quadrant
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
