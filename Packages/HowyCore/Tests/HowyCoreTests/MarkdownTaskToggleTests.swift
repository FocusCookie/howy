import Foundation
import Testing
@testable import HowyCore

/// Text with a selection is written inline: `|` is a caret, `‹…›` a selected range.
@Suite struct MarkdownTaskToggleTests {
    /// Splits marked text into plain text and its selection.
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

    /// Puts the selection markers back into plain text.
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

    func apply(_ edit: MarkdownTaskToggle.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    /// Runs ⇧⌘L on marked text and returns the marked result, or nil when nothing changes.
    func toggle(_ marked: String) -> String? {
        let (text, selection) = unmark(marked)
        guard let edit = MarkdownTaskToggle.toggle(in: text, selection: selection) else { return nil }
        return mark(apply(edit, to: text), edit.selection)
    }

    // MARK: Single line

    @Test func plainTextBecomesAnUncheckedItem() {
        #expect(toggle("buy |milk") == "- [ ] buy |milk")
        #expect(toggle("|buy milk") == "- [ ] |buy milk", "the caret stays on the same text")
        #expect(toggle("buy milk|") == "- [ ] buy milk|")
    }

    @Test func listItemsGetABoxAndKeepTheirMarker() {
        #expect(toggle("- buy| milk") == "- [ ] buy| milk")
        #expect(toggle("* buy| milk") == "* [ ] buy| milk")
        #expect(toggle("+ buy| milk") == "+ [ ] buy| milk")
        #expect(toggle("1. buy| milk") == "1. [ ] buy| milk")
        #expect(toggle("12) buy| milk") == "12) [ ] buy| milk")
    }

    @Test func spacingAfterTheMarkerIsKept() {
        #expect(toggle("-   wide|") == "-   [ ] wide|")
    }

    @Test func uncheckedBoxesGetTicked() {
        #expect(toggle("- [ ] buy| milk") == "- [x] buy| milk")
        #expect(toggle("2. [ ] buy| milk") == "2. [x] buy| milk")
    }

    @Test func tickedBoxesGetUnticked() {
        #expect(toggle("- [x] buy| milk") == "- [ ] buy| milk")
        #expect(toggle("- [X] buy| milk") == "- [ ] buy| milk", "upper-case X counts as ticked")
    }

    @Test func caretAnywhereOnTheLineWorks() {
        #expect(toggle("|- [ ] milk") == "|- [x] milk")
        #expect(toggle("- [| ] milk") == "- [|x] milk")
        #expect(toggle("- |milk") == "- [ ] |milk")
    }

    @Test func indentationIsKept() {
        #expect(toggle("  - sub|") == "  - [ ] sub|")
        #expect(toggle("\t- sub|") == "\t- [ ] sub|")
        #expect(toggle("  text|") == "  - [ ] text|")
        #expect(toggle("    - [ ] deep|") == "    - [x] deep|")
    }

    @Test func onlyTheCaretLineChanges() {
        #expect(toggle("one\ntw|o\nthree") == "one\n- [ ] tw|o\nthree")
    }

    @Test func boxNeedsSpaceOrLineEndAfterIt() {
        #expect(toggle("- [x]done|") == "- [ ] [x]done|", "not a box, so it gets one in front")
        #expect(toggle("- [x]|") == "- [ ]|")
    }

    @Test func notAListMarkerWithoutSpace() {
        #expect(toggle("-dash|") == "- [ ] -dash|")
        #expect(toggle("1.5 litres|") == "- [ ] 1.5 litres|")
    }

    // MARK: Blank lines

    @Test func caretOnABlankLineStartsAnItem() {
        #expect(toggle("|") == "- [ ] |")
        #expect(toggle("one\n|\ntwo") == "one\n- [ ] |\ntwo")
        #expect(toggle("one\n|") == "one\n- [ ] |")
    }

    @Test func blankLineKeepsItsIndentation() {
        #expect(toggle("  |") == "  - [ ] |")
        #expect(toggle(" | ") == "  - [ ] |")
    }

    // MARK: Several lines

    @Test func severalPlainLinesBecomeAnUncheckedChecklist() {
        #expect(toggle("‹one\n- two\n  three›") == "‹- [ ] one\n- [ ] two\n  - [ ] three›")
    }

    @Test func mixedLinesAllGetTicked() {
        #expect(toggle("‹- [ ] one\n- [x] two\nthree\n- four›")
            == "‹- [x] one\n- [x] two\n- [x] three\n- [x] four›")
    }

