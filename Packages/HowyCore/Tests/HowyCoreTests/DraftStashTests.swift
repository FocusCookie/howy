import Foundation
import Testing
@testable import HowyCore

@MainActor
@Suite struct DraftStashTests {
    let drafts = MemoryDraftStore()
    let lastUsed = MemoryLastQuadrantStore()

    func makeCreate(preselected: Quadrant? = nil) -> QuickEntryFlow {
        QuickEntryFlow(mode: .create(preselected: preselected), lastUsed: lastUsed, drafts: drafts)
    }

    func makeEdit(_ source: QuickEntryDraft) -> QuickEntryFlow {
        QuickEntryFlow(mode: .edit(source), lastUsed: lastUsed, drafts: drafts)
    }

    // MARK: create mode

    @Test func escapeInCreateModeStashesAndNextQuickAddRestores() {
        let flow = makeCreate()
        flow.handle(.digit(2))
        flow.title = "Call landlord"
        flow.handle(.enter)
        flow.note = "about the heating"
        flow.handle(.escape)
        #expect(flow.phase == .cancelled)

        let next = makeCreate()
        #expect(next.isRestoredDraft)
        #expect(next.quadrant == .notUrgentImportant)
        #expect(next.title == "Call landlord")
        #expect(next.note == "about the heating")
        #expect(next.phase == .editingNote, "back in the field it was in")
    }

    @Test func startingInTitleKeepsTheDraftButSkipsTheStashedPicker() {
        let flow = makeCreate()
        flow.title = "Call landlord"
        flow.abandon()

        let next = QuickEntryFlow(
            mode: .create(preselected: .urgentUnimportant, startingInTitle: true),
            lastUsed: lastUsed, drafts: drafts
        )
        #expect(next.title == "Call landlord")
        #expect(next.quadrant == .urgentUnimportant)
        #expect(next.phase == .editingTitle)
    }

    @Test(arguments: [QuickEntryFlow.Phase.pickingQuadrant, .editingTitle, .editingNote])
    func abandonStashesThePhase(phase: QuickEntryFlow.Phase) {
        let flow = makeCreate()
        flow.title = "x"
        flow.focus(phase)
        flow.abandon()
        #expect(makeCreate().phase == phase)
    }

    @Test func abandonedFlowKeepsItsPhaseButIgnoresKeys() {
        let flow = makeCreate()
        flow.handle(.enter)
        flow.title = "x"
        flow.abandon()
        #expect(flow.phase == .editingTitle, "no picker/fields flip while the panel fades out")
        #expect(!flow.handle(.commandEnter))
        #expect(flow.savedDraft == nil)
        flow.title = "changed later"
        flow.abandon()
        #expect(drafts.createDraft()?.title == "x", "only the first abandon stashes")
    }

    @Test func abandonAfterFinishIsANoOp() {
        let flow = makeCreate()
        flow.handle(.enter)
        flow.title = "Saved"
        flow.handle(.commandEnter)
        flow.abandon()
        #expect(drafts.createDraft() == nil)
        #expect(!makeCreate().isRestoredDraft)
    }

    @Test func emptyDraftIsNotStashedAndClearsAnOldOne() {
        drafts.setCreateDraft(StashedDraft(quadrant: .urgentImportant, title: "old", note: "", field: .title))
        let flow = makeCreate()
        flow.title = ""
        flow.note = "  "
        flow.abandon()
        #expect(drafts.createDraft() == nil)
        let next = makeCreate()
        #expect(!next.isRestoredDraft)
        #expect(next.phase == .pickingQuadrant)
    }

    @Test func noteOnlyDraftIsStashed() {
        let flow = makeCreate()
        flow.focus(.editingNote)
        flow.note = "just a note"
        flow.abandon()
        #expect(makeCreate().note == "just a note")
    }

    @Test func successfulSaveClearsTheStash() {
        let first = makeCreate()
        first.title = "Draft"
        first.abandon()
        let restored = makeCreate()
        #expect(restored.isRestoredDraft)
        restored.handle(.commandEnter)
        #expect(restored.phase == .saved)
        #expect(drafts.createDraft() == nil)
        #expect(!makeCreate().isRestoredDraft)
    }

    @Test func preselectedQuadrantOverridesOnlyTheStashedQuadrant() {
        let flow = makeCreate()
        flow.handle(.digit(1))
        flow.title = "Keep me"
        flow.abandon()
        let next = makeCreate(preselected: .notUrgentUnimportant)
        #expect(next.quadrant == .notUrgentUnimportant)
        #expect(next.title == "Keep me")
        #expect(next.phase == .editingTitle)
    }

    @Test(arguments: [QuickEntryFlow.Phase.pickingQuadrant, .editingTitle, .editingNote])
    func commandDeleteInCreateModeClearsTheDraftAndReturnsToPicker(phase: QuickEntryFlow.Phase) {
        let first = makeCreate()
        first.title = "T"
        first.note = "N"
        first.abandon()
        let flow = makeCreate()
        flow.focus(phase)
        #expect(flow.handle(.commandDelete))
        #expect(flow.title == "")
        #expect(flow.note == "")
        #expect(flow.phase == .pickingQuadrant)
        #expect(!flow.isRestoredDraft)
        #expect(!flow.isConfirmingDelete, "no confirmation in create mode")
        #expect(drafts.createDraft() == nil)
    }

