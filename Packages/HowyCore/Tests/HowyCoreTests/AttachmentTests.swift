import Foundation
import Testing
@testable import HowyCore

@Suite struct AttachmentNamingTests {
    @Test func pastedImagesCountUpFromTheHighest() {
        #expect(AttachmentNaming.pastedName(extension: "png", existing: []) == "attachment-1.png")
        #expect(AttachmentNaming.pastedName(extension: "png", existing: ["attachment-1.png", "report.pdf"]) == "attachment-2.png")
        #expect(AttachmentNaming.pastedName(extension: "png", existing: ["attachment-3.png"]) == "attachment-4.png")
        #expect(AttachmentNaming.pastedName(extension: "jpg", existing: ["attachment-x.png"]) == "attachment-1.jpg")
    }

    @Test func clashingNamesGetANumberBeforeTheExtension() {
        #expect(AttachmentNaming.unique("report.pdf", existing: []) == "report.pdf")
        #expect(AttachmentNaming.unique("report.pdf", existing: ["Report.pdf"]) == "report 2.pdf")
        #expect(AttachmentNaming.unique("report.pdf", existing: ["report.pdf", "report 2.pdf"]) == "report 3.pdf")
        #expect(AttachmentNaming.unique("README", existing: ["README"]) == "README 2")
    }

    @Test func namesAreSingleFileNames() {
        #expect(AttachmentNaming.unique("a/b:c.txt", existing: []) == "a-b-c.txt")
        #expect(AttachmentNaming.unique(".hidden", existing: []) == "file.hidden")
    }

    @Test func imagesAreRecognisedByExtension() {
        #expect(TodoAttachment(name: "attachment-1.PNG").isImage)
        #expect(TodoAttachment(name: "photo.heic").isImage)
        #expect(!TodoAttachment(name: "report.pdf").isImage)
    }
}

@Suite struct AttachmentReferenceTests {
    @Test func imagesAndFilesFormatDifferently() {
        #expect(AttachmentReference.markdown(for: TodoAttachment(name: "attachment-1.png")) == "![attachment-1](attachment-1.png)")
        #expect(AttachmentReference.markdown(for: TodoAttachment(name: "report.pdf")) == "[report.pdf](report.pdf)")
        #expect(AttachmentReference.markdown(for: TodoAttachment(name: "Q4 plan (draft).pdf"))
            == "[Q4 plan (draft).pdf](Q4%20plan%20%28draft%29.pdf)")
    }

    @Test func referencesAreFoundByName() {
        let note = "See ![attachment-1](attachment-1.png)\nand [Q4 plan.pdf](Q4%20plan.pdf) and [web](https://x.io)"
        let all = AttachmentReference.matches(in: note).map(\.name)
        #expect(all == ["attachment-1.png", "Q4 plan.pdf", "https://x.io"])
        let ours = AttachmentReference.matches(in: note, names: ["Q4 plan.pdf"])
        #expect(ours.count == 1)
        #expect((note as NSString).substring(with: ours[0].range) == "[Q4 plan.pdf](Q4%20plan.pdf)")
    }

    @Test func caretLookupIncludesBothEnds() {
        let note = "ab ![x](x.png) cd"
        let names: Set = ["x.png"]
        #expect(AttachmentReference.name(at: 2, in: note, names: names) == nil)
        #expect(AttachmentReference.name(at: 3, in: note, names: names) == "x.png")
        #expect(AttachmentReference.name(at: 14, in: note, names: names) == "x.png")
        #expect(AttachmentReference.name(at: 15, in: note, names: names) == nil)
        #expect(AttachmentReference.name(at: 5, in: note, names: ["y.png"]) == nil)
    }

    @Test func removingAReferenceLineDropsTheLine() {
        #expect(AttachmentReference.removing(name: "x.png", from: "a\n![x](x.png)\nb") == "a\nb")
        #expect(AttachmentReference.removing(name: "x.png", from: "a\n![x](x.png)") == "a")
        #expect(AttachmentReference.removing(name: "x.png", from: "![x](x.png)") == "")
        #expect(AttachmentReference.removing(name: "x.png", from: "see ![x](x.png) here") == "see  here")
        #expect(AttachmentReference.removing(name: "x.png", from: "![x](x.png)\n![y](y.png)\n![x](x.png)") == "![y](y.png)")
        #expect(AttachmentReference.removing(name: "z.png", from: "![x](x.png)") == "![x](x.png)")
    }
}

