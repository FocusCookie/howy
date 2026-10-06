import Foundation
import Testing
@testable import HowyCore

final class MemoryLastQuadrantStore: LastQuadrantStore {
    var stored: Quadrant?
    init(_ stored: Quadrant? = nil) { self.stored = stored }
    func load() -> Quadrant? { stored }
    func save(_ quadrant: Quadrant) { stored = quadrant }
}

@MainActor
@Suite struct QuickEntryFlowTests {
    func makeCreate(last: Quadrant? = nil, preselected: Quadrant? = nil) -> (QuickEntryFlow, MemoryLastQuadrantStore) {
        let memory = MemoryLastQuadrantStore(last)
        return (QuickEntryFlow(mode: .create(preselected: preselected), lastUsed: memory), memory)
    }

    // MARK: picker

    @Test func createStartsInPickerWithDefaultQuadrant() {
        let (flow, _) = makeCreate()
        #expect(flow.phase == .pickingQuadrant)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.title == "")
        #expect(flow.note == "")
        #expect(flow.savedDraft == nil)
    }

    @Test func rowMoveKeysAreLeftToTheTextFields() {
        let (flow, _) = makeCreate()
        #expect(!flow.handle(.moveUp))
        flow.handle(.enter)
        #expect(flow.phase == .editingTitle)
        #expect(!flow.handle(.moveDown))
        flow.handle(.enter)
        #expect(!flow.handle(.moveUp))
        #expect(flow.phase == .editingNote)
    }

    @Test func createPreselectsLastUsedQuadrant() {
        let (flow, _) = makeCreate(last: .urgentUnimportant)
        #expect(flow.quadrant == .urgentUnimportant)
    }

