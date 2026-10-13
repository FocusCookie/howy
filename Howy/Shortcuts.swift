import AppKit
import HowyCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The one global shortcut, default ⌃⌥⇧⌘Space: opens Browse's quadrant grid, or closes Howy
    /// when a panel is open. It replaced Quick Add, Browse and the launcher of one-shortcut mode
    /// (`OpenHowyShortcutMigration`, which `HowyApp.init()` runs before this is first read).
    static let openHowy = Self(
        OpenHowyShortcutMigration.targetName, default: .init(.space, modifiers: [.control, .option, .shift, .command])
    )
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
