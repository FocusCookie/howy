import AppKit
import HowyCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global quick-entry shortcut, default ⌃⌥⇧⌘Space.
    static let quickAdd = Self("quickAdd", default: .init(.space, modifiers: [.control, .option, .shift, .command]))
    /// Global browse shortcut (open todos per quadrant), default ⌃⌥⇧⌘M.
    static let browse = Self("browse", default: .init(.m, modifiers: [.control, .option, .shift, .command]))
    /// The one shortcut in single-shortcut mode: opens the launcher (New Todo / Browse).
    /// Default ⌃⌥⇧⌘Space, like Quick Add; only the current mode's shortcuts act on a press.
    static let launcher = Self("launcher", default: .init(.space, modifiers: [.control, .option, .shift, .command]))
}

extension QuickEntryKey {
    /// Maps an AppKit key event to a flow key; `nil` for anything the focused control should handle itself.
    /// The mapping itself is pure and lives in HowyCore (`init(keyCode:modifiers:characters:)`).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: QuickEntryModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(keyCode: event.keyCode, modifiers: modifiers, characters: event.charactersIgnoringModifiers)
    }
}
