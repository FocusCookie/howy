import Foundation
import Testing
@testable import HowyCore

/// Link chips and attachment chips together (`NoteChips`) and the attachment reference edits
/// (`NoteAttachments`). Text with a selection is written inline: `|` is a caret, `‹…›` a selection.
@Suite struct NoteChipsTests {
    func unmark(_ marked: String) -> (text: String, selection: NSRange) {
        let ns = marked as NSString
        let caret = ns.range(of: "|")
        if caret.location != NSNotFound {
            return (ns.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
        }
        let open = ns.range(of: "‹")
        let close = ns.range(of: "›")
        let text = marked.replacingOccurrences(of: "‹", with: "").replacingOccurrences(of: "›", with: "")
        return (text, NSRange(location: open.location, length: close.location - open.location - 1))
    }

    func mark(_ text: String, _ selection: NSRange) -> String {
        let ns = NSMutableString(string: text)
        if selection.length == 0 {
            ns.insert("|", at: selection.location)
        } else {
            ns.insert("›", at: NSMaxRange(selection))
            ns.insert("‹", at: selection.location)
        }
        return ns as String
    }

    func apply(_ edit: NoteLinks.Edit, to text: String) -> String {
        mark((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    let names: Set<String> = ["shot.png", "report.pdf", "Q4 plan.pdf"]
    let image = "![Shot](shot.png)" // 17 characters
    let file = "[Report](report.pdf)" // 20 characters
    let pdf = TodoAttachment(name: "report.pdf")
    let png = TodoAttachment(name: "shot.png")

    func snap(from: String, to: String) -> String {
        let (text, old) = unmark(from)
        let (_, proposed) = unmark(to)
        return mark(text, NoteChips.snap(proposed, from: old, in: text, attachmentNames: names))
    }

    // MARK: Finding chips

    @Test func attachmentReferencesAreChipsWithTheirKind() {
        let text = "a \(image) b \(file) c [Docs](https://a.io)"
        let chips = NoteChips.chips(in: text, attachmentNames: names)
        #expect(chips.count == 3)
        #expect(chips[0] == .attachment(AttachmentChip(range: NSRange(location: 2, length: 17), title: "Shot", name: "shot.png", isImage: true)))
        #expect(chips[1] == .attachment(AttachmentChip(range: NSRange(location: 22, length: 20), title: "Report", name: "report.pdf", isImage: false)))
        #expect(chips[2].link?.url == "https://a.io")
        #expect(chips[0].attachment?.kind == .image && chips[1].attachment?.kind == .file)
        #expect(chips[0].titleRange == NSRange(location: 4, length: 4))
        #expect(chips[1].titleRange == NSRange(location: 23, length: 6))
    }

    @Test func aPercentEncodedTargetNamesTheAttachment() {
        let chips = NoteChips.attachments(in: "[Plan](Q4%20plan.pdf)", attachmentNames: names)
        #expect(chips.map(\.name) == ["Q4 plan.pdf"])
    }

    @Test func referencesToUnknownFilesStayAsBefore() {
        // A link to a name that isn't attached is a link chip; an unknown image is no chip.
        let chips = NoteChips.chips(in: "[Old](old.pdf) ![Gone](gone.png)", attachmentNames: names)
        #expect(chips.count == 1)
        #expect(chips[0].link?.url == "old.pdf")
    }

    @Test func referencesInCodeAreNoChips() {
        #expect(NoteChips.chips(in: "`\(image)`\n```\n\(file)\n```", attachmentNames: names).isEmpty)
    }

    @Test func withoutNamesTheChipsAreTheLinkChips() {
        let text = "\(image) \(file) https://b.io"
        #expect(NoteChips.chips(in: text, attachmentNames: []).compactMap(\.link) == NoteLinks.links(in: text).filter(\.isChip))
    }

    @Test func theChipAtTheCaretPrefersTheOneJustPassed() {
        let text = "\(image)\(file)"
        let chips = NoteChips.chips(in: text, attachmentNames: names)
        #expect(NoteChips.chip(at: NSRange(location: 17, length: 0), in: chips)?.attachment?.name == "shot.png")
        #expect(NoteChips.chip(at: NSRange(location: 18, length: 0), in: chips)?.attachment?.name == "report.pdf")
        #expect(NoteChips.chip(at: NSRange(location: 37, length: 0), in: chips)?.attachment?.name == "report.pdf")
        #expect(NoteChips.chip(at: NSRange(location: 0, length: 0), in: NoteChips.chips(in: "x \(file)", attachmentNames: names)) == nil)
    }

    // MARK: One character

    @Test func theCaretStepsOverAnAttachmentChip() {
        #expect(snap(from: "a|\(image) b", to: "a!|[Shot](shot.png) b") == "a\(image)| b")
        #expect(snap(from: "a\(image)| b", to: "a![Shot](shot.png|) b") == "a|\(image) b")
        #expect(snap(from: "a|\(file)", to: "a[|Report](report.pdf)") == "a\(file)|")
    }

    @Test func aSelectionGrowsByWholeAttachmentChips() {
        #expect(snap(from: "a|\(file)", to: "a‹[Rep›ort](report.pdf)") == "a‹\(file)›")
    }

    @Test func backspaceAfterAnAttachmentChipSelectsIt() {
        let (text, caret) = unmark("x \(image)| y")
        #expect(NoteChips.deleteBackward(in: text, selection: caret, attachmentNames: names) == NSRange(location: 2, length: 17))
        #expect(NoteChips.deleteBackward(in: text, selection: NSRange(location: 1, length: 0), attachmentNames: names) == nil)
    }

    @Test func forwardDeleteBeforeAnAttachmentChipSelectsIt() {
        let (text, caret) = unmark("x |\(file) y")
        #expect(NoteChips.deleteForward(in: text, selection: caret, attachmentNames: names) == NSRange(location: 2, length: 20))
    }

    @Test func anEditCuttingIntoAnAttachmentChipTakesItWhole() {
        let text = "ab \(file) cd"
        #expect(NoteChips.widen(NSRange(location: 1, length: 5), in: text, attachmentNames: names) == NSRange(location: 1, length: 22))
        #expect(NoteChips.widen(NSRange(location: 6, length: 0), in: text, attachmentNames: names) == NSRange(location: 3, length: 20))
        #expect(NoteChips.widen(NSRange(location: 0, length: 2), in: text, attachmentNames: names) == NSRange(location: 0, length: 2))
    }

    @Test func linkChipsKeepTheirRules() {
        let link = "[Docs](https://a.io/x)"
        let (text, caret) = unmark("go \(link)|")
        #expect(NoteChips.deleteBackward(in: text, selection: caret, attachmentNames: names) == NSRange(location: 3, length: 22))
        #expect(NoteLinks.deleteBackward(in: text, selection: caret) == NSRange(location: 3, length: 22))
    }

    // MARK: Default title and Markdown

    @Test func theDefaultTitleIsTheNameWithoutItsExtension() {
        #expect(NoteAttachments.defaultTitle(for: "report.pdf") == "report")
        #expect(NoteAttachments.defaultTitle(for: "archive.tar.gz") == "archive.tar")
        #expect(NoteAttachments.defaultTitle(for: "README") == "README")
        #expect(NoteAttachments.defaultTitle(for: ".hidden") == ".hidden")
    }

    @Test func markdownByKindWithACleanTitle() {
        #expect(NoteAttachments.markdown(for: png, title: "Shot") == image)
        #expect(NoteAttachments.markdown(for: pdf, title: " Report ") == file)
        #expect(NoteAttachments.markdown(for: pdf, title: "a [b]\nc") == "[a (b) c](report.pdf)")
        #expect(NoteAttachments.markdown(for: TodoAttachment(name: "Q4 plan.pdf"), title: "Plan") == "[Plan](Q4%20plan.pdf)")
    }

    @Test func aBlankTitleFallsBackToTheDefault() {
        #expect(NoteAttachments.markdown(for: pdf, title: "  ") == "[report](report.pdf)")
        #expect(NoteAttachments.markdown(for: png, title: nil) == "![shot](shot.png)")
    }

    // MARK: Inserting

    @Test func insertsInlineAtTheCaretWithASpaceAfterAWord() {
        let (text, caret) = unmark("see|")
        let edit = NoteAttachments.insert(pdf, title: "Report", replacing: caret, in: text)
        #expect(apply(edit, to: text) == "see \(file)|")
    }

    @Test func noSpaceAfterWhitespaceOrAtTheStart() {
        for marked in ["see |", "|", "line\n|"] {
            let (text, caret) = unmark(marked)
            let edit = NoteAttachments.insert(pdf, title: "Report", replacing: caret, in: text)
            #expect(apply(edit, to: text) == marked.replacingOccurrences(of: "|", with: "\(file)|"))
        }
    }

    @Test func insertingReplacesTheSelection() {
        let (text, selection) = unmark("a ‹xx› b")
        #expect(apply(NoteAttachments.insert(pdf, title: "Report", replacing: selection, in: text), to: text) == "a \(file)| b")
    }

    @Test func severalFilesGoOnOneLineSeparatedBySpaces() {
        let (text, caret) = unmark("files:| end")
        let edit = NoteAttachments.insert([pdf, png], replacing: caret, in: text)
        #expect(apply(edit, to: text) == "files: [report](report.pdf) ![shot](shot.png)| end")
    }

    @Test func aOneLineSelectionBecomesTheTitle() {
        let (text, selection) = unmark("see ‹the report› now")
        let edit = NoteAttachments.insert(pdf, titledBySelection: selection, in: text, attachmentNames: names)
        #expect(edit.map { apply($0, to: text) } == "see [the report](report.pdf)| now")
    }

    @Test func noTitleFromAnEmptyBlankMultiLineOrChipSelection() {
        for marked in ["see| now", "a‹  ›b", "a‹b\nc›d", "a ‹x \(file)›"] {
            let (text, selection) = unmark(marked)
            #expect(NoteAttachments.insert(pdf, titledBySelection: selection, in: text, attachmentNames: names) == nil, "\(marked)")
        }
    }

    // MARK: Editing and removing

    @Test func retitlingChangesOnlyTheTitle() {
        let text = "a \(file) b"
        let chip = NoteChips.attachments(in: text, attachmentNames: names)[0]
        #expect(apply(NoteAttachments.retitle(chip, title: "Q4"), to: text) == "a [Q4](report.pdf)| b")
        #expect(apply(NoteAttachments.retitle(chip, title: ""), to: text) == "a [report](report.pdf)| b")
        let imageChip = NoteChips.attachments(in: image, attachmentNames: names)[0]
        #expect(apply(NoteAttachments.retitle(imageChip, title: "New"), to: image) == "![New](shot.png)|")
    }

    @Test func retitlingKeepsTheReferenceKindEvenForAnOddName() {
        // `[x](shot.png)` stays a link-style reference: only the title changes.
        let text = "[x](shot.png)"
        let chip = NoteChips.attachments(in: text, attachmentNames: names)[0]
        #expect(chip.kind == .file)
        #expect(apply(NoteAttachments.retitle(chip, title: "y"), to: text) == "[y](shot.png)|")
    }

    @Test func removingTakesTheChipAndOneSpareSpace() {
        let cases = [
            ("a \(file) b", "a| b"),
            ("a \(file)", "a|"),
            ("\(file) b", "|b"),
            ("a\(file)b", "a|b"),
            ("x\n\(file)\ny", "x\n|\ny"),
        ]
        for (text, expected) in cases {
            let chip = NoteChips.attachments(in: text, attachmentNames: names)[0]
            #expect(apply(NoteAttachments.remove(chip, in: text), to: text) == expected, "\(text)")
        }
    }

    @Test func theLastReferenceOfAnAttachment() {
        let text = "\(file) and [Again](report.pdf) and \(image)"
        let chips = NoteChips.attachments(in: text, attachmentNames: names)
        #expect(!NoteAttachments.isLastReference(chips[0], in: text, attachmentNames: names))
        #expect(NoteAttachments.isLastReference(chips[2], in: text, attachmentNames: names))
    }
}
