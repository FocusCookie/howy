import Foundation
import Testing
@testable import HowyCore

/// The Overview phase of `BrowseFlow`: all four quadrants as tiles, one of them focused.
@MainActor
@Suite struct BrowseOverviewTests {
    func todos(_ quadrant: Quadrant, _ titles: [String]) -> [TodoSnapshot] {
        titles.map { TodoSnapshot(id: UUID(), title: $0, quadrant: quadrant) }
    }

    func make(q1: [String] = ["c", "b", "a"], q2: [String] = ["p", "q"], q3: [String] = ["x"], q4: [String] = []) -> BrowseFlow {
        BrowseFlow(todos: [
            .urgentImportant: todos(.urgentImportant, q1),
            .notUrgentImportant: todos(.notUrgentImportant, q2),
            .urgentUnimportant: todos(.urgentUnimportant, q3),
            .notUrgentUnimportant: todos(.notUrgentUnimportant, q4),
        ])
    }

    func titles(_ flow: BrowseFlow, _ quadrant: Quadrant) -> [String] { flow.rows(in: quadrant).map(\.title) }

    func id(_ flow: BrowseFlow, _ title: String) throws -> UUID {
        try #require(Quadrant.allCases.flatMap { flow.rows(in: $0) }.first { $0.title == title }).id
    }

    // MARK: Opening and closing

