import Foundation

/// The modifier keys that matter to the quick-entry modal (the app maps `NSEvent.ModifierFlags`
/// to this after dropping caps lock, numeric pad and function flags).
public struct QuickEntryModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = QuickEntryModifiers(rawValue: 1 << 0)
    public static let command = QuickEntryModifiers(rawValue: 1 << 1)
    public static let option = QuickEntryModifiers(rawValue: 1 << 2)
    public static let control = QuickEntryModifiers(rawValue: 1 << 3)
}

extension QuickEntryKey {
    /// Maps a key-down (macOS virtual key code, modifiers, characters ignoring modifiers) to a flow
    /// key. `nil` means "not ours": ⌘/⌃/⌥ combinations the focused control or the system handles.
    public init?(keyCode: UInt16, modifiers: QuickEntryModifiers, characters: String?) {
        let command = modifiers.contains(.command)
        let plain = modifiers.isEmpty

        switch keyCode {
        case 53: // Esc
            self = modifiers == .command ? .closePanel : .escape
        case 36, 76: // Return, keypad Enter
            if command, modifiers == .command {
                self = .commandEnter
            } else if modifiers == .option {
                self = .optionEnter
            } else if plain {
                self = .enter
            } else {
                return nil
            }
        case 48: // Tab
            if modifiers == .shift { self = .shiftTab } else if plain { self = .tab } else { return nil }
        case 51 where modifiers == .command: // ⌘⌫
            self = .commandDelete
        case 51 where plain: self = .backspace
        case 49 where plain: self = .space
        case 126 where modifiers == .command: self = .moveUp
        case 125 where modifiers == .command: self = .moveDown
        // ⌥1–4 by key code: charactersIgnoringModifiers gives the Option character (¡ “ ¶ ¢).
        case 18 where modifiers == .option: self = .optionDigit(1)
        case 19 where modifiers == .option: self = .optionDigit(2)
        case 20 where modifiers == .option: self = .optionDigit(3)
        case 21 where modifiers == .option: self = .optionDigit(4)
        case 123 where plain: self = .left
        case 124 where plain: self = .right
        case 125 where plain: self = .down
        case 126 where plain: self = .up
        default:
            if let zoom = Self.zoomKey(keyCode: keyCode, modifiers: modifiers, characters: characters) {
                self = zoom
            } else if modifiers == .command, characters?.lowercased() == "w" {
                self = .closePanel
            } else if modifiers == .command, characters?.lowercased() == "k" {
                self = .moveUp
            } else if modifiers == .command, characters?.lowercased() == "j" {
                self = .moveDown
            } else if modifiers == .command, characters?.lowercased() == "d" {
                self = .commandDone
            } else if modifiers == .command, characters?.lowercased() == "z" {
                self = .undo
            } else if modifiers == .command, let characters, characters.count == 1, let digit = Int(characters) {
                self = .commandDigit(digit)
            } else if plain, let characters, characters.count == 1, let digit = Int(characters) {
                self = .digit(digit)
            } else if plain, let characters, characters.count == 1, let letter = characters.first, letter.isLetter {
                self = .letter(Character(letter.lowercased()))
            } else if modifiers.isDisjoint(with: [.command, .option, .control]) {
                self = .other // typing, possibly shifted
            } else {
                return nil
            }
        }
    }

    /// ⌘= / ⌘+ zoom in, ⌘- zoom out, ⌘0 reset. Checked before the generic ⌘ + digit rule.
    /// By character first, so every layout works (US ⌘+ is ⌘⇧=, German ⌘= is ⌘⇧0 and German
    /// ⌘+ is its own key); shift is allowed only for ⌘+ and ⌘=. Without characters, by the US
    /// key codes (= 24, - 27, 0 29) and the keypad (+ 69, - 78, 0 82).
    private static func zoomKey(keyCode: UInt16, modifiers: QuickEntryModifiers, characters: String?) -> QuickEntryKey? {
        guard modifiers == .command || modifiers == [.command, .shift] else { return nil }
        let shifted = modifiers.contains(.shift)
        if let characters, !characters.isEmpty {
            switch characters {
            case "=", "+": return .zoomIn
            case "-" where !shifted: return .zoomOut
            case "0" where !shifted: return .zoomReset
            default: return nil
            }
        }
        switch keyCode {
        case 24, 69: return .zoomIn
        case 27 where !shifted, 78 where !shifted: return .zoomOut
        case 29 where !shifted, 82 where !shifted: return .zoomReset
        default: return nil
        }
    }
}
