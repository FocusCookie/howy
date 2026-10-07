import Testing
@testable import HowyCore

@Suite struct KeyHintTests {
    @Test func firstWordOfEachItemIsAKey() {
        #expect(KeyHint.items(in: "↩ open · esc close") == [
            [.key("↩"), .text("open")],
            [.key("esc"), .text("close")],
        ])
    }

    @Test func modifiersGetTheirOwnCaps() {
        #expect(KeyHint.items(in: "⌘↩ save · ⇧⇥ title") == [
            [.key("⌘"), .key("↩"), .text("save")],
            [.key("⇧"), .key("⇥"), .text("title")],
        ])
        #expect(KeyHint.caps("⌃⌥⇧⌘Space") == ["⌃", "⌥", "⇧", "⌘", "Space"])
    }

    @Test func laterModifierWordsAndNumberRangesAreKeys() {
        #expect(KeyHint.items(in: "⌘J ⌘K move · ←→ or 1–2") == [
            [.key("⌘"), .key("J"), .key("⌘"), .key("K"), .text("move")],
            [.key("←→"), .text("or"), .key("1–2")],
        ])
    }

    @Test func multiWordLabelsStayOneText() {
        #expect(KeyHint.items(in: "↩ add files · a archive") == [
            [.key("↩"), .text("add files")],
            [.key("a"), .text("archive")],
        ])
    }

    @Test func emptyItemsAreDropped() {
        #expect(KeyHint.items(in: "") == [])
        #expect(KeyHint.items(in: "esc close · ") == [[.key("esc"), .text("close")]])
    }
}
