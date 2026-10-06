import Testing
@testable import HowyCore

@Suite struct KeyMappingTests {
    func key(_ code: UInt16, _ modifiers: QuickEntryModifiers = [], _ chars: String? = nil) -> QuickEntryKey? {
        QuickEntryKey(keyCode: code, modifiers: modifiers, characters: chars)
    }

    @Test func escapeWithAnyModifiers() {
        #expect(key(53) == .escape)
        #expect(key(53, .command) == .escape)
    }

    @Test(arguments: [UInt16(36), 76])
    func returnAndKeypadEnter(code: UInt16) {
        #expect(key(code) == .enter)
        #expect(key(code, .command) == .commandEnter)
        #expect(key(code, .shift) == nil)
        #expect(key(code, [.command, .shift]) == nil)
        #expect(key(code, .option) == .optionEnter)
    }

    @Test func tabAndShiftTab() {
        #expect(key(48) == .tab)
        #expect(key(48, .shift) == .shiftTab)
        #expect(key(48, .command) == nil)
        #expect(key(48, .control) == nil)
    }

    @Test func commandBackspaceOnly() {
        #expect(key(51, .command) == .commandDelete)
        #expect(key(51) == .backspace)
        #expect(key(51, [.command, .shift]) == nil)
    }

    @Test func arrowsNeedNoModifiers() {
        #expect(key(123) == .left)
        #expect(key(124) == .right)
        #expect(key(125) == .down)
        #expect(key(126) == .up)
        #expect(key(126, .shift) == .other, "shift+arrow extends a selection in a text field")
        #expect(key(123, .command) == nil)
        #expect(key(126, .command) == .moveUp, "⌘↑ reorders in Browse; quick entry passes it on to the text field")
    }

    @Test func digitsOnlyWhenPlain() {
        #expect(key(18, [], "1") == .digit(1))
        #expect(key(29, [], "0") == .digit(0))
        #expect(key(18, .shift, "!") == .other)
        #expect(key(18, .command, "1") == nil)
        #expect(key(18, .option, "1") == nil)
    }

    @Test func lettersAreOtherWhenTyping() {
        #expect(key(0, [], "a") == .other)
        #expect(key(0, .shift, "A") == .other)
        #expect(key(0, .command, "a") == nil, "⌘A etc. belong to the focused control")
        #expect(key(0, .control, "a") == nil)
        #expect(key(0, [], nil) == .other)
    }
}

@Suite struct SpaceKeyMappingTests {
    func key(_ code: UInt16, _ modifiers: QuickEntryModifiers = [], _ chars: String? = nil) -> QuickEntryKey? {
        QuickEntryKey(keyCode: code, modifiers: modifiers, characters: chars)
    }

    @Test func plainSpaceIsSpace() {
        #expect(QuickEntryKey(keyCode: 49, modifiers: [], characters: " ") == .space)
        #expect(QuickEntryKey(keyCode: 49, modifiers: .shift, characters: " ") == .other)
        #expect(QuickEntryKey(keyCode: 49, modifiers: .command, characters: " ") == nil)
    }

    @Test func commandArrowsAndJKMoveRows() {
        #expect(key(126, .command) == .moveUp)
        #expect(key(125, .command) == .moveDown)
        #expect(key(40, .command, "k") == .moveUp)
        #expect(key(38, .command, "j") == .moveDown)
        #expect(key(40, [.command, .shift], "K") == nil)
        #expect(key(40, [], "k") == .other)
        #expect(key(126, [.command, .option]) == nil)
    }
}
