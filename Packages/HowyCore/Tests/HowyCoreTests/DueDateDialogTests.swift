import Foundation
import Testing
@testable import HowyCore

extension DueDateContext {
    /// Wednesday 7 Oct 2026, 10:00 in Berlin, default time 9:00.
    static let fixture = DueDateContext(now: { DueFixture.wednesday }, calendar: DueFixture.calendar, defaultTime: .nine)
}

/// The due-date dialog in the editor (`QuickEntryFlow.dueDialog`).
@MainActor
@Suite struct QuickEntryDueDateTests {
    let tomorrowNine = DueFixture.date("2026-10-08 09:00")

    func makeCreate() -> QuickEntryFlow {
        let flow = QuickEntryFlow(mode: .create(startingInTitle: true), lastUsed: MemoryLastQuadrantStore(), dueDates: .fixture)
        flow.title = "Submit tax return"
        return flow
    }

    func makeEdit(due: Date?, drafts: (any DraftStore)? = nil) -> QuickEntryFlow {
        let draft = QuickEntryDraft(todoID: UUID(), title: "Pay", note: "", quadrant: .urgentImportant, due: due)
        return QuickEntryFlow(mode: .edit(draft), lastUsed: MemoryLastQuadrantStore(), drafts: drafts, dueDates: .fixture)
    }

    @Test func commandTOpensTheDialog() {
        let flow = makeCreate()
        #expect(flow.handle(.dueDate))
        #expect(flow.dueDialog == DueDateDialog(current: nil))
        #expect(flow.phase == .editingTitle, "the field under it keeps its place")
    }

    @Test func itOpensFromTheNoteAndThePickerToo() {
        let flow = makeCreate()
        flow.handle(.enter)
        #expect(flow.phase == .editingNote)
        flow.handle(.dueDate)
        #expect(flow.dueDialog != nil)
        let picker = QuickEntryFlow(mode: .create(), lastUsed: MemoryLastQuadrantStore(), dueDates: .fixture)
        picker.handle(.dueDate)
        #expect(picker.dueDialog != nil)
    }

    @Test func typingUpdatesTheParseResult() {
        let flow = makeCreate()
        flow.handle(.dueDate)
        flow.setDueText("tomorrow")
        #expect(flow.dueDialog?.outcome == .resolved(tomorrowNine, note: "no time → 9:00"))
        flow.setDueText("xyz")
        #expect(flow.dueDialog?.outcome == .failure(.didNotUnderstand("xyz")))
        #expect(flow.dueDialog?.canConfirm == false)
    }

    @Test func letterKeysAreTypingInTheField() {
        let flow = makeCreate()
        flow.handle(.dueDate)
        #expect(!flow.handle(.letter("t")))
        #expect(!flow.handle(.other))
        #expect(!flow.handle(.backspace))
    }

    @Test func enterOnlyConfirmsAValidDate() {
        let flow = makeCreate()
        flow.handle(.dueDate)
        flow.setDueText("xyz")
        #expect(flow.handle(.enter))
        #expect(flow.dueDialog != nil, "still open")
        #expect(flow.due == nil)
        flow.setDueText("tomorrow")
        flow.handle(.enter)
        #expect(flow.dueDialog == nil)
        #expect(flow.due == tomorrowNine)
    }

    @Test func enterOnAnEmptyFieldWithoutADateDoesNothing() {
        let flow = makeCreate()
        flow.handle(.dueDate)
        flow.handle(.enter)
        #expect(flow.dueDialog != nil)
    }

    @Test func enterOnAnEmptyFieldKeepsTheExistingDate() {
        let set = DueFixture.date("2026-10-20 09:00")
        let flow = makeEdit(due: set)
        flow.handle(.dueDate)
        #expect(flow.dueDialog?.current == set)
        flow.handle(.enter)
        #expect(flow.dueDialog == nil)
        #expect(flow.due == set)
    }