@MainActor
@Suite struct AttachmentStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "howy-attachments-\(UUID().uuidString)", directoryHint: .isDirectory)
    var files: AttachmentStore { AttachmentStore(root: root) }

    func file(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = FileManager.default.temporaryDirectory.appending(path: "src-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    func contents(_ url: URL?) throws -> String? {
        try url.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
    }

    func makeStore() throws -> TodoStore {
        try TodoStore.inMemory(attachments: files)
    }

    @Test func stagedFilesBecomeTheTodosOnSave() throws {
        let store = try makeStore()
        let todo = UUID()
        let a = try files.stage(copying: file("A"), as: "a.txt")
        let b = try files.stage(data: Data("B".utf8), as: "attachment-1.png")
        #expect(try contents(store.attachmentURL(for: a, todoID: todo)) == "A")
        #expect(store.attachmentList(for: todo).isEmpty)

        try store.setAttachments([b, a], for: todo)
        #expect(store.attachmentList(for: todo) == [b, a])
        #expect(try contents(store.attachmentURL(for: a, todoID: todo)) == "A")
        #expect(files.url(for: a, todoID: nil) == nil) // no longer staged
    }

    @Test func savingWithoutAnAttachmentDeletesIt() throws {
        let store = try makeStore()
        let todo = UUID()
        let a = try files.stage(data: Data("A".utf8), as: "a.txt")
        let b = try files.stage(data: Data("B".utf8), as: "b.txt")
        try store.setAttachments([a, b], for: todo)
        try store.setAttachments([b], for: todo)
        #expect(store.attachmentList(for: todo) == [b])
        #expect(store.attachmentURL(for: a, todoID: todo) == nil)
        try store.setAttachments([], for: todo)
        #expect(store.attachmentList(for: todo).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: todo.uuidString).path(percentEncoded: false)))
    }

    @Test func missingFilesAreDroppedOnSave() throws {
        let store = try makeStore()
        let todo = UUID()
        let ghost = TodoAttachment(name: "gone.png")
        let a = try files.stage(data: Data("A".utf8), as: "a.txt")
        try store.setAttachments([ghost, a], for: todo)
        #expect(store.attachmentList(for: todo) == [a])
    }

    @Test func stagingKeepsOnlyWhatDraftsReferTo() throws {
        let keep = try files.stage(data: Data("K".utf8), as: "k.txt")
        let drop = try files.stage(data: Data("D".utf8), as: "d.txt")
        files.collectStaging(keeping: [keep.id])
        #expect(files.url(for: keep, todoID: nil) != nil)
        #expect(files.url(for: drop, todoID: nil) == nil)
    }

    @Test func discardingDeletesATodosAttachments() throws {
        let store = try makeStore()
        let todo = UUID()
        let a = try files.stage(data: Data("A".utf8), as: "a.txt")
        try store.setAttachments([a], for: todo)
        store.discardAttachments(for: todo)
        #expect(store.attachmentList(for: todo).isEmpty)
        #expect(store.attachmentURL(for: a, todoID: todo) == nil)
    }
}

@MainActor
@Suite struct TodoStoreAttachmentTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "howy-attachments-\(UUID().uuidString)", directoryHint: .isDirectory)
    let clock = FakeClock()
    let writes = TodoStoreTests.WriteCounter()
    let store: TodoStore

    init() throws {
        let clock = clock
        let writes = writes
        store = try TodoStore.inMemory(attachments: AttachmentStore(root: root), now: { clock.now }, didWrite: { writes.count += 1 })
    }

    @Test func snapshotsCountAttachmentsAndCommitsReloadWidgets() throws {
        let todo = try store.add(title: "T", quadrant: .urgentImportant)
        let files = try #require(store.attachments)
        let a = try files.stage(data: Data("A".utf8), as: "a.txt")
        let before = writes.count
        try store.setAttachments([a], for: todo.id)
        #expect(writes.count == before + 1)
        try store.setAttachments([a], for: todo.id)
        #expect(writes.count == before + 1) // unchanged: no reload
        #expect(try store.openSnapshots()[.urgentImportant]?.first?.attachmentCount == 1)
        #expect(store.attachmentList(for: todo.id) == [a])
    }

    @Test func completingKeepsFilesDeletingRemovesThem() throws {
        let todo = try store.add(title: "T", quadrant: .urgentImportant)
        let files = try #require(store.attachments)
        let a = try files.stage(data: Data("A".utf8), as: "a.txt")
        try store.setAttachments([a], for: todo.id)
        try store.complete(id: todo.id)
        try store.restore(id: todo.id)
        #expect(store.attachmentList(for: todo.id) == [a])
        try store.delete(id: todo.id)
        #expect(files.url(for: a, todoID: todo.id) == nil)
    }

    @Test func purgingRemovesFiles() throws {
        let todo = try store.add(title: "T", quadrant: .urgentImportant)
        let files = try #require(store.attachments)
        let a = try files.stage(data: Data("A".utf8), as: "a.txt")
        try store.setAttachments([a], for: todo.id)
        try store.complete(id: todo.id)
        clock.advance(by: ArchiveRetention.default.interval + 1)
        try store.purgeArchive()
        #expect(files.url(for: a, todoID: todo.id) == nil)
    }
}