    @Test func explicitPreselectionWinsOverLastUsed() {
        let (flow, _) = makeCreate(last: .urgentUnimportant, preselected: .notUrgentImportant)
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.phase == .pickingQuadrant)
    }

    @Test func arrowsMoveAroundTheGrid() {
        let (flow, _) = makeCreate()
        #expect(flow.handle(.right))
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.handle(.down))
        #expect(flow.quadrant == .notUrgentUnimportant)
        #expect(flow.handle(.left))
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.handle(.up))
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.phase == .pickingQuadrant)
    }

    @Test(arguments: [
        (Quadrant.urgentImportant, QuickEntryKey.up),
        (.urgentImportant, .left),
        (.notUrgentImportant, .up),
        (.notUrgentImportant, .right),
        (.urgentUnimportant, .down),
        (.urgentUnimportant, .left),
        (.notUrgentUnimportant, .down),
        (.notUrgentUnimportant, .right),
    ])
    func arrowsClampAtEdges(start: Quadrant, key: QuickEntryKey) {
        let (flow, _) = makeCreate(preselected: start)
        #expect(flow.handle(key), "edge arrows are still consumed")
        #expect(flow.quadrant == start)
    }

    @Test func enterInPickerGoesToTitle() {
        let (flow, _) = makeCreate(last: .notUrgentUnimportant)
        #expect(flow.handle(.enter))
        #expect(flow.phase == .editingTitle)
        #expect(flow.quadrant == .notUrgentUnimportant)
    }

    @Test(arguments: [(1, Quadrant.urgentImportant), (2, .notUrgentImportant), (3, .urgentUnimportant), (4, .notUrgentUnimportant)])
    func digitChoosesQuadrantAndJumpsToTitle(digit: Int, expected: Quadrant) {
        let (flow, _) = makeCreate(last: .notUrgentUnimportant)
        #expect(flow.handle(.digit(digit)))
        #expect(flow.quadrant == expected)
        #expect(flow.phase == .editingTitle)
    }

    @Test(arguments: [0, 5, 9])
    func otherDigitsAreSwallowedInPicker(digit: Int) {
        let (flow, _) = makeCreate()
        #expect(flow.handle(.digit(digit)), "nothing to type into: consumed so it doesn't beep")
        #expect(flow.phase == .pickingQuadrant)
        #expect(flow.quadrant == .urgentImportant)
    }

    // MARK: fields

    @Test func digitsAndArrowsInTitleAreTextNotCommands() {
        let (flow, _) = makeCreate()
        flow.handle(.digit(1))
        #expect(!flow.handle(.digit(3)))
        #expect(!flow.handle(.left))
        #expect(!flow.handle(.down))
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.phase == .editingTitle)
    }

    @Test(arguments: [QuickEntryKey.tab, .enter])
    func tabOrEnterInTitleMovesToNote(key: QuickEntryKey) {
        let (flow, _) = makeCreate()
        flow.handle(.enter)
        flow.title = "Buy milk"
        #expect(flow.handle(key))
        #expect(flow.phase == .editingNote)
    }

    @Test func enterInNoteIsNewlineNotACommand() {
        let (flow, _) = makeCreate()
        flow.handle(.enter)
        flow.title = "T"
        flow.handle(.tab)
        flow.note = "line 1"
        #expect(!flow.handle(.enter), "not consumed: the text view inserts the line break")
        #expect(flow.phase == .editingNote)
        #expect(flow.savedDraft == nil)
    }

    @Test func shiftTabWalksBackwards() {
        let (flow, _) = makeCreate()
        flow.handle(.enter)
        flow.handle(.tab)
        #expect(flow.handle(.shiftTab))
        #expect(flow.phase == .editingTitle)
        #expect(flow.handle(.shiftTab))
        #expect(flow.phase == .pickingQuadrant)
        #expect(!flow.handle(.shiftTab))
        #expect(flow.phase == .pickingQuadrant)
    }

    // MARK: save / cancel

    @Test func commandEnterSavesFromTitle() {
        let (flow, memory) = makeCreate()
        flow.handle(.digit(3))
        flow.title = "  Reply to Bob  "
        #expect(flow.handle(.commandEnter))
        #expect(flow.phase == .saved)
        #expect(flow.savedDraft == QuickEntryDraft(todoID: nil, title: "Reply to Bob", note: "", quadrant: .urgentUnimportant))
        #expect(memory.stored == .urgentUnimportant)
    }

    @Test func commandEnterSavesFromNote() {
        let (flow, memory) = makeCreate()
        flow.handle(.digit(4))
        flow.title = "Read"
        flow.handle(.enter)
        flow.note = "- chapter 1\n- chapter 2"
        #expect(flow.handle(.commandEnter))
        #expect(flow.phase == .saved)
        #expect(flow.savedDraft == QuickEntryDraft(todoID: nil, title: "Read", note: "- chapter 1\n- chapter 2", quadrant: .notUrgentUnimportant))
        #expect(memory.stored == .notUrgentUnimportant)
    }

    @Test(arguments: ["", "   ", "\n"])
    func emptyTitleBlocksSave(title: String) {
        let (flow, memory) = makeCreate(last: .notUrgentImportant)
        flow.handle(.digit(1))
        flow.title = title
        #expect(!flow.canSave)
        #expect(flow.handle(.commandEnter), "consumed, but blocked")
        #expect(flow.phase == .editingTitle)
        flow.handle(.tab)
        #expect(flow.handle(.commandEnter))
        #expect(flow.phase == .editingNote)
        #expect(flow.savedDraft == nil)
        #expect(memory.stored == .notUrgentImportant, "blocked save doesn't touch last-used")
    }

    @Test func commandEnterInPickerIsBlockedWithoutTitle() {
        let (flow, _) = makeCreate()
        #expect(flow.handle(.commandEnter))
        #expect(flow.phase == .pickingQuadrant)
    }

    @Test(arguments: [0, 1, 2])
    func escapeCancelsFromEveryPhase(enters: Int) {
        let (flow, memory) = makeCreate()
        flow.title = "x"
        for _ in 0..<enters { flow.handle(.enter) }
        #expect(flow.phase == [.pickingQuadrant, .editingTitle, .editingNote][enters])
        #expect(flow.handle(.escape))
        #expect(flow.phase == .cancelled)
        #expect(flow.savedDraft == nil)
        #expect(memory.stored == nil)
    }

    @Test func finishedFlowIgnoresFurtherKeys() {
        let (flow, _) = makeCreate()
        flow.handle(.escape)
        #expect(!flow.handle(.enter))
        #expect(!flow.handle(.commandEnter))
        #expect(flow.phase == .cancelled)
    }

    @Test func lastUsedRoundTripsThroughUserDefaults() throws {
        let suite = "howy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persisted = UserDefaultsLastQuadrantStore(defaults: defaults)
        #expect(persisted.load() == nil)

        let flow = QuickEntryFlow(mode: .create(), lastUsed: persisted)
        flow.handle(.digit(2))
        flow.title = "T"
        flow.handle(.commandEnter)

        let next = QuickEntryFlow(mode: .create(), lastUsed: UserDefaultsLastQuadrantStore(defaults: defaults))
        #expect(next.quadrant == .notUrgentImportant)
    }

    // MARK: edit mode

    @Test func editModeLoadsTodoAndStartsInTitle() {
        let id = UUID()
        let source = QuickEntryDraft(todoID: id, title: "Existing", note: "Some *note*", quadrant: .urgentUnimportant)
        let flow = QuickEntryFlow(mode: .edit(source), lastUsed: MemoryLastQuadrantStore(.urgentImportant))
        #expect(flow.phase == .editingTitle)
        #expect(flow.title == "Existing")
        #expect(flow.note == "Some *note*")
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.todoID == id)
    }

    @Test func editModeQuadrantChangeViaShiftTabAndSave() {
        let id = UUID()
        let memory = MemoryLastQuadrantStore(.urgentImportant)
        let flow = QuickEntryFlow(mode: .edit(QuickEntryDraft(todoID: id, title: "E", note: "n", quadrant: .urgentImportant)), lastUsed: memory)
        #expect(flow.handle(.shiftTab))
        #expect(flow.phase == .pickingQuadrant)
        flow.handle(.right)
        flow.handle(.down)
        #expect(flow.handle(.commandEnter), "edit mode has a title, so saving from the picker works")
        #expect(flow.phase == .saved)
        #expect(flow.savedDraft == QuickEntryDraft(todoID: id, title: "E", note: "n", quadrant: .notUrgentUnimportant))
        #expect(memory.stored == .urgentImportant, "editing doesn't change the create-mode default")
    }

    @Test func editModeDigitInPickerReturnsToTitleKeepingText() {
        let flow = QuickEntryFlow(mode: .edit(QuickEntryDraft(todoID: UUID(), title: "E", note: "", quadrant: .urgentImportant)), lastUsed: MemoryLastQuadrantStore())
        flow.handle(.shiftTab)
        flow.handle(.digit(2))
        #expect(flow.phase == .editingTitle)
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.title == "E")
    }

    @Test func pointerHelpersMirrorKeys() {
        let (flow, _) = makeCreate()
        flow.choose(.notUrgentImportant)
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.phase == .editingTitle)
        flow.focus(.editingNote)
        #expect(flow.phase == .editingNote)
        flow.title = "x"
        #expect(flow.save())
        #expect(flow.phase == .saved)
        let (other, _) = makeCreate()
        other.cancel()
        #expect(other.phase == .cancelled)
    }

    // MARK: picker swallows plain typing

    @Test func plainTypingKeysAreSwallowedInPickerButNotInFields() {
        let (flow, _) = makeCreate()
        #expect(flow.handle(.other))
        #expect(flow.phase == .pickingQuadrant)
        flow.handle(.enter)
        #expect(!flow.handle(.other), "typing in the title is left to the text field")
    }

    // MARK: empty-title hint

    @Test func emptyTitleHintAppearsOnBlockedSaveAndClearsWhenTitleIsFilled() {
        let (flow, _) = makeCreate()
        flow.handle(.enter)
        #expect(!flow.showsEmptyTitleHint)
        flow.handle(.commandEnter)
        #expect(flow.showsEmptyTitleHint)
        flow.title = "x"
        #expect(!flow.showsEmptyTitleHint)
    }

    @Test func emptiedTitleBlocksSaveInEditMode() {
        let flow = makeEdit()
        flow.title = "  "
        #expect(flow.handle(.commandEnter))
        #expect(flow.phase == .editingTitle)
        #expect(flow.savedDraft == nil)
    }

    @Test func tabInNoteIsNotConsumedAndShiftTabFromPickerIsNotConsumedInEdit() {
        let (flow, _) = makeCreate()
        flow.handle(.enter)
        flow.handle(.tab)
        #expect(!flow.handle(.tab))
        let edit = makeEdit()
        edit.handle(.shiftTab)
        #expect(!edit.handle(.shiftTab))
    }

    // MARK: delete confirmation

    func makeEdit() -> QuickEntryFlow {
        QuickEntryFlow(mode: .edit(QuickEntryDraft(todoID: UUID(), title: "E", note: "n", quadrant: .urgentImportant)),
                       lastUsed: MemoryLastQuadrantStore())
    }

    @Test(arguments: [0, 1, 2])
    func commandDeleteArmsConfirmationInEveryPhase(shiftTabs: Int) {
        let flow = makeEdit()
        if shiftTabs == 1 { flow.handle(.shiftTab) }
        if shiftTabs == 2 { flow.handle(.tab) }
        #expect(flow.handle(.commandDelete))
        #expect(flow.isConfirmingDelete)
        #expect(flow.phase != .deleted)
    }

    @Test func commandDeleteInCreateModeClearsInsteadOfAskingToDelete() {
        let (flow, _) = makeCreate()
        flow.handle(.enter)
        flow.title = "typed"
        #expect(flow.handle(.commandDelete))
        #expect(!flow.isConfirmingDelete)
        #expect(flow.title == "")
        #expect(flow.phase == .pickingQuadrant)
    }

    @Test(arguments: [QuickEntryKey.enter, .commandDelete])
    func enterOrSecondCommandDeleteConfirms(key: QuickEntryKey) {
        let flow = makeEdit()
        flow.handle(.commandDelete)
        #expect(flow.handle(key))
        #expect(flow.phase == .deleted)
        #expect(flow.isFinished)
    }

    @Test func commandEnterDoesNotConfirmDeleteNorSave() {
        let flow = makeEdit()
        flow.handle(.commandDelete)
        #expect(flow.handle(.commandEnter))
        #expect(flow.isConfirmingDelete)
        #expect(flow.phase == .editingTitle)
        #expect(flow.savedDraft == nil)
    }

    @Test(arguments: [QuickEntryKey.escape, .digit(2), .other, .tab, .up])
    func otherKeysCancelConfirmationAndAreConsumed(key: QuickEntryKey) {
        let flow = makeEdit()
        flow.handle(.commandDelete)
        #expect(flow.handle(key), "consumed so it can't change the form behind the prompt")
        #expect(!flow.isConfirmingDelete)
        #expect(flow.phase == .editingTitle)
        #expect(flow.title == "E")
    }

    @Test func confirmingFromPickerDoesNotChangeQuadrantOnEnter() {
        let flow = makeEdit()
        flow.handle(.shiftTab)
        flow.handle(.down)
        flow.handle(.commandDelete)
        flow.handle(.digit(3))
        #expect(!flow.isConfirmingDelete)
        #expect(flow.phase == .pickingQuadrant, "the digit only cancelled the prompt")
    }

    @Test func buttonsRequestConfirmAndCancel() {
        let flow = makeEdit()
        flow.requestDelete()
        #expect(flow.isConfirmingDelete)
        flow.cancelDelete()
        #expect(!flow.isConfirmingDelete)
        flow.confirmDelete()
        #expect(flow.phase == .editingTitle, "confirm without a prompt is ignored")
        flow.requestDelete()
        flow.confirmDelete()
        #expect(flow.phase == .deleted)
    }

    @Test func reopenAfterFailedSaveOrDeleteReturnsToTitle() {
        let flow = makeEdit()
        flow.handle(.commandEnter)
        #expect(flow.phase == .saved)
        flow.reopen()
        #expect(flow.phase == .editingTitle)
        #expect(flow.savedDraft == nil)
        #expect(flow.handle(.shiftTab))
        flow.requestDelete()
        flow.confirmDelete()
        #expect(flow.phase == .deleted)
        flow.reopen()
        #expect(flow.phase == .editingTitle)
        #expect(!flow.isConfirmingDelete)
    }

    @Test func reopenIgnoresCancelledFlow() {
        let (flow, _) = makeCreate()
        flow.cancel()
        flow.reopen()
        #expect(flow.phase == .cancelled)
    }
}

@MainActor
@Suite struct QuickEntrySpaceKeyTests {
    @Test func spaceIsTextInFieldsAndSwallowedInPicker() {
        let flow = QuickEntryFlow(mode: .create(), lastUsed: MemoryLastQuadrantStore())
        #expect(flow.handle(.space))
        #expect(flow.phase == .pickingQuadrant)
        flow.handle(.enter)
        #expect(!flow.handle(.space))
        flow.handle(.tab)
        #expect(!flow.handle(.space))
    }
}