    @Test func escapeClosesTheExamplesThenTheDialog() {
        let flow = makeCreate()
        flow.handle(.dueDate)
        flow.toggleDueExamples()
        #expect(flow.dueDialog?.showsExamples == true)
        flow.handle(.escape)
        #expect(flow.dueDialog?.showsExamples == false)
        #expect(flow.dueDialog != nil)
        flow.handle(.escape)
        #expect(flow.dueDialog == nil)
        #expect(flow.phase == .editingTitle, "Esc didn't cancel the editor")
    }

    @Test func escapeChangesNothing() {
        let set = DueFixture.date("2026-10-20 09:00")
        let flow = makeEdit(due: set)
        flow.handle(.dueDate)
        flow.setDueText("tomorrow")
        flow.handle(.escape)
        #expect(flow.due == set)
    }

    @Test func commandDeleteClearsASetDate() {
        let flow = makeEdit(due: DueFixture.date("2026-10-20 09:00"))
        flow.handle(.dueDate)
        #expect(flow.handle(.commandDelete))
        #expect(flow.due == nil)
        #expect(flow.dueDialog == nil)
    }

    @Test func commandDeleteWithoutADateIsTheFields() {
        let flow = makeCreate()
        flow.handle(.dueDate)
        #expect(!flow.handle(.commandDelete))
        #expect(flow.dueDialog != nil)
    }

    @Test func pickingAnExamplePutsItInTheField() {
        let flow = makeCreate()
        flow.beginDueDate()
        flow.toggleDueExamples()
        flow.pickDueExample("tomorrow")
        #expect(flow.dueDialog?.text == "tomorrow")
        #expect(flow.dueDialog?.outcome.date == tomorrowNine)
        #expect(flow.dueDialog?.showsExamples == true)
    }

    @Test func theSavedDraftCarriesTheDate() {
        let flow = makeCreate()
        flow.handle(.dueDate)
        flow.setDueText("tomorrow")
        flow.handle(.enter)
        flow.handle(.commandEnter)
        #expect(flow.phase == .saved)
        #expect(flow.savedDraft?.due == tomorrowNine)
    }

    @Test func commandEnterInTheDialogSetsTheDateNotSaves() {
        let flow = makeCreate()
        flow.handle(.dueDate)
        flow.setDueText("tomorrow")
        flow.handle(.commandEnter)
        #expect(flow.due == tomorrowNine)
        #expect(flow.phase == .editingTitle)
    }

    @Test func anEditKeepsItsDateWhenSaved() {
        let set = DueFixture.date("2026-10-20 09:00")
        let flow = makeEdit(due: set)
        flow.handle(.commandEnter)
        #expect(flow.savedDraft?.due == set)
    }

    @Test func removingTheDateOfAnEditSavesNone() {
        let flow = makeEdit(due: DueFixture.date("2026-10-20 09:00"))
        flow.beginDueDate()
        flow.removeDue()
        flow.save()
        #expect(flow.savedDraft?.due == nil)
    }

    @Test func aChangedDateIsStashedForAnAbandonedEdit() {
        let drafts = MemoryDraftStore()
        let flow = makeEdit(due: nil, drafts: drafts)
        flow.beginDueDate()
        flow.setDueText("tomorrow")
        flow.confirmDue()
        flow.abandon()
        let id = flow.todoID!
        #expect(drafts.editDraft(for: id)?.due == tomorrowNine)
        let draft = QuickEntryDraft(todoID: id, title: "Pay", note: "", quadrant: .urgentImportant)
        let again = QuickEntryFlow(mode: .edit(draft), lastUsed: MemoryLastQuadrantStore(), drafts: drafts, dueDates: .fixture)
        #expect(again.due == tomorrowNine)
    }

    @Test func thePreviewShowsTheKeptDateOnAnEmptyField() {
        let set = DueFixture.date("2026-10-08 09:00")
        let dialog = DueDateDialog(current: set)
        let preview = dialog.preview(now: DueFixture.wednesday, format: DueFormat(calendar: DueFixture.calendar))
        #expect(preview == .ok("→ Thu 8 Oct 2026, 09:00", detail: "in 23 h · unchanged"))
    }

