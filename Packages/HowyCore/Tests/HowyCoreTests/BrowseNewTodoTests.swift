import Foundation
import Testing
@testable import HowyCore

/// `n` in Browse: a new todo in the quadrant being browsed, from the list (the create screen) or
/// the Overview (a create editor in the focused tile).
@MainActor
@Suite struct BrowseNewTodoTests {
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

    func id(_ flow: BrowseFlow, _ title: String) throws -> UUID {
        try #require(Quadrant.allCases.flatMap { flow.rows(in: $0) }.first { $0.title == title }).id
    }

    /// The data after the store saved a new todo on top of `quadrant`.
    func adding(_ todo: TodoSnapshot, to flow: BrowseFlow) -> [Quadrant: [TodoSnapshot]] {
        var all: [Quadrant: [TodoSnapshot]] = [:]
        for q in Quadrant.allCases { all[q] = flow.rows(in: q) }
        all[todo.quadrant, default: []].insert(todo, at: 0)
        return all
    }

    // MARK: List

    @Test func nInTheListAsksForANewTodoInThatQuadrant() {
        let flow = make()
        flow.handle(.digit(2))
        flow.handle(.down)
        #expect(flow.handle(.letter(BrowseFlow.newKey)) == .newTodo(.notUrgentImportant))
        #expect(flow.phase == .listing, "the list stays as it was, for coming back")
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.selectedTodo?.title == "q")
    }

    @Test func nWorksOnAnEmptyQuadrant() {
        let flow = make()
        flow.handle(.digit(4))
        #expect(flow.rows.isEmpty)
        #expect(flow.handle(.letter("n")) == .newTodo(.notUrgentUnimportant))
    }

    @Test func nInThePickerIsIgnored() {
        let flow = make()
        flow.handle(.right)
        #expect(flow.handle(.letter("n")) == .handled)
        #expect(flow.phase == .picking)
        #expect(flow.quadrant == .notUrgentImportant)
    }

    @Test func nWithTheMovePickerOpenDoesNothing() {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(.letter("m"))
        #expect(flow.handle(.letter("n")) == .handled)
        #expect(flow.movePicker != nil)
    }

    @Test func comingBackAfterSavingSelectsTheNewTodoOnTop() {
        let flow = make()
        let new = TodoSnapshot(id: UUID(), title: "new", quadrant: .urgentUnimportant)
        // The create screen saved into another quadrant (⇧⇥) than the one browsed.
        let resumed = BrowseFlow(todos: adding(new, to: flow))
        resumed.resumeListing(.urgentUnimportant, selecting: new.id, fallbackIndex: 0)
        #expect(resumed.phase == .listing)
        #expect(resumed.quadrant == .urgentUnimportant)
        #expect(resumed.rows.map(\.title) == ["new", "x"])
        #expect(resumed.selectedTodo?.id == new.id)
    }

    @Test func comingBackAfterEscKeepsTheEarlierSelection() throws {
        let flow = make()
        flow.handle(.digit(1))
        flow.handle(.down)
        let b = try id(flow, "b")
        #expect(flow.handle(.letter("n")) == .newTodo(.urgentImportant))
        // Esc on the create screen: Browse comes back from the same data and selection.
        let resumed = BrowseFlow(todos: adding(TodoSnapshot(id: UUID(), title: "-", quadrant: .urgentImportant), to: flow))
        resumed.reload([.urgentImportant: flow.rows(in: .urgentImportant)])
        resumed.resumeListing(.urgentImportant, selecting: b, fallbackIndex: flow.selectedIndex)
        #expect(resumed.selectedTodo?.id == b)
    }

    // MARK: Overview

    @Test func nInTheOverviewOpensACreateEditorInTheFocusedTile() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.digit(3))
        #expect(flow.handle(.letter("n")) == .createInTile(.urgentUnimportant))
        #expect(flow.tileEditor == .create(.urgentUnimportant))
        #expect(flow.editingTodoID == nil, "no todo is being edited yet")
        #expect(flow.phase == .overview)
        #expect(flow.selectedTodo?.title == "x", "the tile keeps its selection under the editor")
    }

    @Test func nOnAnEmptyTileOpensTheCreateEditor() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.digit(4))
        #expect(flow.handle(.letter("n")) == .createInTile(.notUrgentUnimportant))
        #expect(flow.tileEditor == .create(.notUrgentUnimportant))
    }

    @Test func keysWhileCreatingAreTheEditors() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("n"))
        for key: QuickEntryKey in [.letter("n"), .letter("d"), .letter("o"), .digit(2), .enter, .down, .backspace, .commandEnter] {
            #expect(flow.handle(key) == .ignored)
        }
        #expect(flow.tileEditor == .create(.urgentImportant))
        #expect(flow.rows(in: .urgentImportant).count == 3)
    }

    @Test func escFromTileCreateStashesAndKeepsTheEarlierSelection() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        let b = try id(flow, "b")
        flow.handle(.letter("n"))
        #expect(flow.handle(.escape) == .dismissEditor(.create(.urgentImportant), stash: true))
        #expect(flow.tileEditor == nil)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedTodo?.id == b)
        #expect(flow.handle(.escape) == .hideOverview, "second Esc: back to the grid")
    }

    @Test func switchingTilesWhileCreatingStashesAndMovesFocus() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("n"))
        #expect(flow.handle(.optionDigit(2)) == .dismissEditor(.create(.urgentImportant), stash: true))
        #expect(flow.tileEditor == nil)
        #expect(flow.quadrant == .notUrgentImportant)
        #expect(flow.selectedTodo?.title == "p")
    }

    @Test func clickingAnotherTileWhileCreatingStashesAndMovesFocus() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("n"))
        #expect(flow.focus(.urgentUnimportant) == .dismissEditor(.create(.urgentImportant), stash: true))
        #expect(flow.tileEditor == nil)
        #expect(flow.quadrant == .urgentUnimportant)
    }

    @Test func openingATodoWhileCreatingReplacesTheCreateEditor() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("n"))
        let p = try id(flow, "p")
        #expect(flow.openEditor(id: p) == .editInTile(p))
        #expect(flow.tileEditor == .edit(p))
        #expect(flow.editingTodoID == p)
    }

    @Test func savingFocusesTheTileItWasSavedIntoWithTheNewTodoSelected() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("n"))
        // Saved into another quadrant (⇧⇥ in the editor): the store put it on top there.
        let new = TodoSnapshot(id: UUID(), title: "new", quadrant: .notUrgentUnimportant)
        flow.reload(adding(new, to: flow))
        flow.closeEditor(created: new.id)
        #expect(flow.tileEditor == nil)
        #expect(flow.phase == .overview)
        #expect(flow.quadrant == .notUrgentUnimportant)
        #expect(flow.selectedTodo?.id == new.id)
    }

    @Test func savingIntoTheSameTileSelectsTheNewTodoOnTop() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.down)
        flow.handle(.letter("n"))
        let new = TodoSnapshot(id: UUID(), title: "new", quadrant: .urgentImportant)
        flow.reload(adding(new, to: flow))
        flow.closeEditor(created: new.id)
        #expect(flow.quadrant == .urgentImportant)
        #expect(flow.selectedIndex == 0)
        #expect(flow.selectedTodo?.id == new.id)
    }

    @Test func theFocusedTileTakesNoDropsWhileCreating() throws {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("n"))
        #expect(flow.canDrop(on: .urgentImportant) == false)
        #expect(flow.canDrop(on: .notUrgentImportant))
        let p = try id(flow, "p")
        #expect(flow.drop(id: p, on: .notUrgentImportant, at: 2) == .reorder(.notUrgentImportant))
        #expect(flow.quadrant == .urgentImportant, "focus stays on the tile being created in")
        #expect(flow.tileEditor == .create(.urgentImportant))
    }

    @Test func hidingTheOverviewClosesTheCreateEditor() {
        let flow = make()
        flow.toggleOverview()
        flow.handle(.letter("n"))
        #expect(flow.toggleOverview() == .hideOverview)
        #expect(flow.tileEditor == nil)
    }
}

