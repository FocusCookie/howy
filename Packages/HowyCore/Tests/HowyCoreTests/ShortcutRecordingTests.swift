import HowyCore
import Testing

@Suite struct ShortcutRecordingTests {
    let h: UInt16 = 0x04
    let f5: UInt16 = 0x60

    @Test func commandLetterIsAccepted() {
        #expect(ShortcutRecording.outcome(keyCode: h, modifiers: .command) == .accept)
    }

    @Test func hyperLetterIsAccepted() {
        #expect(ShortcutRecording.outcome(keyCode: h, modifiers: [.control, .option, .shift, .command]) == .accept)
    }

    @Test func plainLetterNeedsModifier() {
        #expect(ShortcutRecording.outcome(keyCode: h, modifiers: []) == .needsModifier)
    }

    @Test func shiftAloneNeedsModifier() {
        #expect(ShortcutRecording.outcome(keyCode: h, modifiers: .shift) == .needsModifier)
    }

    @Test func functionKeyAloneIsAccepted() {
        #expect(ShortcutRecording.outcome(keyCode: f5, modifiers: []) == .accept)
    }

    @Test func plainEscapeCancels() {
        #expect(ShortcutRecording.outcome(keyCode: 0x35, modifiers: []) == .cancel)
    }

    @Test func modifiedEscapeIsAShortcut() {
        #expect(ShortcutRecording.outcome(keyCode: 0x35, modifiers: .control) == .accept)
    }

    @Test func plainDeleteClears() {
        #expect(ShortcutRecording.outcome(keyCode: 0x33, modifiers: []) == .clear)
        #expect(ShortcutRecording.outcome(keyCode: 0x75, modifiers: []) == .clear)
    }

    @Test func symbolsUseMacOrder() {
        #expect(ShortcutRecording.symbols(for: [.command, .shift, .option, .control]) == "⌃⌥⇧⌘")
        #expect(ShortcutRecording.symbols(for: []) == "")
    }
}