@MainActor
@Suite struct QuickEntryAttachmentTests {
    let png = TodoAttachment(name: "attachment-1.png")
    let pdf = TodoAttachment(name: "report.pdf")

    func makeNoteFlow(drafts: MemoryDraftStore? = nil) -> QuickEntryFlow {
        let flow = QuickEntryFlow(mode: .create(.urgentImportant), lastUsed: MemoryLastQuadrantStore(), drafts: drafts)
        flow.handle(.enter)
        return flow
    }

    @Test func attachingKeepsTheListAndSavesIt() {
        let flow = makeNoteFlow()
        flow.attach(png)
        flow.attach(pdf)
        flow.title = "T"
        flow.save()
        #expect(flow.savedDraft?.attachments == [png, pdf])
    }

    @Test func optionEnterMovesIntoTheAttachmentsAndShiftTabBack() {
        let flow = makeNoteFlow()
        flow.attach(png)
        #expect(flow.handle(.optionEnter))
        #expect(flow.phase == .browsingAttachments)
        #expect(flow.selectedAttachment == png)
        #expect(flow.handle(.shiftTab))
        #expect(flow.phase == .editingNote)
        flow.focus(.editingTitle)
        flow.handle(.optionEnter)
        #expect(flow.phase == .browsingAttachments)
    }

    @Test func tabInTheNoteStaysText() {
        let flow = makeNoteFlow()
        #expect(!flow.handle(.tab))
        #expect(!flow.handle(.backspace))
        #expect(flow.phase == .editingNote)
    }

    @Test func arrowsSelectClampedAndKeysRequestOpening() {
        let flow = makeNoteFlow()
        flow.attach(png)
        flow.attach(pdf)
        flow.handle(.optionEnter)
        flow.handle(.left)
        #expect(flow.selectedAttachment == png)
        flow.handle(.right)
        #expect(flow.selectedAttachment == pdf)
        flow.handle(.space)
        #expect(flow.takeRequest() == .open(pdf, alternate: false))
        #expect(flow.takeRequest() == nil)
        flow.handle(.enter)
        #expect(flow.takeRequest() == .open(pdf, alternate: false))
        flow.handle(.optionEnter)
        #expect(flow.takeRequest() == .open(pdf, alternate: true))
        #expect(flow.handle(.other)) // swallowed
        #expect(flow.handle(.tab))
        #expect(flow.phase == .browsingAttachments)
    }

    @Test func vimKeysSelectLikeTheArrows() {
        let flow = makeNoteFlow()
        flow.attach(png)
        flow.attach(pdf)
        flow.handle(.optionEnter)
        flow.handle(.letter("h"))
        #expect(flow.selectedAttachment == png)
        flow.handle(.letter("l"))
        #expect(flow.selectedAttachment == pdf)
        #expect(flow.note.isEmpty) // not typed into the note
    }

    @Test func enterWithoutAttachmentsAsksForFiles() {
        let flow = makeNoteFlow()
        flow.handle(.optionEnter)
        #expect(flow.selectedAttachment == nil)
        #expect(flow.isAddSelected)
        flow.handle(.optionEnter)
        #expect(flow.takeRequest() == nil)
        flow.handle(.enter)
        #expect(flow.takeRequest() == .chooseFiles)
        flow.attach(png) // picked: selected right away
        #expect(flow.selectedAttachment == png)
        #expect(!flow.isAddSelected)
    }

