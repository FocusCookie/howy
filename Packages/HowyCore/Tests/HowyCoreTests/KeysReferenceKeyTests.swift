import Foundation
import Testing
@testable import HowyCore

/// "?" asks for the keys reference on the screens with nothing to type into (Browse's grid, list
/// and Overview, the archive). In text fields, tile editors and dialogs it stays a typed "?".
@MainActor
@Suite struct KeysReferenceKeyTests {
    // MARK: Mapping

    @Test func questionMarkIsMappedByItsCharacter() {
        // US: ⇧/ (key code 44); German: ⇧ß (key code 27). Both arrive as "?".
        #expect(QuickEntryKey(keyCode: 44, modifiers: .shift, characters: "?") == .questionMark)
        #expect(QuickEntryKey(keyCode: 27, modifiers: .shift, characters: "?") == .questionMark)
        #expect(QuickEntryKey(keyCode: 44, modifiers: [], characters: "?") == .questionMark)
    }

    @Test func otherShiftedKeysStayTyping() {
        #expect(QuickEntryKey(keyCode: 44, modifiers: .shift, characters: "/") == .other)
        #expect(QuickEntryKey(keyCode: 44, modifiers: [], characters: "/") == .other)
        #expect(QuickEntryKey(keyCode: 44, modifiers: [.command, .shift], characters: "?") == nil, "⌘? is the system's")
    }

    // MARK: Browse

    func todos(_ quadrant: Quadrant, _ titles: [String]) -> [TodoSnapshot] {
        titles.map { TodoSnapshot(id: UUID(), title: $0, quadrant: quadrant) }
    }

    func make() -> BrowseFlow {
        BrowseFlow(todos: [
            .urgentImportant: todos(.urgentImportant, ["a", "b"]),
            .notUrgentImportant: todos(.notUrgentImportant, ["p"]),
        ])
    }

    @Test func onTheGrid() {
        let flow = make()
        flow.handle(.right)
        #expect(flow.handle(.questionMark) == .showKeys)
        #expect(flow.phase == .picking)
        #expect(flow.quadrant == .notUrgentImportant)
    }

    @Test func inTheList() {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(.down)
        #expect(flow.handle(.questionMark) == .showKeys)
        #expect(flow.phase == .listing)
        #expect(flow.selectedTodo?.title == "b")
    }

    @Test func inTheOverview() {
        let flow = make()
        flow.handle(.letter(BrowseFlow.overviewKey))
        #expect(flow.handle(.questionMark) == .showKeys)
        #expect(flow.phase == .overview)
    }

    @Test func typedInAnOverviewTileEditor() {
        let flow = make()
        flow.handle(.letter(BrowseFlow.overviewKey))
        flow.handle(.enter)
        #expect(flow.tileEditor != nil)
        #expect(flow.handle(.questionMark) == .ignored)
    }

    @Test func typedInTheDueDateDialog() {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(.letter(BrowseFlow.dueKey))
        #expect(flow.dueDialog != nil)
        #expect(flow.handle(.questionMark) == .ignored)
        #expect(flow.dueDialog != nil)
    }

    @Test func swallowedByTheMovePicker() {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(.letter(BrowseFlow.moveKey))
        #expect(flow.handle(.questionMark) == .handled)
        #expect(flow.movePicker != nil)
    }

    @Test func ignoredOnceClosed() {
        let flow = make()
        flow.handle(.escape)
        #expect(flow.handle(.questionMark) == .ignored)
    }

    // MARK: Archive

    @Test func inTheArchive() {
        let ids = [UUID(), UUID()]
        let flow = ArchiveFlow(ids: ids)
        flow.handle(.down)
        #expect(flow.handle(.questionMark) == .showKeys)
        #expect(flow.ids == ids)
        #expect(flow.selectedID == ids[1])
    }

    // MARK: Editor

    @Test func typedInTheTitleAndTheNote() {
        let flow = QuickEntryFlow(mode: .create(.urgentImportant), lastUsed: MemoryLastQuadrantStore())
        #expect(!flow.handle(.questionMark), "the title field types it")
        flow.handle(.enter)
        #expect(flow.phase == .editingNote)
        #expect(!flow.handle(.questionMark), "the note types it")
    }

    @Test func typedInTheEditorsDialogs() {
        let flow = QuickEntryFlow(mode: .create(.urgentImportant), lastUsed: MemoryLastQuadrantStore(), dueDates: .fixture)
        flow.handle(.dueDate)
        #expect(flow.dueDialog != nil)
        #expect(!flow.handle(.questionMark), "the due-date field types it")
        flow.handle(.escape)
        flow.handle(.enter)
        flow.beginAddingLink(url: "https://example.com", replacing: NSRange(location: 0, length: 0))
        #expect(flow.linkDialog != nil)
        #expect(!flow.handle(.questionMark), "the link title field types it")
    }

    @Test func swallowedInTheEditorsPicker() {
        let flow = QuickEntryFlow(mode: .create(.urgentImportant), lastUsed: MemoryLastQuadrantStore())
        flow.handle(.shiftTab)
        #expect(flow.phase == .pickingQuadrant)
        #expect(flow.handle(.questionMark), "nothing to type into")
        #expect(flow.phase == .pickingQuadrant)
    }
}