    @Test func oFromTheGridFocusesTheHighlightedQuadrant() {
        let flow = make()
        flow.handle(.right)
        #expect(flow.handle(.letter("o")) == .showOverview)
        #expect(flow.phase == .overview)
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.selectedTodo?.title == "p")
        #expect(flow.editingTodoID == nil)
    }

    @Test func oFromTheArchiveButtonFocusesTheLastHighlightedQuadrant() {
        let flow = make()
        flow.handle(.down)
        flow.handle(.down) // Archive button
        #expect(flow.isArchiveHighlighted)
        #expect(flow.handle(.letter("o")) == .showOverview)
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.isArchiveHighlighted == false)
    }

    @Test func oFromTheListFocusesThatQuadrantAndTodo() {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(.down)
        #expect(flow.handle(.letter("o")) == .showOverview)
        #expect(flow.phase == .overview)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.title == "b")
    }

    @Test func emptyFocusedTileHasNoSelection() {
        let flow = make()
        flow.handle(.digit(4))
        flow.handle(.letter("o"))
        #expect(flow.quadrant == .notUrgentUnimportant)
        #expect(flow.selectedIndex == nil)
        #expect(flow.handle(.enter) == .handled)
        #expect(flow.editingTodoID == nil)
    }

    @Test func escapeWithoutEditorGoesBackToTheGridWithTheFocusedQuadrantHighlighted() {
        let flow = make()
        flow.handle(.letter("o"))
        flow.handle(.digit(3))
        #expect(flow.handle(.escape) == .hideOverview)
        #expect(flow.phase == .picking)
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.selectedIndex == nil)
    }

    @Test func toggleOverviewOpensAndClosesFromTheMiddleButton() {
        let flow = make()
        flow.handle(.down)
        #expect(flow.toggleOverview() == .showOverview)
        #expect(flow.phase == .overview)
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.toggleOverview() == .hideOverview)
        #expect(flow.phase == .picking)
        #expect(flow.quadrant == .urgentUnimportant)
    }

    @Test func toggleOverviewWithAnEditorOpenClosesBoth() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.enter)
        #expect(flow.editingTodoID != nil)
        #expect(flow.toggleOverview() == .hideOverview)
        #expect(flow.phase == .picking)
        #expect(flow.editingTodoID == nil)
    }

    @Test func toggleOverviewDoesNothingWhenClosed() {
        let flow = make()
        flow.close()
        #expect(flow.toggleOverview() == .ignored)
        #expect(flow.phase == .closed)
    }

    @Test func closingFromTheOverviewClearsTheEditor() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.enter)
        #expect(flow.close() == .close)
        #expect(flow.phase == .closed)
        #expect(flow.editingTodoID == nil)
    }

    // MARK: The editor in a tile and the Esc ladder

    @Test func enterOpensTheSelectedTodoInTheTile() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        let b = try id(flow, "b")
        #expect(flow.handle(.enter) == .editInTile(b))
        #expect(flow.editingTodoID == b)
        #expect(flow.phase == .overview)
    }

    @Test func escapeWithAnEditorDiscardsItAndKeepsTheTodoSelected() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        let b = try id(flow, "b")
        flow.handle(.enter)
        #expect(flow.handle(.escape) == .dismissEditor(.edit(b), stash: false))
        #expect(flow.editingTodoID == nil)
        #expect(flow.phase == .overview)
        #expect(flow.selectedTodo?.id == b)
        #expect(flow.handle(.escape) == .hideOverview, "second Esc: back to the grid")
        #expect(flow.phase == .picking)
    }

    @Test(arguments: [QuickEntryKey.up, .down, .enter, .letter("d"), .backspace, .digit(2), .commandDigit(2),
                      .moveUp, .moveDown, .undo, .letter("a"), .letter("m"), .letter("o"), .other, .space])
    func keysWhileTheEditorIsOpenBelongToTheEditor(key: QuickEntryKey) throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        flow.handle(.enter)
        #expect(flow.handle(key) == .ignored)
        #expect(flow.editingTodoID == c)
        #expect(flow.quadrant == .urgentImportant)
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
    }

    @Test func optionDigitWhileEditingStashesTheEditAndFocusesTheOtherQuadrant() throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        flow.handle(.enter)
        #expect(flow.handle(.optionDigit(2)) == .dismissEditor(.edit(c), stash: true))
        #expect(flow.editingTodoID == nil)
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.selectedTodo?.title == "p")
    }

    @Test func optionDigitOfTheEditedQuadrantKeepsTheEditor() throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        flow.handle(.enter)
        #expect(flow.handle(.optionDigit(1)) == .handled)
        #expect(flow.editingTodoID == c)
    }

    @Test func focusByClickWhileEditingStashesTheEdit() throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        flow.handle(.enter)
        #expect(flow.focus(.urgentUnimportant) == .dismissEditor(.edit(c), stash: true))
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.selectedTodo?.title == "x")
        #expect(flow.focus(.urgentImportant) == .handled)
        #expect(flow.selectedTodo?.id == c)
    }

    @Test func closeEditorAfterASaveSelectsTheTodo() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        let b = try id(flow, "b")
        flow.handle(.enter)
        flow.closeEditor()
        #expect(flow.editingTodoID == nil)
        #expect(flow.selectedTodo?.id == b)
    }

    @Test func closeEditorAfterTheTodoLeftTheTileSelectsTheRowInItsPlace() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        let b = try id(flow, "b")
        flow.handle(.enter)
        // Saved with ⌘D: the todo is gone from the open todos.
        var all = Dictionary(uniqueKeysWithValues: Quadrant.allCases.map { ($0, flow.rows(in: $0)) })
        all[.urgentImportant]?.removeAll { $0.id == b }
        flow.reload(all)
        flow.closeEditor()
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.title == "a")
    }

    @Test func openEditorByClickFocusesTheTodosTile() throws {
        let flow = make()
        flow.toggleOverview()
        let x = try id(flow, "x")
        #expect(flow.openEditor(id: x) == .editInTile(x))
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.selectedTodo?.id == x)
        #expect(flow.editingTodoID == x)
    }

    @Test func openEditorOutsideTheOverviewDoesNothing() throws {
        let flow = make()
        let x = try id(flow, "x")
        #expect(flow.openEditor(id: x) == .ignored)
        #expect(flow.editingTodoID == nil)
    }

    // MARK: Focus and selection per quadrant

    @Test(arguments: [QuickEntryKey.digit(3), .optionDigit(3)])
    func digitsFocusAQuadrant(key: QuickEntryKey) {
        let flow = make()
        flow.toggleOverview()
        #expect(flow.handle(key) == .handled)
        #expect(flow.phase == .overview, "unlike the list, a digit doesn't leave the Overview")
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.selectedTodo?.title == "x")
    }

    @Test(arguments: [0, 5, 9])
    func otherDigitsDoNothing(n: Int) {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.digit(n))
        flow.handle(.optionDigit(n))
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.title == "c")
    }

    @Test func focusComesBackToTheTodoLastSelectedThere() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        flow.handle(.down) // a
        flow.handle(.digit(2))
        flow.handle(.down) // q
        flow.handle(.optionDigit(1))
        #expect(flow.selectedTodo?.title == "a")
        flow.handle(.digit(2))
        #expect(flow.selectedTodo?.title == "q")
        #expect(flow.selection(in: .urgentImportant)?.title == "a")
        #expect(flow.selection(in: .notUrgentImportant)?.title == "q")
    }

    @Test func focusFallsBackToTheFirstRowWhenTheRememberedTodoIsGone() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        let b = try id(flow, "b")
        flow.handle(.digit(2))
        flow.complete(id: b)
        flow.handle(.digit(1))
        #expect(flow.selectedTodo?.title == "c")
    }

    @Test func selectionIsRememberedAcrossLeavingTheOverview() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        flow.handle(.escape)
        flow.handle(.letter("o"))
        #expect(flow.selectedTodo?.title == "b")
    }

    @Test func pointerSelectOnlyActsOnTheFocusedTile() throws {
        let flow = make()
        flow.toggleOverview()
        let a = try id(flow, "a")
        let x = try id(flow, "x")
        flow.select(id: x)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.title == "c")
        flow.select(id: a)
        #expect(flow.selectedTodo?.id == a)
    }

    // MARK: List keys on the focused tile

    @Test func arrowsMoveTheSelectionInTheFocusedTile() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.digit(2))
        flow.handle(.down)
        flow.handle(.down)
        #expect(flow.selectedTodo?.title == "q")
        flow.handle(.up)
        #expect(flow.selectedTodo?.title == "p")
    }

    @Test func dCompletesAndBackspaceArchivesInTheFocusedTile() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.digit(2))
        let p = try id(flow, "p")
        let q = try id(flow, "q")
        #expect(flow.handle(.letter("d")) == .complete(p))
        #expect(titles(flow, .notUrgentImportant) == ["q"])
        #expect(flow.handle(.backspace) == .archive(q))
        #expect(flow.rows(in: .notUrgentImportant).isEmpty)
        #expect(flow.selectedIndex == nil)
        #expect(flow.phase == .overview)
    }

    @Test func commandDigitMovesTheSelectedTodoOnTopOfTheOtherTile() throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        #expect(flow.handle(.commandDigit(3)) == .move(c, from: .urgentImportant, to: .urgentUnimportant))
        #expect(titles(flow, .urgentImportant) == ["b", "a"])
        #expect(titles(flow, .urgentUnimportant) == ["c", "x"])
        #expect(flow.quadrant == .urgentImportant, "focus stays")
        #expect(flow.selectedTodo?.title == "b")
    }

    @Test func commandArrowsReorderTheFocusedTile() {
        let flow = make()
        flow.toggleOverview()
        #expect(flow.handle(.moveDown) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["b", "c", "a"])
        #expect(flow.selectedTodo?.title == "c")
        #expect(flow.handle(.moveUp) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
    }

    @Test func mOpensTheMovePickerAndADigitMoves() throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        flow.handle(.letter("m"))
        #expect(flow.movePicker?.todo.id == c)
        #expect(flow.handle(.escape) == .handled, "Esc closes only the picker")
        #expect(flow.phase == .overview)
        flow.handle(.letter("m"))
        #expect(flow.handle(.digit(4)) == .move(c, from: .urgentImportant, to: .notUrgentUnimportant))
        #expect(flow.movePicker == nil)
        #expect(flow.quadrant == .urgentImportant)
    }

    @Test func optionDigitClosesTheMovePickerAndFocuses() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("m"))
        #expect(flow.handle(.optionDigit(3)) == .handled)
        #expect(flow.movePicker == nil)
        #expect(flow.quadrant == .urgentUnimportant)
    }

    @Test func aOpensTheArchive() {
        let flow = make()
        flow.toggleOverview()
        #expect(flow.handle(.letter("a")) == .openArchive)
    }

    @Test func undoBringsTheTodoBackAndFocusesItsTile() throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        flow.handle(.letter("d"))
        flow.handle(.digit(3))
        #expect(flow.handle(.undo) == .restore(c))
        #expect(flow.phase == .overview)
        #expect(flow.quadrant == .urgentImportant)
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
        #expect(flow.selectedTodo?.id == c)
    }

    @Test func undoOfAMoveFocusesTheOldTile() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        let b = try id(flow, "b")
        flow.handle(.commandDigit(2))
        flow.handle(.digit(2))
        #expect(flow.handle(.undo) == .moveBack(b, to: .urgentImportant))
        #expect(flow.quadrant == .urgentImportant)
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
        #expect(titles(flow, .notUrgentImportant) == ["p", "q"])
        #expect(flow.selectedTodo?.id == b)
    }

    @Test(arguments: [QuickEntryKey.other, .space, .commandEnter, .letter("z")])
    func otherKeysAreSwallowed(key: QuickEntryKey) {
        let flow = make()
        flow.toggleOverview()
        #expect(flow.handle(key) == .handled)
        #expect(flow.phase == .overview)
        #expect(flow.selectedTodo?.title == "c")
    }

    // MARK: Tab cycles the focused tile

    @Test func tabFocusesTheNextQuadrantInPriorityOrderAndWraps() {
        let flow = make()
        flow.toggleOverview()
        #expect(flow.quadrant == .urgentImportant)
        var seen: [Quadrant] = []
        for _ in 0..<4 {
            #expect(flow.handle(.tab) == .handled)
            seen.append(flow.quadrant)
        }
        #expect(seen == [.notUrgentImportant, .urgentUnimportant, .notUrgentUnimportant, .urgentImportant])
        #expect(flow.phase == .overview)
    }

    @Test func shiftTabFocusesThePreviousQuadrantAndWraps() {
        let flow = make()
        flow.toggleOverview()
        var seen: [Quadrant] = []
        for _ in 0..<4 {
            #expect(flow.handle(.shiftTab) == .handled)
            seen.append(flow.quadrant)
        }
        #expect(seen == [.notUrgentUnimportant, .urgentUnimportant, .notUrgentImportant, .urgentImportant])
    }

    @Test func tabKeepsEachTilesSelection() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down) // "b" in Do first
        flow.handle(.tab)
        #expect(flow.selectedTodo?.title == "p")
        flow.handle(.down) // "q"
        flow.handle(.shiftTab)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.title == "b")
        flow.handle(.tab)
        #expect(flow.selectedTodo?.title == "q")
    }

    @Test(arguments: [QuickEntryKey.tab, .shiftTab])
    func tabInTheTileEditorIsLeftToTheEditor(key: QuickEntryKey) throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.enter)
        let editing = try #require(flow.editingTodoID)
        #expect(flow.handle(key) == .ignored)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.editingTodoID == editing)
    }

    @Test func tabWithTheMovePickerOpenDoesNotChangeFocus() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("m"))
        #expect(flow.movePicker != nil)
        flow.handle(.tab)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.movePicker != nil)
    }

    @Test func tabOutsideTheOverviewKeepsItsOldMeaning() {
        let picking = make()
        #expect(picking.handle(.tab) == .handled)
        #expect(picking.phase == .listing) // Tab opens the highlighted quadrant, like ↩
        #expect(picking.quadrant == .urgentImportant)

        let listing = make()
        listing.handle(.digit(2))
        listing.handle(.shiftTab) // back to the picker, like esc
        #expect(listing.phase == .picking)
        #expect(listing.quadrant == .notUrgentImportant)
    }

    @Test func reloadKeepsTheFocusedSelection() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        var all = Dictionary(uniqueKeysWithValues: Quadrant.allCases.map { ($0, flow.rows(in: $0)) })
        all[.urgentImportant]?.insert(TodoSnapshot(id: UUID(), title: "new", quadrant: .urgentImportant), at: 0)
        flow.reload(all)
        #expect(flow.selectedTodo?.title == "b")
        #expect(flow.phase == .overview)
    }

    // MARK: Drag and drop

    @Test func dropOnAnotherTileLandsAtTheInsertionPoint() throws {
        let flow = make()
        flow.toggleOverview()
        let b = try id(flow, "b")
        #expect(flow.drop(id: b, on: .notUrgentImportant, at: 1) == .place(b, from: .urgentImportant, to: .notUrgentImportant, index: 1))
        #expect(titles(flow, .urgentImportant) == ["c", "a"])
        #expect(titles(flow, .notUrgentImportant) == ["p", "b", "q"])
        #expect(flow.quadrant == .notUrgentImportant, "the drop focuses the target tile")
        #expect(flow.selectedTodo?.id == b)
    }

    @Test func dropOnAHeaderLandsOnTop() throws {
        let flow = make()
        flow.toggleOverview()
        let a = try id(flow, "a")
        #expect(flow.drop(id: a, on: .urgentUnimportant, at: 0) == .place(a, from: .urgentImportant, to: .urgentUnimportant, index: 0))
        #expect(titles(flow, .urgentUnimportant) == ["a", "x"])
    }

    @Test func dropPastTheEndClampsToTheEnd() throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        #expect(flow.drop(id: c, on: .notUrgentImportant, at: 99) == .place(c, from: .urgentImportant, to: .notUrgentImportant, index: 2))
        #expect(titles(flow, .notUrgentImportant) == ["p", "q", "c"])
    }

    @Test func dropOnAnEmptyTile() throws {
        let flow = make()
        flow.toggleOverview()
        let x = try id(flow, "x")
        #expect(flow.drop(id: x, on: .notUrgentUnimportant, at: 0) == .place(x, from: .urgentUnimportant, to: .notUrgentUnimportant, index: 0))
        #expect(titles(flow, .notUrgentUnimportant) == ["x"])
        #expect(flow.rows(in: .urgentUnimportant).isEmpty)
    }

    @Test func dropInsideTheSameTileReorders() throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        // Insertion point 2 = between b and a.
        #expect(flow.drop(id: c, on: .urgentImportant, at: 2) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["b", "c", "a"])
        let a = try id(flow, "a")
        #expect(flow.drop(id: a, on: .urgentImportant, at: 0) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["a", "b", "c"])
    }

    @Test func dropOnItsOwnPlaceDoesNothing() throws {
        let flow = make()
        flow.toggleOverview()
        let b = try id(flow, "b")
        #expect(flow.drop(id: b, on: .urgentImportant, at: 1) == .handled)
        #expect(flow.drop(id: b, on: .urgentImportant, at: 2) == .handled)
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
    }

    @Test func undoTakesBackADrop() throws {
        let flow = make()
        flow.toggleOverview()
        let b = try id(flow, "b")
        flow.drop(id: b, on: .notUrgentImportant, at: 1)
        #expect(flow.handle(.undo) == .moveBack(b, to: .urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
        #expect(titles(flow, .notUrgentImportant) == ["p", "q"])
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.id == b)
    }

    @Test func dropWithAnUnknownIdOrOutsideTheOverviewDoesNothing() throws {
        let flow = make()
        let c = try id(flow, "c")
        #expect(flow.drop(id: c, on: .notUrgentImportant, at: 0) == .ignored)
        flow.toggleOverview()
        #expect(flow.drop(id: UUID(), on: .notUrgentImportant, at: 0) == .ignored)
        #expect(titles(flow, .notUrgentImportant) == ["p", "q"])
    }

    @Test func dropWhileEditingKeepsTheFocusAndTheEditor() throws {
        let flow = make()
        flow.toggleOverview()
        let c = try id(flow, "c")
        let x = try id(flow, "x")
        flow.handle(.enter)
        #expect(flow.drop(id: x, on: .notUrgentImportant, at: 0) == .place(x, from: .urgentUnimportant, to: .notUrgentImportant, index: 0))
        #expect(titles(flow, .notUrgentImportant) == ["x", "p", "q"])
        #expect(flow.editingTodoID == c)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.id == c)
        let q = try id(flow, "q")
        #expect(flow.drop(id: q, on: .notUrgentImportant, at: 0) == .reorder(.notUrgentImportant), "reorders an unfocused tile")
        #expect(titles(flow, .notUrgentImportant) == ["q", "x", "p"])
        #expect(flow.drop(id: c, on: .notUrgentImportant, at: 0) == .ignored, "the edited todo stays put")
    }
}