    @Test func allTickedLinesGetUnticked() {
        #expect(toggle("‹- [x] one\n- [X] two›") == "‹- [ ] one\n- [ ] two›")
    }

    @Test func blankLinesInASelectionAreSkipped() {
        #expect(toggle("‹one\n\n  \ntwo›") == "‹- [ ] one\n\n  \n- [ ] two›")
        #expect(toggle("‹- [x] one\n\n- [x] two›") == "‹- [ ] one\n\n- [ ] two›",
                "blank lines don't stop 'all ticked'")
    }

    @Test func partlySelectedLinesCount() {
        #expect(toggle("on‹e\ntw›o\nthree") == "- [ ] on‹e\n- [ ] tw›o\nthree")
    }

    @Test func selectionEndingAtALineStartLeavesThatLineOut() {
        #expect(toggle("‹one\n›two") == "‹- [ ] one\n›two")
    }

    @Test func selectionWithOnlyBlankLinesDoesNothing() {
        #expect(toggle("a\n‹\n\n›b") == nil)
    }

    // MARK: Code blocks

    @Test func linesInFencedCodeAreLeftAlone() {
        #expect(toggle("```\nco|de\n```") == nil)
        #expect(toggle("|```\ncode\n```") == nil, "the fence itself too")
        #expect(toggle("‹one\n```\ncode\n```\ntwo›") == "‹- [ ] one\n```\ncode\n```\n- [ ] two›")
    }

    @Test func blankLineInCodeIsLeftAlone() {
        #expect(toggle("```\n|\n```") == nil)
    }

    // MARK: Undo-friendly edit

    @Test func editIsOneReplacementInsideTheText() throws {
        let text = "keep\none\ntwo\nkeep"
        let selection = NSRange(location: 5, length: 7)
        let edit = try #require(MarkdownTaskToggle.toggle(in: text, selection: selection))
        let ns = text as NSString
        #expect(edit.range.location >= 5 && NSMaxRange(edit.range) <= ns.length - 5)
        #expect(apply(edit, to: text) == "keep\n- [ ] one\n- [ ] two\nkeep")
    }

    @Test func worksWithNonASCIIText() {
        #expect(toggle("😀 mi|lk") == "- [ ] 😀 mi|lk")
        #expect(toggle("‹😀 one\n✓ two›") == "‹- [ ] 😀 one\n- [ ] ✓ two›")
    }

    // MARK: Clicking a box

    func click(_ text: String, boxAt location: Int) -> String? {
        let range = NSRange(location: location, length: 3)
        guard let edit = MarkdownTaskToggle.toggleBox(in: text, at: range) else { return nil }
        #expect(edit.range == range, "only the box characters change")
        return apply(edit, to: text)
    }

    @Test func clickingABoxFlipsIt() {
        #expect(click("- [ ] milk", boxAt: 2) == "- [x] milk")
        #expect(click("- [x] milk", boxAt: 2) == "- [ ] milk")
        #expect(click("- [X] milk", boxAt: 2) == "- [ ] milk")
    }

    @Test func clickingFlipsOnlyThatBox() {
        #expect(click("- [ ] one\n  1. [ ] two", boxAt: 15) == "- [ ] one\n  1. [x] two")
    }

    @Test func clickingSomethingElseDoesNothing() {
        #expect(click("- [ ] milk", boxAt: 0) == nil)
        #expect(click("[ ] not an item", boxAt: 0) == nil)
        #expect(click("```\n- [ ] code\n```", boxAt: 6) == nil)
        #expect(click("- [ ]", boxAt: 4) == nil, "out of bounds")
    }

    @Test func clickingKeepsTheTextLength() throws {
        let edit = try #require(MarkdownTaskToggle.toggleBox(in: "- [ ] milk", at: NSRange(location: 2, length: 3)))
        #expect(edit.replacement.utf16.count == 3)
    }
}