    @Test func restoredHintNeedsText() {
        let first = makeCreate()
        first.title = "T"
        first.abandon()
        let flow = makeCreate()
        #expect(flow.showsRestoredHint)
        flow.title = ""
        #expect(!flow.showsRestoredHint)
    }

    @Test func freshCreateIsNotRestored() {
        let flow = makeCreate()
        #expect(!flow.isRestoredDraft)
        #expect(!flow.showsRestoredHint)
    }

    // MARK: edit mode

    func source(_ id: UUID = UUID()) -> QuickEntryDraft {
        QuickEntryDraft(todoID: id, title: "Original", note: "n", quadrant: .urgentImportant)
    }

    @Test func focusLossInEditModeStashesForThatTodo() {
        let id = UUID()
        let flow = makeEdit(source(id))
        flow.title = "Changed"
        flow.focus(.editingNote)
        flow.note = "new note"
        flow.abandon()

        let reopened = makeEdit(source(id))
        #expect(reopened.isRestoredDraft)
        #expect(reopened.title == "Changed")
        #expect(reopened.note == "new note")
        #expect(reopened.phase == .editingNote)
        #expect(reopened.todoID == id)

        let other = makeEdit(source())
        #expect(!other.isRestoredDraft)
        #expect(other.title == "Original")
        #expect(drafts.createDraft() == nil, "edit stashes never leak into Quick Add")
    }

    @Test func unchangedEditIsNotStashed() {
        let id = UUID()
        let flow = makeEdit(source(id))
        flow.abandon()
        #expect(drafts.editDraft(for: id) == nil)
    }

    @Test func escapeInEditModeDiscardsTheStash() {
        let id = UUID()
        let flow = makeEdit(source(id))
        flow.title = "Changed"
        flow.abandon()
        let reopened = makeEdit(source(id))
        reopened.handle(.escape)
        #expect(drafts.editDraft(for: id) == nil)
        #expect(makeEdit(source(id)).title == "Original")
    }

    @Test func savingOrDeletingAnEditClearsItsStash() {
        let id = UUID()
        let flow = makeEdit(source(id))
        flow.title = "Changed"
        flow.abandon()
        makeEdit(source(id)).handle(.commandEnter)
        #expect(drafts.editDraft(for: id) == nil)

        let again = makeEdit(source(id))
        again.title = "Changed again"
        again.abandon()
        let deleting = makeEdit(source(id))
        deleting.handle(.commandDelete)
        deleting.handle(.enter)
        #expect(deleting.phase == .deleted)
        #expect(drafts.editDraft(for: id) == nil)
    }

    @Test func commandDeleteInEditModeStillAsksToDelete() {
        let flow = makeEdit(source())
        flow.handle(.commandDelete)
        #expect(flow.isConfirmingDelete)
        #expect(flow.title == "Original")
    }

    // MARK: persistence

    @Test func userDefaultsDraftStoreRoundTrips() throws {
        let suite = "howy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let create = StashedDraft(quadrant: .urgentUnimportant, title: "T", note: "N", field: .note)
        let edit = StashedDraft(quadrant: .notUrgentImportant, title: "E", note: "", field: .quadrant)

        let store = UserDefaultsDraftStore(defaults: defaults)
        #expect(store.createDraft() == nil)
        store.setCreateDraft(create)
        store.setEditDraft(edit, for: id)

        let reloaded = UserDefaultsDraftStore(defaults: defaults) // e.g. after an app restart
        #expect(reloaded.createDraft() == create)
        #expect(reloaded.editDraft(for: id) == edit)
        #expect(reloaded.editDraft(for: UUID()) == nil)

        reloaded.setCreateDraft(nil)
        reloaded.setEditDraft(nil, for: id)
        #expect(UserDefaultsDraftStore(defaults: defaults).createDraft() == nil)
        #expect(UserDefaultsDraftStore(defaults: defaults).editDraft(for: id) == nil)
    }

    @Test func editStashesAreCapped() {
        let store = MemoryDraftStore()
        let ids = (0..<(MemoryDraftStore.maxEditDrafts + 3)).map { _ in UUID() }
        for id in ids {
            store.setEditDraft(StashedDraft(quadrant: .urgentImportant, title: "x", note: "", field: .title), for: id)
        }
        #expect(store.editDraft(for: ids[0]) == nil, "oldest dropped")
        #expect(store.editDraft(for: ids.last!) != nil)
    }

    @Test func corruptDefaultsAreIgnored() throws {
        let suite = "howy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("nope".utf8), forKey: UserDefaultsDraftStore.defaultKey)
        #expect(UserDefaultsDraftStore(defaults: defaults).createDraft() == nil)
    }
}