/// The create flow Browse opens: the browsed quadrant wins over the "New todo starts in" setting
/// and over a stashed draft's quadrant; the draft's text is still restored.
@MainActor
@Suite struct BrowseCreateQuadrantTests {
    let drafts = MemoryDraftStore()
    let lastUsed = MemoryLastQuadrantStore(.urgentImportant)

    func makeCreate(in quadrant: Quadrant, startQuadrant: NewTodoQuadrant) -> QuickEntryFlow {
        QuickEntryFlow(
            mode: .create(preselected: quadrant, startingInTitle: true),
            lastUsed: lastUsed, drafts: drafts, startQuadrant: startQuadrant
        )
    }

    @Test func browsedQuadrantBeatsAFixedStartQuadrantAndStartsInTheTitle() {
        let flow = makeCreate(in: .urgentUnimportant, startQuadrant: .fixed(.notUrgentImportant))
        #expect(flow.quadrant == .urgentUnimportant)
        #expect(flow.phase == .editingTitle)
        #expect(flow.title.isEmpty)
    }

    @Test func browsedQuadrantBeatsTheDraftsQuadrantButKeepsItsText() {
        drafts.setCreateDraft(StashedDraft(quadrant: .notUrgentImportant, title: "Call Bob", note: "re: invoice", field: .title))
        let flow = makeCreate(in: .notUrgentUnimportant, startQuadrant: .fixed(.urgentImportant))
        #expect(flow.quadrant == .notUrgentUnimportant)
        #expect(flow.title == "Call Bob")
        #expect(flow.note == "re: invoice")
        #expect(flow.isRestoredDraft)
        #expect(flow.phase == .editingTitle)
    }

    @Test func aDraftStashedAtThePickerStillStartsInTheTitle() {
        drafts.setCreateDraft(StashedDraft(quadrant: .notUrgentImportant, title: "Half", note: "", field: .quadrant))
        let flow = makeCreate(in: .urgentUnimportant, startQuadrant: .lastUsed)
        #expect(flow.phase == .editingTitle)
        #expect(flow.quadrant == .urgentUnimportant)
    }

    @Test func shiftTabStillReachesThePickerAndSavingThereUpdatesLastUsed() {
        let flow = makeCreate(in: .urgentUnimportant, startQuadrant: .lastUsed)
        flow.title = "Walk"
        flow.handle(.shiftTab)
        #expect(flow.phase == .pickingQuadrant)
        flow.handle(.digit(4))
        flow.handle(.commandEnter)
        #expect(flow.savedDraft?.quadrant == .notUrgentUnimportant)
        #expect(lastUsed.load() == .notUrgentUnimportant)
        #expect(drafts.createDraft() == nil)
    }

    @Test func escStashesTheDraftInTheSharedCreateSlot() {
        let flow = makeCreate(in: .urgentUnimportant, startQuadrant: .lastUsed)
        flow.title = "Later"
        flow.handle(.escape)
        #expect(drafts.createDraft()?.title == "Later")
        // Quick Add picks it up next.
        let quickAdd = QuickEntryFlow(mode: .create(), lastUsed: lastUsed, drafts: drafts)
        #expect(quickAdd.title == "Later")
        #expect(quickAdd.quadrant == .urgentUnimportant)
    }
}
