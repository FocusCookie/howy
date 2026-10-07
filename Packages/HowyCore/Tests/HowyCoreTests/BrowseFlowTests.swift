import Foundation
import Testing
@testable import HowyCore

@MainActor
@Suite struct BrowseFlowTests {
    func todos(_ quadrant: Quadrant, _ titles: [String]) -> [TodoSnapshot] {
        titles.map { TodoSnapshot(id: UUID(), title: $0, quadrant: quadrant) }
    }

    func make(q1: [String] = ["c", "b", "a"], q2: [String] = [], q3: [String] = ["x"], q4: [String] = []) -> BrowseFlow {
        BrowseFlow(todos: [
            .urgentImportant: todos(.urgentImportant, q1),
            .notUrgentImportant: todos(.notUrgentImportant, q2),
            .urgentUnimportant: todos(.urgentUnimportant, q3),
            .notUrgentUnimportant: todos(.notUrgentUnimportant, q4),
        ])
    }

    func titles(_ flow: BrowseFlow) -> [String] { flow.rows.map(\.title) }

    // MARK: picker

    @Test func startsInPickerWithCounts() {
        let flow = make()
        #expect(flow.phase == .picking)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.count(in: .urgentImportant) == 3)
        #expect(flow.count(in: .notUrgentImportant) == 0)
        #expect(flow.count(in: .urgentUnimportant) == 1)
        #expect(flow.count(in: .notUrgentUnimportant) == 0)
        #expect(flow.selectedIndex == nil)
    }

    @Test func missingQuadrantsCountAsEmpty() {
        let flow = BrowseFlow(todos: [:])
        #expect(Quadrant.allCases.allSatisfy { flow.count(in: $0) == 0 })
    }

    @Test func arrowsMoveAndClampInPicker() {
        let flow = make()
        #expect(flow.handle(.left) == .handled)
        #expect(flow.quadrant == .urgentImportant)
        flow.handle(.right)
        flow.handle(.down)
        #expect(flow.quadrant == .notUrgentUnimportant)
        flow.handle(.down)
        #expect(flow.quadrant == .notUrgentUnimportant)
        #expect(flow.phase == .picking)
    }

    @Test(arguments: [QuickEntryKey.enter, .tab])
    func enterOpensTheHighlightedQuadrant(key: QuickEntryKey) {
        let flow = make()
        flow.handle(.down)
        #expect(flow.handle(key) == .handled)
        #expect(flow.phase == .listing)
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(titles(flow) == ["x"])
        #expect(flow.selectedIndex == 0)
    }

    @Test func digitJumpsStraightToTheList() {
        let flow = make()
        #expect(flow.handle(.digit(1)) == .handled)
        #expect(flow.phase == .listing)
        #expect(titles(flow) == ["c", "b", "a"], "newest first, as given")
        #expect(flow.selectedIndex == 0)
    }

    @Test(arguments: [QuickEntryKey.other, .space, .letter("d"), .digit(7), .shiftTab, .commandEnter])
    func pickerSwallowsKeysWithNothingToDo(key: QuickEntryKey) {
        let flow = make()
        #expect(flow.handle(key) == .handled)
        #expect(flow.phase == .picking)
    }

