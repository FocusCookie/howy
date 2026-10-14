import Foundation
import Testing
@testable import HowyCore

@Suite struct MarkdownListIndentTests {
    /// Applies an edit and returns the text and the selection after it.
    func apply(_ edit: MarkdownTaskToggle.Edit?, to text: String) -> (String, NSRange)? {
        guard let edit else { return nil }
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    func indent(_ text: String, _ selection: NSRange) -> (String, NSRange)? {
        apply(MarkdownListIndent.indent(in: text, selection: selection), to: text)
    }

    func outdent(_ text: String, _ selection: NSRange) -> (String, NSRange)? {
        apply(MarkdownListIndent.outdent(in: text, selection: selection), to: text)
    }

    @Test func tabNestsTheItemUnderTheOneBefore() {
        let text = "- first\n- second"
        let result = indent(text, NSRange(location: 16, length: 0))
        #expect(result?.0 == "- first\n\t- second")
        #expect(result?.1 == NSRange(location: 17, length: 0)) // the caret stays on its text
    }

    @Test func tabWorksAnywhereInTheItem() {
        #expect(indent("- a\n1. b", NSRange(location: 4, length: 0))?.0 == "- a\n\t1. b")
        #expect(indent("- a\n- [ ] b", NSRange(location: 10, length: 0))?.0 == "- a\n\t- [ ] b")
        #expect(indent("- a\n- ", NSRange(location: 6, length: 0))?.0 == "- a\n\t- ")
    }

    @Test func nestingGoesDeeper() {
        #expect(indent("- a\n\t- b", NSRange(location: 8, length: 0))?.0 == "- a\n\t\t- b")
    }

    @Test func aSelectionIndentsEveryItemItTouches() {
        let text = "- a\n- b\ntext\n- c"
        let result = indent(text, NSRange(location: 4, length: 12))
        #expect(result?.0 == "- a\n\t- b\ntext\n\t- c")
        #expect(result?.1 == NSRange(location: 4, length: 14)) // still the whole lines
    }

    @Test func tabOutsideAListIsNotHandled() {
        #expect(MarkdownListIndent.indent(in: "plain", selection: NSRange(location: 5, length: 0)) == nil)
        #expect(MarkdownListIndent.indent(in: "", selection: NSRange(location: 0, length: 0)) == nil)
        #expect(MarkdownListIndent.indent(in: "```\n- code\n```", selection: NSRange(location: 6, length: 0)) == nil)
    }

    @Test func shiftTabRemovesOneLevel() {
        let result = outdent("- a\n\t\t- b", NSRange(location: 9, length: 0))
        #expect(result?.0 == "- a\n\t- b")
        #expect(result?.1 == NSRange(location: 8, length: 0))
    }

    @Test func shiftTabRemovesUpToFourSpaces() {
        #expect(outdent("- a\n   - b", NSRange(location: 9, length: 0))?.0 == "- a\n- b")
        #expect(outdent("- a\n      - b", NSRange(location: 12, length: 0))?.0 == "- a\n  - b")
    }

    @Test func shiftTabOnATopLevelItemIsNotHandled() {
        // The flow then takes Shift-Tab back to the title.
        #expect(MarkdownListIndent.outdent(in: "- a\n- b", selection: NSRange(location: 6, length: 0)) == nil)
        #expect(MarkdownListIndent.outdent(in: "  text", selection: NSRange(location: 4, length: 0)) == nil)
    }

    @Test func aCaretInTheIndentStaysAtTheLineStart() {
        let result = outdent("\t- a", NSRange(location: 0, length: 0))
        #expect(result?.1 == NSRange(location: 0, length: 0))
    }
}
