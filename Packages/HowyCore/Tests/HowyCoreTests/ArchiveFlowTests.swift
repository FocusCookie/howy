import Foundation
import Testing
@testable import HowyCore

@MainActor
@Suite struct ArchiveFlowTests {
    let ids = (0..<4).map { _ in UUID() }

    func make() -> ArchiveFlow { ArchiveFlow(ids: ids) }

    @Test func startsOnTheFirstRow() {
        let flow = make()
        #expect(flow.selectedIndex == 0)
        #expect(flow.selectedID == ids[0])
        #expect(ArchiveFlow(ids: []).selectedIndex == nil)
    }

    @Test func arrowsMoveAndClamp() {
        let flow = make()
        #expect(flow.handle(.up) == .handled)
        #expect(flow.selectedIndex == 0)
        flow.handle(.down)
        flow.handle(.down)
        #expect(flow.selectedIndex == 2)
        for _ in 0..<5 { flow.handle(.down) }
        #expect(flow.selectedIndex == 3)
        flow.handle(.up)
        #expect(flow.selectedIndex == 2)
    }

    @Test func restoreKeyRestoresTheSelectedRowAndMovesOn() {
        let flow = make()
        flow.handle(.down)
        #expect(flow.handle(.letter("r")) == .restore(ids[1]))
        #expect(flow.ids == [ids[0], ids[2], ids[3]])
        #expect(flow.selectedID == ids[2], "the row below moves up into the gap")
    }

    @Test(arguments: [QuickEntryKey.backspace, .commandDelete])
    func deleteKeysDeleteTheSelectedRow(key: QuickEntryKey) {
        let flow = make()
        #expect(flow.handle(key) == .delete(ids[0]))
        #expect(flow.ids == Array(ids[1...]))
        #expect(flow.selectedIndex == 0)
    }

    @Test func removingTheLastRowSelectsTheNewLast() {
        let flow = make()
        for _ in 0..<3 { flow.handle(.down) }
        #expect(flow.handle(.backspace) == .delete(ids[3]))
        #expect(flow.selectedID == ids[2])
    }

    @Test func removingAnotherRowKeepsTheSelectedTodo() {
        let flow = make()
        flow.handle(.down)
        flow.handle(.down)
        #expect(flow.remove(id: ids[0]))
        #expect(flow.selectedID == ids[2])
        #expect(flow.selectedIndex == 1)
        #expect(!flow.remove(id: UUID()))
    }

    @Test func emptyingTheListClearsTheSelectionAndKeysDoNothing() {
        let flow = ArchiveFlow(ids: [ids[0]])
        #expect(flow.handle(.letter("r")) == .restore(ids[0]))
        #expect(flow.selectedIndex == nil)
        #expect(flow.handle(.letter("r")) == .handled)
        #expect(flow.handle(.backspace) == .handled)
        #expect(flow.handle(.down) == .handled)
        #expect(flow.handle(.escape) == .close)
    }

    @Test func escapeClosesAndOtherKeysAreSwallowed() {
        let flow = make()
        #expect(flow.handle(.escape) == .close)
        #expect(flow.handle(.letter("x")) == .handled)
        #expect(flow.handle(.digit(1)) == .handled)
        #expect(flow.handle(.enter) == .handled)
        #expect(flow.handle(.other) == .handled)
        #expect(flow.selectedIndex == 0)
    }

    @Test func selectByIDAndReloadKeepOrClamp() {
        let flow = make()
        flow.select(id: ids[2])
        #expect(flow.selectedIndex == 2)
        flow.select(id: UUID())
        #expect(flow.selectedIndex == 2)

        flow.reload(ids: [ids[2], ids[3]])
        #expect(flow.selectedIndex == 0, "follows the todo")
        flow.select(id: ids[3])
        flow.reload(ids: [ids[0]])
        #expect(flow.selectedIndex == 0, "clamped")
        flow.reload(ids: [])
        #expect(flow.selectedIndex == nil)
    }
}
