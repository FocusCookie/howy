import Foundation
import Testing
@testable import HowyCore

/// A page-title lookup that answers with a fixed title.
struct FakeTitleLookup: LinkTitleLookup {
    let answer: String?
    func title(for url: URL) async -> String? { answer }
}

/// The link dialog over the note (`QuickEntryFlow.linkDialog`).
@MainActor
@Suite struct LinkDialogTests {
    func makeFlow(note: String = "go now", lookup: (any LinkTitleLookup)? = nil) -> QuickEntryFlow {
        let flow = QuickEntryFlow(mode: .create(startingInTitle: true), lastUsed: MemoryLastQuadrantStore(), linkTitles: lookup)
        flow.title = "Trip"
        flow.note = note
        flow.handle(.enter) // into the note
        return flow
    }

    func noteAfterEdit(_ flow: QuickEntryFlow) -> String? {
        flow.pendingNoteEdit.map { (flow.note as NSString).replacingCharacters(in: $0.edit.range, with: $0.edit.replacement) }
    }

    // MARK: Adding

    @Test func aPastedURLAsksForATitleStartingWithTheDomain() {
        let flow = makeFlow()
        flow.beginAddingLink(url: "https://www.booking.com/h", replacing: NSRange(location: 3, length: 0))
        #expect(flow.linkDialog?.title == "booking.com")
        #expect(flow.linkDialog?.isEditing == false)
        #expect(flow.linkDialog?.isLookingUpTitle == false, "no lookup configured")
        #expect(flow.phase == .editingNote)
    }