    @Test func downFromTheBottomRowHighlightsTheArchiveAndUpComesBack() {
        let flow = make()
        flow.handle(.down)
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(!flow.isArchiveHighlighted)
        #expect(flow.handle(.down) == .handled)
        #expect(flow.isArchiveHighlighted)
        #expect(flow.quadrant == .urgentUnimportant, "the quadrant is remembered")
        flow.handle(.left)
        flow.handle(.right)
        #expect(flow.isArchiveHighlighted, "left/right stay on the archive")
        #expect(flow.handle(.up) == .handled)
        #expect(!flow.isArchiveHighlighted)
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.phase == .picking)
    }

    @Test(arguments: [QuickEntryKey.enter, .tab])
    func enterOnTheHighlightedArchiveOpensIt(key: QuickEntryKey) {
        let flow = make()
        flow.handle(.down)
        flow.handle(.down)
        #expect(flow.handle(key) == .openArchive)
        #expect(flow.phase == .picking, "the caller swaps the screen")
    }

    @Test func backspaceArchivesTheSelectedRowWithoutCallingItDone() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.down)
        let id = flow.selectedTodo!.id
        #expect(flow.handle(.backspace) == .archive(id))
        #expect(titles(flow) == ["c", "a"])
        #expect(flow.selectedIndex == 1, "the row below moves up into the gap")
        flow.choose(.notUrgentImportant)
        #expect(flow.handle(.backspace) == .handled, "nothing selected in an empty list")
    }

    @Test func archiveKeyOpensTheArchiveFromPickerAndList() {
        let flow = make()
        #expect(flow.handle(.letter("a")) == .openArchive)
        #expect(flow.handle(.letter("b")) == .handled)
        flow.choose(.urgentImportant)
        #expect(flow.handle(.letter("a")) == .openArchive)
        #expect(flow.phase == .listing)
    }

    @Test func choosingAQuadrantDropsTheArchiveHighlight() {
        let flow = make()
        flow.highlightArchive()
        #expect(flow.isArchiveHighlighted)
        flow.handle(.digit(1))
        #expect(flow.phase == .listing)
        #expect(!flow.isArchiveHighlighted)
        flow.backToPicker()
        #expect(!flow.isArchiveHighlighted)
        flow.highlightArchive()
        flow.choose(.urgentImportant)
        flow.highlightArchive()
        #expect(!flow.isArchiveHighlighted, "only in the picker")
    }

    @Test func escapeInPickerCloses() {
        let flow = make()
        #expect(flow.handle(.escape) == .close)
        #expect(flow.phase == .closed)
        #expect(flow.handle(.enter) == .ignored, "closed flow ignores keys")
    }

    // MARK: list

    @Test func emptyQuadrantListHasNoSelection() {
        let flow = make()
        flow.choose(.notUrgentImportant)
        #expect(flow.phase == .listing)
        #expect(flow.rows.isEmpty)
        #expect(flow.selectedIndex == nil)
        #expect(flow.handle(.enter) == .handled)
        #expect(flow.handle(.letter("d")) == .handled)
        #expect(flow.handle(.down) == .handled)
        #expect(flow.selectedIndex == nil)
    }

    @Test func upDownMoveSelectionAndClamp() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.up)
        #expect(flow.selectedIndex == 0)
        flow.handle(.down)
        flow.handle(.down)
        flow.handle(.down)
        #expect(flow.selectedIndex == 2)
        flow.handle(.up)
        #expect(flow.selectedTodo?.title == "b")
    }

    @Test func enterOpensTheSelectedTodo() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.down)
        let id = flow.rows[1].id
        #expect(flow.handle(.enter) == .open(id))
    }

    @Test(arguments: [QuickEntryKey.escape, .shiftTab])
    func escapeOrShiftTabGoesBackToPicker(key: QuickEntryKey) {
        let flow = make()
        flow.choose(.urgentUnimportant)
        #expect(flow.handle(key) == .handled)
        #expect(flow.phase == .picking)
        #expect(flow.quadrant == .urgentUnimportant, "picker keeps the quadrant highlighted")
        #expect(flow.selectedIndex == nil)
    }

    @Test func digitInListSwitchesQuadrant() {
        let flow = make()
        flow.choose(.urgentImportant)
        #expect(flow.handle(.digit(3)) == .handled)
        #expect(flow.phase == .listing)
        #expect(titles(flow) == ["x"])
        #expect(flow.selectedIndex == 0)
    }

    @Test func listIgnoresTypingButConsumesIt() {
        let flow = make()
        flow.choose(.urgentImportant)
        #expect(flow.handle(.other) == .handled)
        #expect(flow.handle(.left) == .handled)
        #expect(flow.phase == .listing)
    }

    // MARK: completing

    @Test func dCompletesTheSelectedRowAndKeepsThePosition() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.down)
        let middle = flow.rows[1].id
        #expect(flow.handle(.letter("d")) == .complete(middle))
        #expect(titles(flow) == ["c", "a"])
        #expect(flow.selectedTodo?.title == "a", "the next row moves up under the selection")
        #expect(flow.count(in: .urgentImportant) == 2)
    }

    @Test func completingTheLastRowSelectsTheNewLast() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.down)
        flow.handle(.down)
        flow.handle(.letter("d"))
        #expect(titles(flow) == ["c", "b"])
        #expect(flow.selectedIndex == 1)
    }

    @Test func completingTheOnlyRowLeavesNoSelection() {
        let flow = make()
        flow.choose(.urgentUnimportant)
        flow.handle(.letter("d"))
        #expect(flow.rows.isEmpty)
        #expect(flow.selectedIndex == nil)
        #expect(flow.count(in: .urgentUnimportant) == 0)
        #expect(flow.phase == .listing, "stays on the (now empty) list")
    }

    @Test func completingByIdAboveTheSelectionKeepsTheSelectedTodo() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.down)
        flow.handle(.down) // "a"
        let first = flow.rows[0].id
        #expect(flow.complete(id: first))
        #expect(flow.selectedTodo?.title == "a")
        #expect(!flow.complete(id: UUID()), "unknown id")
    }

    // MARK: undo

    @Test func undoPutsTheCompletedRowBackWhereItWasAndSelectsIt() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.down)
        let middle = flow.rows[1].id
        #expect(!flow.canUndo)
        #expect(flow.handle(.letter("d")) == .complete(middle))
        #expect(flow.canUndo)
        flow.handle(.up)
        #expect(flow.handle(.undo) == .restore(middle))
        #expect(titles(flow) == ["c", "b", "a"])
        #expect(flow.selectedTodo?.id == middle)
        #expect(!flow.canUndo)
        #expect(flow.handle(.undo) == .handled, "nothing left to undo")
        #expect(titles(flow) == ["c", "b", "a"])
    }

    @Test func undoTakesBackSeveralInReverseOrder() {
        let flow = make()
        flow.choose(.urgentImportant)
        let first = flow.rows[0].id
        let second = flow.rows[1].id
        flow.handle(.letter("d")) // c
        flow.handle(.backspace) // b, archived without celebration
        #expect(titles(flow) == ["a"])
        #expect(flow.handle(.undo) == .restore(second))
        #expect(titles(flow) == ["b", "a"])
        #expect(flow.handle(.undo) == .restore(first))
        #expect(titles(flow) == ["c", "b", "a"])
        #expect(flow.selectedTodo?.id == first)
    }

    @Test func undoFromAnotherQuadrantShowsTheRestoredOne() {
        let flow = make()
        flow.choose(.urgentUnimportant)
        let x = flow.rows[0].id
        flow.handle(.letter("d"))
        #expect(flow.selectedIndex == nil)
        flow.handle(.digit(1))
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.handle(.undo) == .restore(x))
        #expect(flow.phase == .listing)
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(titles(flow) == ["x"])
        #expect(flow.selectedIndex == 0)
    }

    @Test func undoInThePickerRestoresTheCountAndHighlightsTheQuadrant() {
        let flow = make()
        flow.choose(.urgentUnimportant)
        let x = flow.rows[0].id
        flow.handle(.letter("d"))
        flow.handle(.escape)
        flow.handle(.down) // onto the Archive button
        #expect(flow.isArchiveHighlighted)
        #expect(flow.count(in: .urgentUnimportant) == 0)
        #expect(flow.handle(.undo) == .restore(x))
        #expect(flow.phase == .picking)
        #expect(flow.count(in: .urgentUnimportant) == 1)
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(!flow.isArchiveHighlighted)
    }

    @Test func undoClampsTheOldPositionWhenTheListShrank() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.down)
        flow.handle(.down)
        let last = flow.rows[2].id
        flow.handle(.letter("d")) // a, at index 2
        flow.reload([.urgentImportant: [flow.rows[0]]]) // b went elsewhere meanwhile
        #expect(flow.handle(.undo) == .restore(last))
        #expect(titles(flow) == ["c", "a"])
        #expect(flow.selectedIndex == 1)
    }

    @Test func undoSkipsATodoAReloadAlreadyBroughtBack() {
        let flow = make()
        flow.choose(.urgentImportant)
        let first = flow.rows[0]
        flow.handle(.letter("d"))
        flow.reload([.urgentImportant: [first, flow.rows[0], flow.rows[1]]]) // the write failed
        #expect(flow.handle(.undo) == .restore(first.id))
        #expect(titles(flow) == ["c", "b", "a"], "not inserted twice")
    }

    @Test func undoDoesNothingWhenClosed() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.letter("d"))
        flow.close()
        #expect(flow.handle(.undo) == .ignored)
        #expect(flow.undoCompletion() == nil)
    }

    @Test func reloadKeepsTheSelectedTodoWhenStillThere() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.handle(.down) // "b"
        let b = flow.rows[1]
        flow.reload([.urgentImportant: [TodoSnapshot(id: UUID(), title: "new", quadrant: .urgentImportant)] + flow.rows])
        #expect(flow.selectedTodo == b)
        flow.reload([.urgentImportant: []])
        #expect(flow.selectedIndex == nil)
        #expect(flow.count(in: .urgentUnimportant) == 0)
    }

    @Test func pointerSelect() {
        let flow = make()
        flow.choose(.urgentImportant)
        flow.select(id: flow.rows[2].id)
        #expect(flow.selectedIndex == 2)
        flow.select(id: UUID())
        #expect(flow.selectedIndex == 2)
    }

    // MARK: back from editing

    @Test func resumeListingSelectsTheEditedTodo() {
        let flow = make()
        flow.choose(.urgentImportant)
        let edited = flow.rows[1].id
        flow.backToPicker()
        flow.resumeListing(.urgentImportant, selecting: edited, fallbackIndex: 1)
        #expect(flow.phase == .listing)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.id == edited)
    }

    @Test func resumeListingFallsBackToTheOldPositionWhenTheTodoIsGone() {
        let flow = make()
        flow.resumeListing(.urgentImportant, selecting: UUID(), fallbackIndex: 1)
        #expect(flow.selectedIndex == 1)
        flow.resumeListing(.urgentImportant, selecting: UUID(), fallbackIndex: 7)
        #expect(flow.selectedIndex == 2)
    }

    @Test func resumeListingOnAnEmptyQuadrantSelectsNothing() {
        let flow = make()
        flow.resumeListing(.notUrgentImportant, selecting: UUID(), fallbackIndex: 0)
        #expect(flow.phase == .listing)
        #expect(flow.selectedIndex == nil)
    }

    @Test func escapeAfterResumingGoesBackToThePicker() {
        let flow = make()
        flow.resumeListing(.urgentUnimportant, selecting: nil, fallbackIndex: 0)
        #expect(flow.handle(.escape) == .handled)
        #expect(flow.phase == .picking)
        #expect(flow.handle(.escape) == .close)
    }

    // MARK: reordering

    @Test func commandKeysMoveTheSelectedRowAndKeepItSelected() {
        let flow = make()
        flow.choose(.urgentImportant)
        #expect(flow.handle(.moveDown) == .reorder(.urgentImportant))
        #expect(titles(flow) == ["b", "c", "a"])
        #expect(flow.selectedTodo?.title == "c")
        #expect(flow.handle(.moveDown) == .reorder(.urgentImportant))
        #expect(titles(flow) == ["b", "a", "c"])
        #expect(flow.handle(.moveDown) == .handled) // already last
        #expect(flow.handle(.moveUp) == .reorder(.urgentImportant))
        #expect(titles(flow) == ["b", "c", "a"])
        #expect(flow.selectedIndex == 1)
    }

    @Test func moveKeysDoNothingInPickerOrEmptyList() {
        let flow = make()
        #expect(flow.handle(.moveDown) == .handled)
        flow.choose(.notUrgentImportant)
        #expect(flow.handle(.moveUp) == .handled)
    }

    @Test func dragMoveClampsAndSelectionFollowsItsTodo() throws {
        let flow = make()
        flow.choose(.urgentImportant) // selects "c"
        let a = try #require(flow.rows.last)
        #expect(flow.move(id: a.id, to: -5))
        #expect(titles(flow) == ["a", "c", "b"])
        #expect(flow.selectedTodo?.title == "c")
        #expect(!flow.move(id: a.id, to: 0))
        #expect(flow.count(in: .urgentImportant) == 3)
    }
}
