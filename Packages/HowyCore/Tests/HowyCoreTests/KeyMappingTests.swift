import Testing
@testable import HowyCore

@Suite struct KeyMappingTests {
    func key(_ code: UInt16, _ modifiers: QuickEntryModifiers = [], _ chars: String? = nil) -> QuickEntryKey? {
        QuickEntryKey(keyCode: code, modifiers: modifiers, characters: chars)
    }

    @Test func escapeWithAnyOtherModifiers() {
        #expect(key(53) == .escape)
        #expect(key(53, .shift) == .escape)
        #expect(key(53, [.command, .shift]) == .escape)
    }

    @Test func commandWOrCommandEscapeClosesThePanel() {
        #expect(key(13, .command, "w") == .closePanel)
        #expect(key(13, .command, "W") == .closePanel)
        #expect(key(53, .command) == .closePanel)
        #expect(key(13, [.command, .shift], "w") == nil)
        #expect(key(13, [], "w") == .letter("w"))
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

    @Test func commandZIsUndoAndShiftCommandZIsNotOurs() {
        #expect(key(6, .command, "z") == .undo)
        #expect(key(6, .command, "Z") == .undo)
        #expect(key(6, [.command, .shift], "z") == nil, "⇧⌘Z (redo) stays with the system")
        #expect(key(6, [], "z") == .letter("z"))
    }

    @Test func commandBackspaceOnly() {
        #expect(key(51, .command) == .commandDelete)
        #expect(key(51) == .backspace)
        #expect(key(51, [.command, .shift]) == nil)
    }

    @Test func commandDIsDone() {
        #expect(key(2, .command, "d") == .commandDone)
        #expect(key(2, [], "d") == .letter("d"))
        #expect(key(2, [.command, .shift], "d") == nil)
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
        #expect(key(18, .option, "¡") == .optionDigit(1), "⌥1–4 are their own key (Overview focus)")
        #expect(key(23, .option, "[") == nil)
    }

    @Test func commandDigitIsItsOwnKey() {
        #expect(key(18, .command, "1") == .commandDigit(1), "⌘1–4 moves a todo in Browse")
        #expect(key(21, .command, "4") == .commandDigit(4))
        #expect(key(18, [.command, .shift], "1") == nil)
        #expect(key(18, [.command, .option], "1") == nil)
    }

    @Test func mIsALetter() {
        #expect(key(46, [], "m") == .letter("m"), "m opens Browse's move picker")
    }

    @Test func plainLettersAreLetters() {
        #expect(key(0, [], "a") == .letter("a"))
        #expect(key(0, [], "Z") == .letter("z"), "caps lock: still the plain key")
        #expect(key(0, .shift, "A") == .other, "shifted: typing only")
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
        #expect(key(40, [], "k") == .letter("k"), "plain K types")
        #expect(key(126, [.command, .option]) == nil)
    }

    @Test(arguments: [(UInt16(18), 1), (19, 2), (20, 3), (21, 4)])
    func optionDigitsMapByKeyCode(code: UInt16, digit: Int) {
        // charactersIgnoringModifiers gives the Option character (German: ¡ “ ¶ ¢), not the digit.
        #expect(key(code, .option, "¡") == .optionDigit(digit))
        #expect(key(code, .option, nil) == .optionDigit(digit))
        #expect(key(code, [.option, .shift], "⁄") == nil)
        #expect(key(code, [.option, .command], "¡") == nil)
        #expect(key(code, [.option, .control], "¡") == nil, "⌥⌃ digits aren't ours")
        #expect(key(code, [], String(digit)) == .digit(digit), "without modifiers still the plain digit")
    }

    @Test func optionWithOtherDigitsIsNotOurs() {
        #expect(key(23, .option, "[") == nil) // ⌥5
        #expect(key(29, .option, "≠") == nil) // ⌥0
    }

    @Test func plainOIsALetter() {
        #expect(key(31, [], "o") == .letter("o"))
        #expect(key(31, .option, "ø") == nil)
    }
}

@Suite struct ZoomKeyMappingTests {
    func key(_ code: UInt16, _ modifiers: QuickEntryModifiers = [], _ chars: String? = nil) -> QuickEntryKey? {
        QuickEntryKey(keyCode: code, modifiers: modifiers, characters: chars)
    }

    @Test func commandEqualsAndCommandPlusZoomIn() {
        #expect(key(24, .command, "=") == .zoomIn, "US ⌘=")
        #expect(key(24, [.command, .shift], "+") == .zoomIn, "US ⌘+ is ⌘⇧=")
        #expect(key(24, [.command, .shift], "=") == .zoomIn, "⌘⇧= when the characters stay unshifted")
        #expect(key(30, .command, "+") == .zoomIn, "German ⌘+ (own key)")
        #expect(key(29, [.command, .shift], "=") == .zoomIn, "German ⌘= is ⌘⇧0")
        #expect(key(69, .command, "+") == .zoomIn, "keypad +")
        #expect(key(24, .command, nil) == .zoomIn, "no characters: by the US key code")
    }

    @Test func commandMinusZoomsOut() {
        #expect(key(27, .command, "-") == .zoomOut, "US ⌘-")
        #expect(key(44, .command, "-") == .zoomOut, "German ⌘-")
        #expect(key(78, .command, "-") == .zoomOut, "keypad -")
        #expect(key(27, .command, nil) == .zoomOut, "no characters: by the US key code")
    }

    @Test func commandZeroResetsTheZoom() {
        #expect(key(29, .command, "0") == .zoomReset)
        #expect(key(82, .command, "0") == .zoomReset, "keypad 0")
        #expect(key(29, .command, nil) == .zoomReset, "no characters: by the US key code")
    }

    @Test(arguments: [(UInt16(18), 1), (19, 2), (20, 3), (21, 4)])
    func commandOneToFourStillMoveToQuadrants(code: UInt16, digit: Int) {
        #expect(key(code, .command, String(digit)) == .commandDigit(digit))
    }

    @Test func zoomKeysNeedCommand() {
        #expect(key(24, [], "=") == .other, "plain = types")
        #expect(key(27, [], "-") == .other, "plain - types")
        #expect(key(24, .shift, "+") == .other)
        #expect(key(29, [], "0") == .digit(0))
        #expect(key(24, [.command, .option], "=") == nil)
        #expect(key(27, [.command, .control], "-") == nil)
        #expect(key(27, [.command, .shift], "_") == nil, "⌘⇧- (⌘_) is not zoom out")
        #expect(key(29, [.command, .shift], ")") == nil, "⌘⇧0 on US is not reset")
    }
}
