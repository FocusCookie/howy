import Foundation
import Testing
@testable import HowyCore

/// Attachment chips in the editor: the attachment dialog (`QuickEntryFlow.attachmentDialog`),
/// staging a pasted file only on confirm, and **I** in the attachment strip with the remembered
/// note selection (the ghost caret).
@MainActor
@Suite struct AttachmentDialogTests {
    let pdf = TodoAttachment(name: "report.pdf")
    let png = TodoAttachment(name: "shot.png")

    func makeFlow(note: String = "go now", attachments: [TodoAttachment] = []) -> QuickEntryFlow {
        let draft = QuickEntryDraft(todoID: UUID(), title: "Trip", note: note, quadrant: .urgentImportant, attachments: attachments)
        let flow = QuickEntryFlow(mode: .edit(draft), lastUsed: MemoryLastQuadrantStore())
        flow.handle(.enter) // into the note
        return flow
    }

    /// The note with the pending edit applied, `|` at its caret.
    func noteAfterEdit(_ flow: QuickEntryFlow) -> String? {
        flow.pendingNoteEdit.map {
            let text = (flow.note as NSString).replacingCharacters(in: $0.edit.range, with: $0.edit.replacement)
            return (text as NSString).replacingCharacters(in: $0.edit.selection, with: "|")
        }
    }

    /// The editor applied the pending edit (and syncs the note back).
    func applyEdit(_ flow: QuickEntryFlow) {
        guard let pending = flow.pendingNoteEdit else { return }
        flow.note = (flow.note as NSString).replacingCharacters(in: pending.edit.range, with: pending.edit.replacement)
        flow.noteSelectionChanged(pending.edit.selection)
        flow.noteEditApplied(id: pending.id)
    }

    // MARK: Pasting or dropping one file

    @Test func aPastedFileAsksForATitleWithoutStagingIt() {
        let flow = makeFlow()
        let token = UUID()
        flow.beginAddingAttachment(fileName: "report.pdf", token: token, replacing: NSRange(location: 2, length: 0))
        let dialog = flow.attachmentDialog
        #expect(dialog?.isEditing == false)
        #expect(dialog?.fileName == "report.pdf")
        #expect(dialog?.isImage == false)
        #expect(dialog?.title == "report")
        #expect(dialog?.placeholder == "report")
        #expect(flow.attachments.isEmpty, "nothing is attached before ↩")
        #expect(flow.request == nil)
    }

    @Test func enterAsksToStageAndTheStagedFileGoesInline() {
        let flow = makeFlow()
        let token = UUID()
        flow.beginAddingAttachment(fileName: "report.pdf", token: token, replacing: NSRange(location: 2, length: 0))
        flow.setAttachmentTitle("Q4")
        #expect(flow.handle(.enter))
        #expect(flow.attachmentDialog == nil)
        #expect(flow.takeRequest() == .stage(token: token))
        #expect(flow.pendingNoteEdit == nil, "only once the file is staged")
        flow.attachStaged(pdf, token: token)
        #expect(flow.attachments == [pdf])
        #expect(noteAfterEdit(flow) == "go [Q4](report.pdf)| now")
        #expect(flow.pendingNoteEdit?.actionName == "Add Attachment")
    }

    @Test func theStagedNameCountsNotTheOfferedOne() {
        // "report.pdf" was taken, so the store staged "report 2.pdf"; a blank title falls back to it.
        let flow = makeFlow(note: "", attachments: [pdf])
        let token = UUID()
        flow.beginAddingAttachment(fileName: "report.pdf", token: token, replacing: NSRange(location: 0, length: 0))
        flow.setAttachmentTitle("")
        flow.confirmAttachment()
        flow.attachStaged(TodoAttachment(name: "report 2.pdf"), token: token)
        #expect(noteAfterEdit(flow) == "[report 2](report%202.pdf)|")
    }

    @Test func escapeCancelsAndNothingIsStaged() {
        let flow = makeFlow()
        let token = UUID()
        flow.beginAddingAttachment(fileName: "report.pdf", token: token, replacing: NSRange(location: 2, length: 0))
        #expect(flow.handle(.escape))
        #expect(flow.attachmentDialog == nil)
        #expect(flow.request == nil)
        #expect(flow.attachments.isEmpty)
        #expect(flow.phase == .editingNote, "Esc closed only the dialog")
        flow.attachStaged(pdf, token: token) // a late answer for a cancelled dialog
        #expect(flow.attachments.isEmpty)
    }

