import Foundation
import Testing
@testable import HowyCore

@Suite struct MarkdownHighlighterTests {
    /// The source substrings covered by spans of `style`, in order.
    func covered(_ text: String, _ style: MarkdownStyleSpan.Style) -> [String] {
        let ns = text as NSString
        return MarkdownHighlighter.spans(in: text)
            .filter { $0.style == style }
            .sorted { $0.range.location < $1.range.location }
            .map { ns.substring(with: $0.range) }
    }

    @Test func plainTextHasNoSpans() {
        #expect(MarkdownHighlighter.spans(in: "").isEmpty)
        #expect(MarkdownHighlighter.spans(in: "just a note, nothing fancy").isEmpty)
    }

    @Test func headingsCoverTheLineAndDimTheHashes() {
        let text = "# Big\nbody\n### Small"
        #expect(covered(text, .heading(level: 1)) == ["# Big"])
        #expect(covered(text, .heading(level: 3)) == ["### Small"])
        #expect(covered(text, .syntax) == ["# ", "### "])
    }

    @Test func hashWithoutSpaceIsNotAHeading() {
        #expect(covered("#hashtag", .heading(level: 1)).isEmpty)
    }

    @Test func boldAndItalicKeepTheirMarkersAsSyntax() {
        let text = "a **bold** and *it* and _also_"
        #expect(covered(text, .bold) == ["**bold**"])
        #expect(covered(text, .italic) == ["*it*", "_also_"])
        #expect(covered(text, .syntax) == ["**", "**", "*", "*", "_", "_"])
    }

    @Test func italicInsideBold() {
        let text = "**very *much* so**"
        #expect(covered(text, .bold) == ["**very *much* so**"])
        #expect(covered(text, .italic) == ["*much*"])
    }

    @Test func snakeCaseAndLoneStarsAreNotItalic() {
        #expect(covered("snake_case_name", .italic).isEmpty)
        #expect(covered("2 * 3 * 4", .italic).isEmpty)
    }

    @Test func inlineCodeIsNotStyledInside() {
        let text = "run `**not bold**` now"
        #expect(covered(text, .inlineCode) == ["`**not bold**`"])
        #expect(covered(text, .bold).isEmpty)
        #expect(covered(text, .syntax) == ["`", "`"])
    }

    @Test func strikethrough() {
        #expect(covered("~~gone~~", .strikethrough) == ["~~gone~~"])
    }

    @Test func fencedCodeBlocksCoverFencesAndBody() {
        let text = "before\n```swift\nlet x = **1**\n```\nafter *it*"
        #expect(covered(text, .codeBlock) == ["```swift\nlet x = **1**\n```"])
        #expect(covered(text, .bold).isEmpty, "no inline styling inside code")
        #expect(covered(text, .syntax) == ["```swift", "```", "*", "*"])
        #expect(covered(text, .italic) == ["*it*"])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        let text = "```\ncode\nmore"
        #expect(covered(text, .codeBlock) == [text])
    }

    @Test func listMarkers() {
        let text = "- one\n* two\n  + nested\n1. first\n12) twelfth"
        #expect(covered(text, .listMarker) == ["-", "*", "+", "1.", "12)"])
        #expect(covered(text, .italic).isEmpty, "a * bullet is not italic")
    }

    @Test func listItemsGetInlineStyling() {
        let text = "- buy **milk**"
        #expect(covered(text, .bold) == ["**milk**"])
    }

    @Test func quotesCoverTheLineAndDimTheMarker() {
        let text = "> quoted *text*\nnormal"
        #expect(covered(text, .quote) == ["> quoted *text*"])
        #expect(covered(text, .quoteMarker) == [">"], "drawn as a bar, not just dimmed")
        #expect(covered("> a\n>> b", .quoteMarker) == [">", ">>"])
        #expect(covered(text, .italic) == ["*text*"])
    }

    @Test func linksColourTheTextAndDimTheURL() {
        let text = "see [the docs](https://example.com) now"
        #expect(covered(text, .link) == ["the docs"])
        #expect(covered(text, .syntax) == ["[", "](https://example.com)"])
    }

    @Test func bareURLsAreLinks() {
        #expect(covered("go to https://apple.com/mac today", .link) == ["https://apple.com/mac"])
    }

    @Test func rangesAreUTF16() {
        let text = "😀 **bold** ✓"
        #expect(covered(text, .bold) == ["**bold**"])
    }

    @Test func spansStayInsideTheText() {
        let text = "# h\n- **a\n> `b\n```\nx"
        let length = (text as NSString).length
        for span in MarkdownHighlighter.spans(in: text) {
            #expect(span.range.location >= 0 && NSMaxRange(span.range) <= length)
        }
    }
}
