import Foundation
import Testing
@testable import HowyCore

/// Text with a selection is written inline: `|` is a caret, `‹…›` a selected range.
@Suite struct NoteLinksTests {
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

    /// Moves from `from` (marked) to the proposed selection (marked) and returns the snapped one.
    func snap(from: String, to: String) -> String {
        let (text, old) = unmark(from)
        let (_, proposed) = unmark(to)
        return mark(text, NoteLinks.snap(proposed, from: old, in: text))
    }

    let chip = "[Docs](https://a.io/x)" // 22 characters

    // MARK: Finding links

    @Test func findsMarkdownLinksAndBareURLs() {
        let links = NoteLinks.links(in: "see [Docs](https://a.io/x) and https://b.io/y.")
        #expect(links == [
            NoteLink(range: NSRange(location: 4, length: 22), title: "Docs", url: "https://a.io/x", isBare: false),
            NoteLink(range: NSRange(location: 31, length: 14), title: "https://b.io/y", url: "https://b.io/y", isBare: true),
        ])
        #expect(links[0].isChip && !links[1].isChip)
        #expect(links[0].titleRange == NSRange(location: 5, length: 4))
    }

    @Test func linksInListItemsAndLaterLinesHaveTextRanges() {
        let text = "first\n- [ ] book [the hotel](https://h.de)"
        let link = NoteLinks.links(in: text).first
        #expect(link.map { (text as NSString).substring(with: $0.range) } == "[the hotel](https://h.de)")
        #expect(link?.title == "the hotel")
    }

    @Test func attachmentReferencesAndCodeAreNotLinks() {
        #expect(NoteLinks.links(in: "![shot.png](attachments/shot.png)").isEmpty)
        #expect(NoteLinks.links(in: "`[a](https://a.io)`").isEmpty)
        #expect(NoteLinks.links(in: "```\n[a](https://a.io)\n```").isEmpty)
    }

    @Test func theLinkAtTheCaretCountsBothEdges() {
        let links = NoteLinks.links(in: "x \(chip) y")
        #expect(NoteLinks.link(at: NSRange(location: 2, length: 0), in: links)?.title == "Docs")
        #expect(NoteLinks.link(at: NSRange(location: 24, length: 0), in: links)?.title == "Docs")
        #expect(NoteLinks.link(at: NSRange(location: 2, length: 22), in: links)?.title == "Docs")
        #expect(NoteLinks.link(at: NSRange(location: 1, length: 0), in: links) == nil)
        #expect(NoteLinks.link(at: NSRange(location: 25, length: 0), in: links) == nil)
    }

    @Test func aCaretBetweenTwoLinksBelongsToTheOneBefore() {
        let links = NoteLinks.links(in: "[A](https://a.io)[B](https://b.io)")
        #expect(NoteLinks.link(at: NSRange(location: 17, length: 0), in: links)?.title == "A")
    }

    // MARK: The caret steps over a chip

    @Test func arrowsStepOverAChip() {
        #expect(snap(from: "x |\(chip) y", to: "x [|Docs](https://a.io/x) y") == "x \(chip)| y")
        #expect(snap(from: "x \(chip)| y", to: "x [Docs](https://a.io/x|) y") == "x |\(chip) y")
    }

    @Test func aCaretLandingInsideFromAfarGoesToTheEdgeInItsDirection() {
        #expect(snap(from: "|ab\n\(chip)", to: "ab\n[Do|cs](https://a.io/x)") == "ab\n\(chip)|")
        #expect(snap(from: "\(chip)\nab|", to: "[Do|cs](https://a.io/x)\nab") == "|\(chip)\nab")
    }

    @Test func bareURLsAndPlainTextDontSnap() {
        #expect(snap(from: "|https://a.io", to: "https://a.|io") == "https://a.|io")
        #expect(snap(from: "|abc", to: "ab|c") == "ab|c")
    }

    @Test func aSelectionGrowsAndShrinksByWholeChips() {
        #expect(snap(from: "x \(chip)| y", to: "x [Docs](https://a.io/‹x)› y") == "x ‹\(chip)› y")
        #expect(snap(from: "x |\(chip) y", to: "x ‹[›Docs](https://a.io/x) y") == "x ‹\(chip)› y")
        #expect(snap(from: "x ‹\(chip)› y", to: "x ‹[Docs](https://a.io/x›) y") == "x |\(chip) y")
    }

    // MARK: Deleting a chip

    @Test func backspaceAfterAChipSelectsItFirst() {
        let (text, caret) = unmark("x \(chip)| y")
        #expect(NoteLinks.deleteBackward(in: text, selection: caret) == NSRange(location: 2, length: 22))
        #expect(NoteLinks.deleteBackward(in: text, selection: NSRange(location: 2, length: 22)) == nil, "the next ⌫ deletes")
        #expect(NoteLinks.deleteBackward(in: "https://a.io", selection: NSRange(location: 12, length: 0)) == nil)
    }

    @Test func forwardDeleteBeforeAChipSelectsItFirst() {
        let (text, caret) = unmark("x |\(chip) y")
        #expect(NoteLinks.deleteForward(in: text, selection: caret) == NSRange(location: 2, length: 22))
        #expect(NoteLinks.deleteForward(in: text, selection: NSRange(location: 1, length: 0)) == nil)
    }

    @Test func anEditCuttingIntoAChipTakesAllOfIt() {
        let text = "one \(chip) two"
        #expect(NoteLinks.widen(NSRange(location: 0, length: 8), in: text) == NSRange(location: 0, length: 26))
        #expect(NoteLinks.widen(NSRange(location: 10, length: 6), in: text) == NSRange(location: 4, length: 22))
        #expect(NoteLinks.widen(NSRange(location: 4, length: 22), in: text) == NSRange(location: 4, length: 22))
        #expect(NoteLinks.widen(NSRange(location: 0, length: 3), in: text) == NSRange(location: 0, length: 3))
        #expect(NoteLinks.widen(NSRange(location: 10, length: 0), in: text) == NSRange(location: 4, length: 22))
    }

    // MARK: Pasting

    @Test func onlyASingleWebAddressCountsAsAPastedURL() {
        #expect(NoteLinks.pastedURL("  https://github.com/a/b?c=d#e \n") == "https://github.com/a/b?c=d#e")
        #expect(NoteLinks.pastedURL("http://x.io") == "http://x.io")
        #expect(NoteLinks.pastedURL("see https://x.io") == nil)
        #expect(NoteLinks.pastedURL("https://x.io\nhttps://y.io") == nil)
        #expect(NoteLinks.pastedURL("ftp://x.io") == nil)
        #expect(NoteLinks.pastedURL("mailto:a@b.c") == nil)
        #expect(NoteLinks.pastedURL("https://") == nil)
        #expect(NoteLinks.pastedURL("hello") == nil)
    }

    @Test func pastingOverSelectedTextLinksIt() {
        let (text, selection) = unmark("book ‹the hotel› soon")
        let edit = NoteLinks.linkSelection(url: "https://h.de", in: text, selection: selection)
        #expect(edit.map { apply($0, to: text) } == "book [the hotel](https://h.de)| soon")
    }

    @Test func noDirectLinkForACaretBlankOrMultilineSelectionOrOverAnotherLink() {
        let url = "https://h.de"
        #expect(NoteLinks.linkSelection(url: url, in: "ab", selection: NSRange(location: 1, length: 0)) == nil)
        #expect(NoteLinks.linkSelection(url: url, in: "a  b", selection: NSRange(location: 1, length: 2)) == nil)
        #expect(NoteLinks.linkSelection(url: url, in: "ab\ncd", selection: NSRange(location: 1, length: 3)) == nil)
        #expect(NoteLinks.linkSelection(url: url, in: "x https://a.io", selection: NSRange(location: 0, length: 5)) == nil)
    }

    @Test func insertingPutsTheCaretAfterTheLink() {
        let (text, selection) = unmark("go |now")
        #expect(apply(NoteLinks.insert(title: "Docs", url: "https://a.io", replacing: selection), to: text)
            == "go [Docs](https://a.io)|now")
        #expect(apply(NoteLinks.insert(title: "  ", url: "https://a.io", replacing: selection), to: text)
            == "go https://a.io|now", "a blank title inserts the plain URL")
    }

    @Test func titlesAndURLsAreCleanedSoTheLinkStaysWhole() {
        #expect(NoteLinks.markdown(title: " a [b]\nc ", url: "https://a.io/x (1)") == "[a (b) c](https://a.io/x%20%281%29)")
    }

    @Test func theDomainDropsWWW() {
        #expect(NoteLinks.domain(of: "https://www.booking.com/x") == "booking.com")
        #expect(NoteLinks.domain(of: "https://developer.apple.com/") == "developer.apple.com")
        #expect(NoteLinks.domain(of: "nonsense") == "nonsense")
    }

    // MARK: Editing

    @Test func replacingAndUnlinking() {
        let text = "x \(chip) y"
        let link = NoteLinks.links(in: text)[0]
        #expect(apply(NoteLinks.replace(link, title: "API", url: "https://b.io"), to: text) == "x [API](https://b.io)| y")
        #expect(apply(NoteLinks.replace(link, title: "", url: "https://b.io"), to: text) == "x https://b.io| y")
        #expect(apply(NoteLinks.unlink(link), to: text) == "x Docs| y")
    }

    @Test func aBareURLGetsATitle() {
        let text = "x https://a.io y"
        let link = NoteLinks.links(in: text)[0]
        #expect(apply(NoteLinks.replace(link, title: "A", url: link.url), to: text) == "x [A](https://a.io)| y")
    }
}

@Suite struct LinkTitleTests {
    @Test func readsTheTitleTag() {
        #expect(LinkTitle.title(inHTML: "<html><head><title>Hello</title></head></html>") == "Hello")
        #expect(LinkTitle.title(inHTML: "<TITLE lang=\"en\">\n  Two\n  lines </TITLE>") == "Two lines")
    }

    @Test func decodesEntities() {
        #expect(LinkTitle.title(inHTML: "<title>A &amp; B &#8211; C&#x27;s &hellip; &bogus;</title>") == "A & B – C's … &bogus;")
    }

    @Test func fallsBackToOpenGraph() {
        #expect(LinkTitle.title(inHTML: #"<meta property="og:title" content="Graph &amp; Co">"#) == "Graph & Co")
        #expect(LinkTitle.title(inHTML: "<title> </title><meta content='Single' name='og:title'>") == "Single")
    }

    @Test func nothingWithoutATitle() {
        #expect(LinkTitle.title(inHTML: "<html><body>hi</body></html>") == nil)
        #expect(LinkTitle.title(inHTML: "<title>   </title>") == nil)
    }
}
