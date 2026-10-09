import Foundation
import Testing
@testable import HowyCore

/// The Overview's reorder undo, drop rules, nudges, and the edges of its key handling.
@MainActor
@Suite struct BrowseOverviewEdgeTests {
    let base = BrowseOverviewTests()

    func make() -> BrowseFlow { base.make() }
    func titles(_ flow: BrowseFlow, _ quadrant: Quadrant) -> [String] { base.titles(flow, quadrant) }
    func id(_ flow: BrowseFlow, _ title: String) throws -> UUID { try base.id(flow, title) }

    func overview() -> BrowseFlow {
        let flow = make()
        flow.toggleOverview()
        return flow
    }

    // MARK: Reorder undo

    @Test func undoTakesBackADropInsideOneTile() throws {
        let flow = overview()
        let c = try id(flow, "c")
        #expect(flow.drop(id: c, on: .urgentImportant, at: 3) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["b", "a", "c"])
        #expect(flow.canUndo)
        #expect(flow.handle(.undo) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
        #expect(flow.selectedTodo?.id == c)
        #expect(flow.canUndo == false)
    }

    @Test(arguments: [QuickEntryKey.moveDown, .moveUp])
    func undoTakesBackACommandArrowReorder(key: QuickEntryKey) {
        let flow = overview()
        flow.handle(.down) // b
        #expect(flow.handle(key) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) != ["c", "b", "a"])
        #expect(flow.handle(.undo) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
        #expect(flow.selectedTodo?.title == "b")
    }

    @Test func undoTakesBackACommandArrowReorderInTheList() {
        let flow = make()
        flow.handle(.digit(1))
        #expect(flow.handle(.moveDown) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["b", "c", "a"])
        #expect(flow.handle(.undo) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
        #expect(flow.selectedTodo?.title == "c")
    }

    @Test func aReorderAtTheEndRecordsNothing() {
        let flow = overview()
        #expect(flow.handle(.moveUp) == .handled)
        #expect(flow.canUndo == false)
    }

    @Test func undoOfAReorderFromTheGridHighlightsThatQuadrant() throws {
        let flow = overview()
        let p = try id(flow, "p")
        flow.drop(id: p, on: .notUrgentImportant, at: 2)
        flow.handle(.escape)
        #expect(flow.phase == .picking)
        flow.handle(.left)
        #expect(flow.handle(.undo) == .reorder(.notUrgentImportant))
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(titles(flow, .notUrgentImportant) == ["p", "q"])
    }

    @Test func aListDragIsOneUndo() throws {
        let flow = make()
        flow.handle(.digit(1))
        let c = try id(flow, "c")
        flow.beginReorderDrag(id: c)
        flow.move(id: c, to: 1)
        flow.move(id: c, to: 2)
        #expect(flow.endReorderDrag() == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["b", "a", "c"])
        #expect(flow.handle(.undo) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
        #expect(flow.canUndo == false)
    }

    @Test func aListDragThatEndsWhereItBeganRecordsNothing() throws {
        let flow = make()
        flow.handle(.digit(1))
        let c = try id(flow, "c")
        flow.beginReorderDrag(id: c)
        flow.move(id: c, to: 1)
        flow.move(id: c, to: 0)
        #expect(flow.endReorderDrag() == .handled)
        #expect(flow.canUndo == false)
        #expect(flow.endReorderDrag() == .ignored, "no drag")
    }

    // MARK: Nudge