    @Test func aFailedStagingInsertsNothing() {
        let flow = makeFlow()
        let token = UUID()
        flow.beginAddingAttachment(fileName: "report.pdf", token: token, replacing: NSRange(location: 2, length: 0))
        flow.confirmAttachment()
        flow.stagingFailed(token: token)
        flow.attachStaged(pdf, token: token)
        #expect(flow.attachments.isEmpty)
        #expect(flow.pendingNoteEdit == nil)
    }

    @Test func aScreenshotStartsEmptyWithAPlaceholder() {
        let flow = makeFlow(note: "")
        let token = UUID()
        flow.beginAddingAttachment(fileName: "attachment-1.png", token: token, isScreenshot: true, replacing: NSRange(location: 0, length: 0))
        #expect(flow.attachmentDialog?.title == "")
        #expect(flow.attachmentDialog?.placeholder == "Screenshot")
        #expect(flow.attachmentDialog?.isImage == true)
        flow.handle(.enter)
        flow.attachStaged(TodoAttachment(name: "attachment-1.png"), token: token)
        #expect(noteAfterEdit(flow) == "![attachment-1](attachment-1.png)|")
    }

    @Test func aChangedNoteGetsNoInsertButKeepsTheFile() {
        let flow = makeFlow()
        let token = UUID()
        flow.beginAddingAttachment(fileName: "report.pdf", token: token, replacing: NSRange(location: 2, length: 0))
        flow.confirmAttachment()
        flow.note = "changed"
        flow.attachStaged(pdf, token: token)
        #expect(flow.attachments == [pdf])
        #expect(flow.pendingNoteEdit == nil)
    }

    @Test func anAttachedFileDroppedFromTheStripInsertsRightAway() {
        let flow = makeFlow(attachments: [png])
        flow.beginAddingAttachment(png, replacing: NSRange(location: 6, length: 0))
        #expect(flow.attachmentDialog?.title == "shot")
        #expect(flow.attachmentDialog?.isImage == true)
        flow.handle(.enter)
        #expect(flow.request == nil, "nothing to stage")
        #expect(noteAfterEdit(flow) == "go now ![shot](shot.png)|")
        #expect(flow.attachments == [png])
    }