    @Test func enterInsertsTheLinkForTheEditor() {
        let flow = makeFlow()
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 3, length: 0))
        flow.setLinkTitle("Docs")
        #expect(flow.handle(.enter))
        #expect(flow.linkDialog == nil)
        #expect(noteAfterEdit(flow) == "go [Docs](https://a.io)now")
        #expect(flow.pendingNoteEdit?.edit.selection == NSRange(location: 23, length: 0))
        let id = flow.pendingNoteEdit!.id
        flow.noteEditApplied(id: id)
        #expect(flow.pendingNoteEdit == nil)
    }

    @Test func aBlankTitleInsertsThePlainURL() {
        let flow = makeFlow()
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 3, length: 0))
        flow.setLinkTitle("")
        flow.handle(.enter)
        #expect(noteAfterEdit(flow) == "go https://a.ionow")
    }

    @Test func escapeCancelsThePasteAndKeepsThePanel() {
        let flow = makeFlow()
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 3, length: 0))
        #expect(flow.handle(.escape))
        #expect(flow.linkDialog == nil)
        #expect(flow.pendingNoteEdit == nil)
        #expect(flow.phase == .editingNote, "Esc closed only the dialog")
    }

    @Test func thePageTitleReplacesTheDomainWhenItArrives() async {
        let flow = makeFlow(lookup: FakeTitleLookup(answer: "Booking – Hotel"))
        flow.beginAddingLink(url: "https://booking.com/h", replacing: NSRange(location: 3, length: 0))
        #expect(flow.linkDialog?.isLookingUpTitle == true)
        #expect(flow.linkDialog?.title == "booking.com")
        await flow.titleLookupTask?.value
        #expect(flow.linkDialog?.title == "Booking – Hotel")
        #expect(flow.linkDialog?.isLookingUpTitle == false)
    }

    @Test func aFailedLookupKeepsTheDomain() async {
        let flow = makeFlow(lookup: FakeTitleLookup(answer: nil))
        flow.beginAddingLink(url: "https://booking.com/h", replacing: NSRange(location: 3, length: 0))
        await flow.titleLookupTask?.value
        #expect(flow.linkDialog?.title == "booking.com")
        #expect(flow.linkDialog?.isLookingUpTitle == false)
    }

    @Test func typingBeforeTheLookupArrivesWins() async {
        let flow = makeFlow(lookup: FakeTitleLookup(answer: "Page"))
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 3, length: 0))
        flow.setLinkTitle("Mine")
        await flow.titleLookupTask?.value
        #expect(flow.linkDialog?.title == "Mine")
    }

    @Test func otherKeysTypeIntoTheField() {
        let flow = makeFlow()
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 3, length: 0))
        #expect(!flow.handle(.letter("a")))
        #expect(!flow.handle(.other))
        #expect(!flow.handle(.backspace))
        #expect(!flow.handle(.commandDelete), "⌘⌫ deletes to the line start in the field")
        #expect(flow.handle(.shiftTab), "doesn't leave the note for the title")
        #expect(flow.phase == .editingNote)
        #expect(flow.handle(.optionEnter))
        #expect(flow.phase == .editingNote, "doesn't go to the attachments")
        #expect(flow.linkDialog != nil)
    }

    @Test func commandEnterInsertsTheLinkInsteadOfSaving() {
        let flow = makeFlow()
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 3, length: 0))
        flow.handle(.commandEnter)
        #expect(flow.phase == .editingNote)
        #expect(flow.pendingNoteEdit != nil)
    }

    @Test func onlyFromTheNote() {
        let flow = QuickEntryFlow(mode: .create(startingInTitle: true), lastUsed: MemoryLastQuadrantStore())
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 0, length: 0))
        #expect(flow.linkDialog == nil)
    }

    @Test func aNoteChangedMeanwhileGetsNoEdit() {
        let flow = makeFlow()
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 3, length: 0))
        flow.note = "something else"
        flow.handle(.enter)
        #expect(flow.pendingNoteEdit == nil)
    }

    @Test func savingClosesTheDialog() {
        let flow = makeFlow()
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 3, length: 0))
        flow.save()
        #expect(flow.phase == .saved)
        #expect(flow.linkDialog == nil)
    }

    // MARK: Editing

    @Test func editingShowsTitleAndURLAndTabSwitchesFields() {
        let flow = makeFlow(note: "x [Docs](https://a.io) y")
        flow.beginEditingLink(NoteLinks.links(in: flow.note)[0])
        #expect(flow.linkDialog?.title == "Docs")
        #expect(flow.linkDialog?.url == "https://a.io")
        #expect(flow.linkDialog?.field == .title)
        flow.handle(.tab)
        #expect(flow.linkDialog?.field == .url)
        flow.handle(.shiftTab)
        #expect(flow.linkDialog?.field == .title)
    }

    @Test func savingAnEditReplacesTheLink() {
        let flow = makeFlow(note: "x [Docs](https://a.io) y")
        flow.beginEditingLink(NoteLinks.links(in: flow.note)[0])
        flow.setLinkTitle("API")
        flow.setLinkURL("https://b.io")
        flow.handle(.enter)
        #expect(noteAfterEdit(flow) == "x [API](https://b.io) y")
    }

    @Test func commandDeleteOrABlankURLRemovesTheLinkButKeepsItsTitle() {
        let flow = makeFlow(note: "x [Docs](https://a.io) y")
        flow.beginEditingLink(NoteLinks.links(in: flow.note)[0])
        flow.handle(.commandDelete)
        #expect(noteAfterEdit(flow) == "x Docs y")

        let other = makeFlow(note: "x [Docs](https://a.io) y")
        other.beginEditingLink(NoteLinks.links(in: other.note)[0])
        other.setLinkURL("  ")
        other.handle(.enter)
        #expect(noteAfterEdit(other) == "x Docs y")
    }

    @Test func aBareURLStartsWithAnEmptyTitle() {
        let flow = makeFlow(note: "x https://a.io y")
        flow.beginEditingLink(NoteLinks.links(in: flow.note)[0])
        #expect(flow.linkDialog?.title == "")
        flow.setLinkTitle("A")
        flow.handle(.enter)
        #expect(noteAfterEdit(flow) == "x [A](https://a.io) y")
    }

    @Test func escapeLeavesTheLinkAsItWas() {
        let flow = makeFlow(note: "x [Docs](https://a.io) y")
        flow.beginEditingLink(NoteLinks.links(in: flow.note)[0])
        flow.setLinkTitle("Changed")
        flow.handle(.escape)
        #expect(flow.pendingNoteEdit == nil)
        #expect(flow.phase == .editingNote)
    }
}
