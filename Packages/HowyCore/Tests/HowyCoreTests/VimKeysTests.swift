import Foundation
import Testing
@testable import HowyCore

/// h/j/k/l next to the arrows, where there is nothing to type into: the grid and the move picker
/// (all four), Browse's list and the archive (j/k), the Overview (j/k in a tile, h/l and ←/→ to
/// the tile beside it). Text fields, tile editors and dialogs get the letters as typing.
@MainActor
@Suite struct VimKeysTests {
    func todos(_ quadrant: Quadrant, _ titles: [String]) -> [TodoSnapshot] {
        titles.map { TodoSnapshot(id: UUID(), title: $0, quadrant: quadrant) }
    }

    func make() -> BrowseFlow {
        BrowseFlow(todos: [
            .urgentImportant: todos(.urgentImportant, ["a", "b", "c"]),
            .notUrgentImportant: todos(.notUrgentImportant, ["p", "q"]),
            .urgentUnimportant: todos(.urgentUnimportant, ["x"]),
            .notUrgentUnimportant: todos(.notUrgentUnimportant, []),
        ])
    }

    func letter(_ c: Character) -> QuickEntryKey { .letter(c) }

    // MARK: Grid

    @Test func hjklMoveOnTheGridLikeTheArrows() {
        let flow = make()
        #expect(flow.handle(letter("l")) == .handled)
        #expect(flow.quadrant == .notUrgentImportant)
        flow.handle(letter("j"))
        #expect(flow.quadrant == .notUrgentUnimportant)
        flow.handle(letter("h"))
        #expect(flow.quadrant == .urgentUnimportant)
        flow.handle(letter("k"))
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.phase == .picking)
    }

    @Test func jFromTheBottomRowReachesTheArchiveButtonAndKComesBack() {
        let flow = make()
        flow.handle(letter("j"))
        flow.handle(letter("j"))
        #expect(flow.isArchiveHighlighted)
        flow.handle(letter("k"))
        #expect(!flow.isArchiveHighlighted)
        #expect(flow.quadrant == .urgentUnimportant)
    }

    // MARK: List

    @Test func jkMoveTheListSelection() {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(letter("j"))
        flow.handle(letter("j"))
        #expect(flow.selectedTodo?.title == "c")
        flow.handle(letter("j"))
        #expect(flow.selectedTodo?.title == "c", "clamped like ↓")
        flow.handle(letter("k"))
        #expect(flow.selectedTodo?.title == "b")
    }

    @Test func hAndLDoNothingInTheList() {
        let flow = make()
        flow.handle(.digit(1))
        #expect(flow.handle(letter("h")) == .handled)
        #expect(flow.handle(letter("l")) == .handled)
        #expect(flow.phase == .listing)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.title == "a")
    }

    @Test func theListsLetterKeysStillWork() throws {
        let flow = make()
        flow.handle(.digit(1))
        let first = try #require(flow.selectedTodo).id
        #expect(flow.handle(.letter(BrowseFlow.newKey)) == .newTodo(.urgentImportant))
        #expect(flow.handle(.letter(BrowseFlow.doneKey)) == .complete(first))
    }

    // MARK: Move picker

    @Test func hjklMoveTheMovePickersHighlight() throws {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(.letter(BrowseFlow.moveKey))
        #expect(flow.movePicker?.highlighted == .notUrgentImportant)
        flow.handle(letter("j"))
        #expect(flow.movePicker?.highlighted == .notUrgentUnimportant)
        flow.handle(letter("h"))
        #expect(flow.movePicker?.highlighted == .urgentUnimportant)
        flow.handle(letter("k"))
        #expect(flow.movePicker?.highlighted == .urgentImportant)
        flow.handle(letter("l"))
        #expect(flow.movePicker?.highlighted == .notUrgentImportant)
        #expect(flow.selectedTodo?.title == "a", "the list's selection stays")
    }

    // MARK: Overview

    func overview() -> BrowseFlow {
        let flow = make()
        flow.handle(.letter(BrowseFlow.overviewKey))
        return flow
    }

    @Test func jkMoveInsideTheFocusedTile() {
        let flow = overview()
        flow.handle(letter("j"))
        #expect(flow.selectedTodo?.title == "b")
        flow.handle(letter("k"))
        flow.handle(letter("k"))
        #expect(flow.selectedTodo?.title == "a")
        #expect(flow.quadrant == .urgentImportant)
    }

    @Test(arguments: [QuickEntryKey.up, .down, .letter("j"), .letter("k")])
    func upAndDownNeverLeaveTheTile(key: QuickEntryKey) {
        let flow = overview()
        for _ in 0..<5 { flow.handle(key) }
        #expect(flow.quadrant == .urgentImportant)
    }

    @Test(arguments: [(QuickEntryKey.right, QuickEntryKey.left), (.letter("l"), .letter("h"))])
    func leftAndRightFocusTheTileBeside(right: QuickEntryKey, left: QuickEntryKey) {
        let flow = overview()
        #expect(flow.handle(right) == .handled)
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.selectedTodo?.title == "p")
        flow.handle(right)
        #expect(flow.quadrant == .notUrgentImportant, "clamped at the right edge")
        flow.handle(left)
        #expect(flow.quadrant == .urgentImportant)
        flow.handle(left)
        #expect(flow.quadrant == .urgentImportant, "clamped at the left edge")
    }

    @Test func leftAndRightStayInTheBottomRow() {
        let flow = overview()
        flow.handle(.digit(3))
        flow.handle(.right)
        #expect(flow.quadrant == .notUrgentUnimportant)
        flow.handle(letter("h"))
        #expect(flow.quadrant == .urgentUnimportant)
    }

    @Test func hjklMoveTheMovePickerInTheOverview() {
        let flow = overview()
        flow.handle(.letter(BrowseFlow.moveKey))
        flow.handle(letter("j"))
        #expect(flow.movePicker?.highlighted == .notUrgentUnimportant)
        #expect(flow.quadrant == .urgentImportant, "the picker's, not the tiles'")
    }

    @Test func aTileEditorGetsTheLettersAsTyping() {
        let flow = overview()
        flow.handle(.enter)
        #expect(flow.tileEditor != nil)
        for c in "hjkl" { #expect(flow.handle(letter(c)) == .ignored) }
        #expect(flow.handle(.left) == .ignored)
        #expect(flow.quadrant == .urgentImportant)
    }

    // MARK: Due-date dialog

    @Test func theDueDateDialogGetsTheLettersAsTyping() {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(.letter(BrowseFlow.dueKey))
        #expect(flow.dueDialog != nil)
        for c in "hjkl" { #expect(flow.handle(letter(c)) == .ignored) }
        #expect(flow.selectedTodo?.title == "a")
    }

    // MARK: Archive

    @Test func jkMoveTheArchiveSelection() {
        let ids = [UUID(), UUID(), UUID()]
        let flow = ArchiveFlow(ids: ids)
        flow.handle(letter("j"))
        flow.handle(letter("j"))
        flow.handle(letter("j"))
        #expect(flow.selectedID == ids[2])
        flow.handle(letter("k"))
        #expect(flow.selectedID == ids[1])
    }
}