    @Test func theDialogOpensOnlyInTheNoteWithoutAnotherDialog() {
        let flow = makeFlow()
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 0, length: 0))
        flow.beginAddingAttachment(fileName: "a.pdf", token: UUID(), replacing: NSRange(location: 0, length: 0))
        #expect(flow.attachmentDialog == nil)
        flow.cancelLink()
        flow.beginAddingAttachment(fileName: "a.pdf", token: UUID(), replacing: NSRange(location: 0, length: 0))
        flow.beginAddingLink(url: "https://a.io", replacing: NSRange(location: 0, length: 0))
        flow.beginDueDate()
        #expect(flow.linkDialog == nil && flow.dueDialog == nil)
        #expect(flow.hasDialog)
    }

    @Test func theDialogsKeysComeFirst() {
        let flow = makeFlow()
        flow.beginAddingAttachment(fileName: "a.pdf", token: UUID(), replacing: NSRange(location: 0, length: 0))
        #expect(!flow.handle(.letter("x")), "typing goes into the title field")
        #expect(!flow.handle(.commandDelete), "the field deletes to the line start when adding")
        #expect(flow.handle(.commandDone))
        #expect(flow.handle(.optionEnter))
        #expect(flow.handle(.tab))
        #expect(flow.phase == .editingNote && flow.attachmentDialog != nil)
    }

    // MARK: Editing a chip (⌘E)

    func chip(_ flow: QuickEntryFlow, _ index: Int = 0) -> AttachmentChip {
        NoteChips.attachments(in: flow.note, attachmentNames: Set(flow.attachmentNames))[index]
    }

    @Test func editingChangesOnlyTheTitle() {
        let flow = makeFlow(note: "a [Report](report.pdf) b", attachments: [pdf])
        flow.beginEditingAttachment(chip(flow))
        #expect(flow.attachmentDialog?.isEditing == true)
        #expect(flow.attachmentDialog?.title == "Report")
        #expect(flow.attachmentDialog?.fileName == "report.pdf")
        #expect(flow.attachmentDialog?.placeholder == "report")
        flow.setAttachmentTitle("Q4 numbers")
        flow.handle(.commandEnter)
        #expect(noteAfterEdit(flow) == "a [Q4 numbers](report.pdf)| b")
        #expect(flow.pendingNoteEdit?.actionName == "Edit Attachment")
    }

    @Test func removingOneOfSeveralReferencesDoesNotAsk() {
        let flow = makeFlow(note: "[A](report.pdf) and [B](report.pdf)", attachments: [pdf])
        flow.beginEditingAttachment(chip(flow, 1))
        #expect(flow.handle(.commandDelete))
        #expect(flow.attachmentDialog == nil)
        #expect(noteAfterEdit(flow) == "[A](report.pdf) and|")
        #expect(flow.attachments == [pdf])
    }

    @Test func removingTheLastReferenceAsksAboutTheAttachment() {
        let flow = makeFlow(note: "a [Report](report.pdf) b", attachments: [pdf])
        flow.beginEditingAttachment(chip(flow))
        flow.handle(.commandDelete)
        #expect(flow.attachmentDialog?.isAskingToDeleteAttachment == true)
        #expect(flow.pendingNoteEdit == nil)
        #expect(flow.handle(.letter("x")), "nothing to type into while asking")
        #expect(flow.attachmentDialog?.title == "Report")
    }

    @Test func yesRemovesTheReferenceAndTheAttachment() {
        for yes in [QuickEntryKey.enter, .letter("y")] {
            let flow = makeFlow(note: "a [Report](report.pdf) b", attachments: [pdf, png])
            flow.beginEditingAttachment(chip(flow))
            flow.handle(.commandDelete)
            flow.handle(yes)
            #expect(flow.attachmentDialog == nil)
            #expect(flow.attachments == [png])
            #expect(noteAfterEdit(flow) == "a| b", "the note changes through the editor, as one undo step")
        }
    }

    @Test func noRemovesOnlyTheReference() {
        let flow = makeFlow(note: "a [Report](report.pdf) b", attachments: [pdf])
        flow.beginEditingAttachment(chip(flow))
        flow.handle(.commandDelete)
        flow.handle(.letter("n"))
        #expect(flow.attachmentDialog == nil)
        #expect(flow.attachments == [pdf])
        #expect(noteAfterEdit(flow) == "a| b")
    }

    @Test func escapeWhileAskingGoesBackToTheTitle() {
        let flow = makeFlow(note: "a [Report](report.pdf) b", attachments: [pdf])
        flow.beginEditingAttachment(chip(flow))
        flow.handle(.commandDelete)
        flow.handle(.escape)
        #expect(flow.attachmentDialog?.isAskingToDeleteAttachment == false)
        flow.handle(.escape)
        #expect(flow.attachmentDialog == nil)
        #expect(flow.pendingNoteEdit == nil)
        #expect(flow.attachments == [pdf])
    }

    @Test func theButtonsAnswerToo() {
        let flow = makeFlow(note: "[Report](report.pdf)", attachments: [pdf])
        flow.beginEditingAttachment(chip(flow))
        flow.removeAttachmentReference()
        flow.answerDeleteAttachment(true)
        #expect(flow.attachments.isEmpty)
        #expect(noteAfterEdit(flow) == "|")
    }

    // MARK: I in the strip

    @Test func theNoteRemembersItsSelectionForTheGhostCaret() {
        let flow = makeFlow(attachments: [pdf])
        flow.noteSelectionChanged(NSRange(location: 2, length: 0))
        #expect(flow.ghostNoteSelection == nil, "no ghost while the note has focus")
        flow.handle(.optionEnter)
        #expect(flow.ghostNoteSelection == NSRange(location: 2, length: 0))
        flow.noteSelectionChanged(NSRange(location: 0, length: 2))
        #expect(flow.ghostNoteSelection == NSRange(location: 0, length: 2))
    }

    @Test func withoutARememberedCaretTheGhostIsAtTheEnd() {
        let flow = makeFlow(attachments: [pdf])
        flow.handle(.optionEnter)
        #expect(flow.ghostNoteSelection == NSRange(location: 6, length: 0))
    }

    @Test func aRememberedSelectionPastTheEndIsClamped() {
        let flow = makeFlow(attachments: [pdf])
        flow.noteSelectionChanged(NSRange(location: 4, length: 10))
        flow.handle(.optionEnter)
        #expect(flow.ghostNoteSelection == NSRange(location: 4, length: 2))
    }

    @Test func iOpensTheDialogAtTheRememberedCaret() {
        let flow = makeFlow(attachments: [pdf])
        flow.noteSelectionChanged(NSRange(location: 2, length: 0))
        flow.handle(.optionEnter)
        #expect(flow.handle(.letter(QuickEntryFlow.insertKey)))
        #expect(flow.phase == .editingNote)
        #expect(flow.attachmentDialog?.title == "report")
        flow.handle(.enter)
        #expect(noteAfterEdit(flow) == "go [report](report.pdf)| now")
        applyEdit(flow)
        #expect(flow.note == "go [report](report.pdf) now")
        #expect(flow.rememberedNoteSelection == NSRange(location: 23, length: 0))
    }

    @Test func iWithoutARememberedCaretInsertsAtTheEnd() {
        let flow = makeFlow(attachments: [pdf])
        flow.handle(.optionEnter)
        flow.handle(.letter("i"))
        flow.handle(.enter)
        #expect(noteAfterEdit(flow) == "go now [report](report.pdf)|")
    }

    @Test func iWithAOneLineSelectionUsesItAsTheTitle() {
        let flow = makeFlow(attachments: [pdf])
        flow.noteSelectionChanged(NSRange(location: 3, length: 3))
        flow.handle(.optionEnter)
        flow.handle(.letter("i"))
        #expect(flow.attachmentDialog == nil, "no dialog")
        #expect(flow.phase == .editingNote)
        #expect(noteAfterEdit(flow) == "go [now](report.pdf)|")
    }

    @Test func iWithAMultiLineSelectionInsertsAfterIt() {
        let flow = makeFlow(note: "a\nb", attachments: [pdf])
        flow.noteSelectionChanged(NSRange(location: 0, length: 3))
        flow.handle(.optionEnter)
        flow.handle(.letter("i"))
        flow.handle(.enter)
        #expect(noteAfterEdit(flow) == "a\nb [report](report.pdf)|")
    }

    @Test func iNeverLandsInsideAChip() {
        let flow = makeFlow(note: "[Docs](https://a.io)", attachments: [pdf])
        flow.noteSelectionChanged(NSRange(location: 3, length: 0))
        flow.handle(.optionEnter)
        flow.handle(.letter("i"))
        flow.handle(.enter)
        #expect(noteAfterEdit(flow) == "[Docs](https://a.io) [report](report.pdf)|")
    }

    @Test func escapeAfterIInsertsNothingAndKeepsTheAttachment() {
        let flow = makeFlow(attachments: [pdf])
        flow.handle(.optionEnter)
        flow.handle(.letter("i"))
        flow.handle(.escape)
        #expect(flow.attachmentDialog == nil)
        #expect(flow.pendingNoteEdit == nil)
        #expect(flow.attachments == [pdf])
        #expect(flow.phase == .editingNote)
    }

    @Test func iOnTheAddButtonDoesNothing() {
        let flow = makeFlow()
        flow.handle(.optionEnter)
        #expect(flow.isAddSelected)
        flow.handle(.letter("i"))
        #expect(flow.phase == .browsingAttachments)
        #expect(flow.attachmentDialog == nil)
    }

    // MARK: Closing

    @Test func savingClosesTheDialog() {
        let flow = makeFlow()
        flow.beginAddingAttachment(fileName: "a.pdf", token: UUID(), replacing: NSRange(location: 0, length: 0))
        flow.save()
        #expect(flow.attachmentDialog == nil)
        #expect(flow.phase == .saved)
    }
}