    @Test func savingClosesAnOpenDialog() {
        let flow = makeCreate()
        flow.beginDueDate()
        flow.save()
        #expect(flow.dueDialog == nil)
    }
}

/// The due-date dialog over the Browse list (`BrowseFlow.dueDialog`).
@MainActor
@Suite struct BrowseDueDateTests {
    let tomorrowNine = DueFixture.date("2026-10-08 09:00")

    func make(due: Date? = nil) -> BrowseFlow {
        let todos = [
            TodoSnapshot(id: UUID(), title: "a", quadrant: .urgentImportant, due: due),
            TodoSnapshot(id: UUID(), title: "b", quadrant: .urgentImportant),
        ]
        let flow = BrowseFlow(todos: [.urgentImportant: todos], dueDates: .fixture)
        flow.choose(.urgentImportant)
        return flow
    }

    @Test func tOnASelectionOpensTheDialog() {
        let flow = make()
        #expect(flow.handle(.letter("t")) == .handled)
        #expect(flow.dueDialog != nil)
        #expect(flow.dueDialogTodoID == flow.rows[0].id)
    }

    @Test func tOnAnEmptyListDoesNothing() {
        let flow = BrowseFlow(todos: [:], dueDates: .fixture)
        flow.choose(.urgentImportant)
        flow.handle(.letter("t"))
        #expect(flow.dueDialog == nil)
    }

    @Test func confirmingWritesTheDate() {
        let flow = make()
        flow.handle(.letter("t"))
        #expect(flow.handle(.letter("d")) == .ignored, "typing, not done")
        flow.setDueText("tomorrow")
        let id = flow.rows[0].id
        #expect(flow.handle(.enter) == .setDue(id, tomorrowNine))
        #expect(flow.dueDialog == nil)
        #expect(flow.rows[0].due == tomorrowNine, "the row shows it at once")
        #expect(flow.rows.map(\.title) == ["a", "b"], "the order stays")
    }

    @Test func anInvalidPhraseKeepsTheDialogOpen() {
        let flow = make()
        flow.handle(.letter("t"))
        flow.setDueText("xyz")
        #expect(flow.handle(.enter) == .handled)
        #expect(flow.dueDialog != nil)
    }

    @Test func anEmptyFieldKeepsTheDate() {
        let set = DueFixture.date("2026-10-20 09:00")
        let flow = make(due: set)
        flow.handle(.letter("t"))
        #expect(flow.handle(.enter) == .handled)
        #expect(flow.dueDialog == nil)
        #expect(flow.rows[0].due == set)
    }

    @Test func commandDeleteRemovesTheDate() {
        let flow = make(due: DueFixture.date("2026-10-20 09:00"))
        flow.handle(.letter("t"))
        #expect(flow.handle(.commandDelete) == .setDue(flow.rows[0].id, nil))
        #expect(flow.rows[0].due == nil)
    }

    @Test func escapeClosesTheExamplesThenTheDialogAndStaysInTheList() {
        let flow = make()
        flow.handle(.letter("t"))
        flow.toggleDueExamples()
        flow.handle(.escape)
        #expect(flow.dueDialog?.showsExamples == false)
        flow.handle(.escape)
        #expect(flow.dueDialog == nil)
        #expect(flow.phase == .listing)
    }

    @Test func aRowClockOpensTheDialogForThatRow() {
        let flow = make()
        let second = flow.rows[1].id
        flow.beginDueDate(id: second)
        #expect(flow.selectedTodo?.id == second)
        #expect(flow.dueDialogTodoID == second)
    }

    @Test func theOverviewOpensItForTheFocusedTile() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("t"))
        #expect(flow.dueDialogTodoID == flow.selectedTodo?.id)
        flow.setDueText("tomorrow")
        #expect(flow.handle(.enter) == .setDue(flow.rows[0].id, tomorrowNine))
    }

    @Test func notWhileATileEditorIsOpen() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.enter) // opens the tile editor
        #expect(flow.handle(.letter("t")) == .ignored)
        #expect(flow.dueDialog == nil)
    }
}