    @Test func theAddButtonComesAfterTheAttachments() {
        let flow = makeNoteFlow()
        flow.attach(png)
        flow.handle(.optionEnter)
        flow.handle(.right)
        #expect(flow.isAddSelected)
        #expect(flow.selectedAttachment == nil)
        flow.handle(.right) // clamped
        #expect(flow.isAddSelected)
        flow.handle(.backspace) // nothing to remove
        #expect(flow.attachments == [png])
        flow.handle(.space)
        #expect(flow.takeRequest() == .chooseFiles)
        flow.attach(pdf) // picked: the first new file is selected
        #expect(flow.selectedAttachment == pdf)
        flow.handle(.right)
        flow.removeAttachment(id: png.id) // removed by mouse: Add stays selected
        #expect(flow.isAddSelected)
        flow.handle(.left)
        #expect(flow.selectedAttachment == pdf)
    }

    @Test func backspaceRemovesTheSelectedOneAndItsReferences() {
        let flow = makeNoteFlow()
        flow.attach(png)
        flow.note = "Error:\n" + AttachmentReference.markdown(for: png) + "\nmore"
        flow.attach(pdf)
        flow.handle(.optionEnter)
        flow.handle(.backspace)
        #expect(flow.attachments == [pdf])
        #expect(flow.note == "Error:\nmore")
        #expect(flow.selectedAttachment == pdf)
        flow.handle(.backspace)
        #expect(flow.attachments.isEmpty)
        #expect(flow.selectedAttachment == nil)
        #expect(flow.phase == .browsingAttachments)
    }

    @Test func deletingTheReferenceTextKeepsTheAttachment() {
        let flow = makeNoteFlow()
        flow.attach(png)
        flow.note = AttachmentReference.markdown(for: png)
        flow.note = ""
        #expect(flow.attachments == [png])
    }

    @Test func escInEditModeDiscardsAttachmentChanges() {
        let drafts = MemoryDraftStore()
        let id = UUID()
        let flow = QuickEntryFlow(
            mode: .edit(QuickEntryDraft(todoID: id, title: "T", note: "", quadrant: .urgentImportant, attachments: [png])),
            lastUsed: MemoryLastQuadrantStore(), drafts: drafts
        )
        flow.attach(pdf)
        flow.handle(.escape)
        #expect(flow.savedDraft == nil)
        #expect(drafts.editDraft(for: id) == nil)
        #expect(drafts.stashedAttachmentIDs().isEmpty)
    }

    @Test func abandonedDraftsCarryTheirAttachments() {
        let drafts = MemoryDraftStore()
        let flow = makeNoteFlow(drafts: drafts)
        flow.attach(png) // nothing typed: attachments alone make it worth keeping
        flow.abandon()
        #expect(drafts.stashedAttachmentIDs() == [png.id])

        let next = QuickEntryFlow(mode: .create(.urgentImportant), lastUsed: MemoryLastQuadrantStore(), drafts: drafts)
        #expect(next.attachments == [png])
        next.title = "T"
        next.save()
        #expect(drafts.stashedAttachmentIDs().isEmpty, "saving clears the stash")
    }

    @Test func anEditOnlyChangingAttachmentsIsStashed() {
        let drafts = MemoryDraftStore()
        let id = UUID()
        let flow = QuickEntryFlow(
            mode: .edit(QuickEntryDraft(todoID: id, title: "T", note: "", quadrant: .urgentImportant)),
            lastUsed: MemoryLastQuadrantStore(), drafts: drafts
        )
        flow.attach(png)
        flow.abandon()
        #expect(drafts.editDraft(for: id)?.attachments == [png])
    }

    @Test func oldDraftsWithoutAttachmentsStillDecode() throws {
        let json = #"{"quadrant":2,"title":"T","note":"N","field":"note"}"#
        let draft = try JSONDecoder().decode(StashedDraft.self, from: Data(json.utf8))
        #expect(draft.attachments.isEmpty)
        #expect(draft.title == "T")
    }

    @Test func keyMappingForAttachments() {
        #expect(QuickEntryKey(keyCode: 36, modifiers: .option, characters: "\r") == .optionEnter)
        #expect(QuickEntryKey(keyCode: 51, modifiers: [], characters: nil) == .backspace)
        #expect(QuickEntryKey(keyCode: 51, modifiers: .command, characters: nil) == .commandDelete)
    }

    @Test func imageReferencesAreHighlighted() {
        let spans = MarkdownHighlighter.spans(in: "![shot](shot.png)")
        #expect(spans.contains(.init(.syntax, NSRange(location: 0, length: 2))))
        #expect(spans.contains(.init(.link, NSRange(location: 2, length: 4))))
        #expect(spans.contains(.init(.syntax, NSRange(location: 6, length: 11))))
    }
}
