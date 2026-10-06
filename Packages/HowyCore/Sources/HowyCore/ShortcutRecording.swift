import Foundation

/// What a key press does while a Settings shortcut recorder is listening.
///
/// fn (Globe) is never part of a recorded shortcut: global hotkeys that include it don't fire
/// reliably, and it is set implicitly on F-keys and arrows anyway, so callers drop it before asking.
public enum ShortcutRecordingOutcome: Equatable, Sendable {
    /// Store this key with these modifiers.
    case accept
    /// Plain Esc: stop recording and keep the old shortcut.
    case cancel
    /// Plain Delete / Forward Delete: remove the shortcut.
    case clear
    /// A key without ⌘, ⌃ or ⌥ (Shift alone isn't enough): it would swallow ordinary typing.
    case needsModifier
}

public enum ShortcutRecording {
    static let escape: UInt16 = 0x35
    static let delete: UInt16 = 0x33
    static let forwardDelete: UInt16 = 0x75
    /// F1–F20, which may be used without modifiers.
    static let functionKeys: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    public static func outcome(keyCode: UInt16, modifiers: QuickEntryModifiers) -> ShortcutRecordingOutcome {
        if modifiers.isEmpty {
            if keyCode == escape { return .cancel }
            if keyCode == delete || keyCode == forwardDelete { return .clear }
        }
        if functionKeys.contains(keyCode) { return .accept }
        return modifiers.subtracting(.shift).isEmpty ? .needsModifier : .accept
    }

    /// Modifier glyphs in the order macOS shows them: ⌃⌥⇧⌘.
    public static func symbols(for modifiers: QuickEntryModifiers) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }
}