    @Test func nudgeMovesOneRowAndFocusesTheTile() throws {
        let flow = overview()
        let p = try id(flow, "p")
        #expect(flow.nudge(id: p, by: 1) == .reorder(.notUrgentImportant))
        #expect(titles(flow, .notUrgentImportant) == ["q", "p"])
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.selectedTodo?.id == p)
        #expect(flow.nudge(id: p, by: 1) == .handled, "already last")
        #expect(flow.nudge(id: p, by: -1) == .reorder(.notUrgentImportant))
        #expect(titles(flow, .notUrgentImportant) == ["p", "q"])
        flow.handle(.undo)
        #expect(titles(flow, .notUrgentImportant) == ["q", "p"])
    }

    @Test func nudgeIsRefusedForTheEditedTileAndUnknownIds() throws {
        let flow = overview()
        let b = try id(flow, "b")
        let p = try id(flow, "p")
        flow.handle(.enter) // edit c
        #expect(flow.nudge(id: b, by: 1) == .ignored, "the focused tile is under the editor")
        #expect(flow.nudge(id: p, by: 1) == .reorder(.notUrgentImportant), "another tile is fine")
        #expect(flow.quadrant == .urgentImportant, "the editor keeps the focus")
        #expect(flow.nudge(id: UUID(), by: 1) == .ignored)
    }

    @Test func nudgeInTheListOnlyActsOnTheShownQuadrant() throws {
        let flow = make()
        flow.handle(.digit(1))
        let p = try id(flow, "p")
        let b = try id(flow, "b")
        #expect(flow.nudge(id: p, by: 1) == .ignored)
        #expect(flow.nudge(id: b, by: -1) == .reorder(.urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["b", "c", "a"])
        let closed = make()
        #expect(closed.nudge(id: b, by: 1) == .ignored, "the picker shows no rows")
    }

    // MARK: Move to

    @Test func moveToQuadrantIsTheOnePath() throws {
        let flow = overview()
        let b = try id(flow, "b")
        #expect(flow.move(id: b, toQuadrant: .urgentImportant) == .handled, "its own quadrant")
        #expect(flow.move(id: b, toQuadrant: .notUrgentUnimportant) == .move(b, from: .urgentImportant, to: .notUrgentUnimportant))
        #expect(titles(flow, .notUrgentUnimportant) == ["b"])
        #expect(flow.move(id: UUID(), toQuadrant: .urgentImportant) == .ignored)
        #expect(flow.handle(.undo) == .moveBack(b, to: .urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
    }

    // MARK: canDrop

    @Test func theEditedTileTakesNoDrops() throws {
        let flow = overview()
        #expect(Quadrant.allCases.allSatisfy(flow.canDrop(on:)))
        flow.handle(.enter)
        #expect(flow.canDrop(on: .urgentImportant) == false)
        #expect(flow.canDrop(on: .notUrgentImportant))
        let x = try id(flow, "x")
        let b = try id(flow, "b")
        #expect(flow.drop(id: x, on: .urgentImportant, at: 0) == .ignored)
        #expect(flow.drop(id: b, on: .urgentImportant, at: 3) == .ignored)
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
        #expect(titles(flow, .urgentUnimportant) == ["x"])
        flow.handle(.escape)
        #expect(flow.canDrop(on: .urgentImportant))
    }

    @Test func noTileTakesDropsOutsideTheOverview() {
        let flow = make()
        #expect(Quadrant.allCases.allSatisfy { !flow.canDrop(on: $0) })
    }

    // MARK: Drop clamping

    @Test(arguments: [(-5, ["c", "b", "a"]), (0, ["c", "b", "a"]), (1, ["c", "b", "a"]), (2, ["b", "c", "a"]),
                      (3, ["b", "a", "c"]), (99, ["b", "a", "c"])])
    func sameTileDropIndicesAreClamped(index: Int, expected: [String]) throws {
        let flow = overview()
        let c = try id(flow, "c")
        let unchanged = expected == ["c", "b", "a"]
        #expect(flow.dropIsNoOp(id: c, on: .urgentImportant, at: index) == unchanged)
        #expect(flow.drop(id: c, on: .urgentImportant, at: index) == (unchanged ? .handled : .reorder(.urgentImportant)))
        #expect(titles(flow, .urgentImportant) == expected)
    }

    @Test(arguments: [(-5, 0), (0, 0), (1, 1), (2, 2), (3, 2), (99, 2)])
    func crossTileDropIndicesAreClamped(index: Int, landed: Int) throws {
        let flow = overview()
        let c = try id(flow, "c")
        #expect(flow.drop(id: c, on: .notUrgentImportant, at: index) == .place(c, from: .urgentImportant, to: .notUrgentImportant, index: landed))
        #expect(flow.rows(in: .notUrgentImportant)[landed].id == c)
    }

    @Test func lastRowDroppedAtTheEndOrPastItDoesNothing() throws {
        let flow = overview()
        let a = try id(flow, "a")
        #expect(flow.drop(id: a, on: .urgentImportant, at: 3) == .handled, "the row count")
        #expect(flow.drop(id: a, on: .urgentImportant, at: 4) == .handled, "the row count + 1")
        let c = try id(flow, "c")
        #expect(flow.drop(id: c, on: .urgentImportant, at: 0) == .handled, "the top row on top")
        #expect(flow.canUndo == false)
    }

    @Test func twoCrossDropsThenTwoUndos() throws {
        let flow = overview()
        let c = try id(flow, "c")
        let b = try id(flow, "b")
        flow.drop(id: c, on: .notUrgentImportant, at: 1)
        flow.drop(id: b, on: .urgentUnimportant, at: 0)
        #expect(titles(flow, .urgentImportant) == ["a"])
        #expect(flow.handle(.undo) == .moveBack(b, to: .urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["b", "a"])
        #expect(flow.handle(.undo) == .moveBack(c, to: .urgentImportant))
        #expect(titles(flow, .urgentImportant) == ["c", "b", "a"])
        #expect(titles(flow, .notUrgentImportant) == ["p", "q"])
        #expect(titles(flow, .urgentUnimportant) == ["x"])
    }

    @Test func undoOfADropBelowTheFocusedTilesOtherRowsKeepsAValidSelection() throws {
        // b lands last in x's tile and is selected there; ⌘Z takes it out of that (focused) tile.
        let flow = overview()
        let b = try id(flow, "b")
        #expect(flow.drop(id: b, on: .urgentUnimportant, at: 1) == .place(b, from: .urgentImportant, to: .urgentUnimportant, index: 1))
        #expect(flow.selectedIndex == 1)
        #expect(flow.handle(.undo) == .moveBack(b, to: .urgentImportant))
        #expect(flow.selection(in: .urgentUnimportant)?.title == "x")
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.id == b)
        #expect(titles(flow, .urgentUnimportant) == ["x"])
    }

    // MARK: Move picker and the editor

    @Test func openingTheEditorClosesTheMovePicker() throws {
        let flow = overview()
        flow.handle(.letter("m"))
        #expect(flow.movePicker != nil)
        let c = try id(flow, "c")
        #expect(flow.openEditor(id: c) == .editInTile(c))
        #expect(flow.movePicker == nil)
        flow.closeEditor()
        #expect(flow.movePicker == nil)
    }

    @Test func aClickOnTheFocusedHeaderClosesTheMovePicker() {
        let flow = overview()
        flow.handle(.letter("m"))
        #expect(flow.focus(.urgentImportant) == .handled)
        #expect(flow.movePicker == nil)
    }

    @Test func closeFromTheOverviewWithTheMovePickerOpen() {
        let flow = overview()
        flow.handle(.letter("m"))
        #expect(flow.close() == .close)
        #expect(flow.movePicker == nil)
        #expect(flow.phase == .closed)
    }

    // MARK: Keys

    @Test(arguments: [0, 5, 9])
    func otherOptionDigitsWhileEditingKeepTheEditor(n: Int) throws {
        let flow = overview()
        flow.handle(.enter)
        let c = try id(flow, "c")
        #expect(flow.handle(.optionDigit(n)) == .handled)
        #expect(flow.editingTodoID == c)
        #expect(flow.quadrant == .urgentImportant)
    }

    @Test func optionDigitsOutsideTheOverviewChangeNothing() {
        let flow = make()
        #expect(flow.handle(.optionDigit(2)) == .handled)
        #expect(flow.phase == .picking)
        #expect(flow.quadrant == .urgentImportant)
        flow.handle(.digit(3))
        #expect(flow.handle(.optionDigit(2)) == .handled)
        #expect(flow.phase == .listing)
        #expect(flow.quadrant == .urgentUnimportant)
    }

    @Test func optionDigitAwayFromAnEditAndBackSelectsTheEditedTodo() throws {
        let flow = overview()
        flow.handle(.down) // b
        let b = try id(flow, "b")
        flow.handle(.enter)
        #expect(flow.handle(.optionDigit(2)) == .dismissEditor(b, stash: true))
        #expect(flow.selection(in: .urgentImportant)?.id == b)
        #expect(flow.handle(.optionDigit(1)) == .handled)
        #expect(flow.selectedTodo?.id == b)
        #expect(flow.editingTodoID == nil)
    }

    @Test func theEscapeLadder() throws {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(.letter("o"))
        let c = try id(flow, "c")
        flow.handle(.enter)
        #expect(flow.handle(.escape) == .dismissEditor(c, stash: false), "editor → tile")
        #expect(flow.phase == .overview)
        #expect(flow.handle(.escape) == .hideOverview, "tile → grid")
        #expect(flow.phase == .picking)
        #expect(flow.handle(.escape) == .close, "grid → closed")
        #expect(flow.phase == .closed)
        #expect(flow.handle(.escape) == .ignored)
    }

    @Test func escapeOnAnEmptyFocusedTileGoesBackToTheGrid() {
        let flow = overview()
        flow.handle(.digit(4))
        #expect(flow.selectedIndex == nil)
        #expect(flow.handle(.escape) == .hideOverview)
        #expect(flow.quadrant == .notUrgentUnimportant)
    }

    @Test func oInsideTheOverviewIsSwallowed() {
        let flow = overview()
        #expect(flow.handle(.letter("o")) == .handled)
        #expect(flow.phase == .overview)
    }

    @Test func archiveAndBack() {
        let flow = overview()
        flow.handle(.digit(2))
        #expect(flow.handle(.letter("a")) == .openArchive)
        // The app shows the archive, then comes back to the grid with the Archive button lit.
        flow.handle(.escape)
        flow.highlightArchive()
        #expect(flow.isArchiveHighlighted)
        #expect(flow.handle(.letter("o")) == .showOverview)
        #expect(flow.quadrant == .notUrgentImportant)
    }
}
