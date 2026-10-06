import Foundation
import Testing
@testable import HowyCore

@Suite struct MarkdownListContinuationTests {
    func next(_ line: String) -> MarkdownListContinuation.Action? {
        MarkdownListContinuation.action(forLineBeforeCaret: line)
    }

    @Test func plainLinesGetAPlainNewline() {
        #expect(next("") == nil)
        #expect(next("just text") == nil)
        #expect(next("-not a list") == nil)
        #expect(next("1.not a list") == nil)
    }

    @Test func bulletItemsContinueWithTheSameMarker() {
        #expect(next("- first") == .insert("\n- "))
        #expect(next("* first") == .insert("\n* "))
        #expect(next("+ first") == .insert("\n+ "))
    }

    @Test func indentationIsKept() {
        #expect(next("  - nested") == .insert("\n  - "))
        #expect(next("\t- nested") == .insert("\n\t- "))
    }

    @Test func numberedItemsIncrement() {
        #expect(next("1. first") == .insert("\n2. "))
        #expect(next("9) ninth") == .insert("\n10) "))
        #expect(next("  3. third") == .insert("\n  4. "))
    }

    @Test func taskItemsContinueUnchecked() {
        #expect(next("- [ ] todo") == .insert("\n- [ ] "))
        #expect(next("- [x] done") == .insert("\n- [ ] "))
    }

    @Test func anEmptyItemEndsTheList() {
        #expect(next("- ") == .removeMarker(length: 2))
        #expect(next("  * ") == .removeMarker(length: 4))
        #expect(next("2. ") == .removeMarker(length: 3))
        #expect(next("- [ ] ") == .removeMarker(length: 6))
    }

    @Test func caretInsideTheMarkerGetsAPlainNewline() {
        // Line before the caret is only part of the marker.
        #expect(next("-") == nil)
        #expect(next("1.") == nil)
    }

    @Test func spaceRunAfterTheMarkerIsKept() {
        #expect(next("-   wide") == .insert("\n-   "))
    }
}
