import Foundation

/// The one-time move from the old global shortcuts (Quick Add, Browse, and the launcher of
/// one-shortcut mode) to the one "Open Howy" shortcut.
///
/// `KeyboardShortcuts` stores every name's default on first launch, so an install from before
/// 2.1 has a value for each old name even when the user never touched them. Open Howy takes over
/// the shortcut the user pressed so far: the launcher's in one-shortcut mode (`shortcutMode` 1),
/// otherwise Quick Add's. A removed source shortcut (stored as `false`) or none at all keeps Open
/// Howy's default (⌃⌥⇧⌘Space), so Howy always has a way in. The Browse shortcut is dropped.
/// Afterwards the old names' values and the mode setting are removed (`staleKeys`).
///
/// Run it before anything reads the `openHowy` name: declaring that name stores its default when
/// it has no value, and this only writes over a value it copied itself.
public enum OpenHowyShortcutMigration {
    public enum Source: Hashable, Sendable {
        case quickAdd
        case launcher
    }

    public enum Result: Hashable, Sendable {
        /// An earlier launch migrated already; nothing changed.
        case alreadyDone
        /// Nothing to take over: Open Howy keeps its default.
        case keptDefault
        /// Open Howy now has this old shortcut's keys.
        case took(Source)
    }

    /// Set once the migration ran.
    public static let doneKey = "didMigrateToOpenHowyShortcut"
    /// The `KeyboardShortcuts` name of the Open Howy shortcut.
    public static let targetName = "openHowy"
    /// Where `KeyboardShortcuts` keeps the Open Howy shortcut.
    public static var targetKey: String { storageKey(targetName) }

    /// The settings of the old shortcuts and of the Settings rows that went with them.
    public static let staleKeys = [
        storageKey("quickAdd"), storageKey("browse"), storageKey("launcher"),
        "shortcutMode", "didMigrateBrowseShortcutToM",
    ]

    @discardableResult
    public static func run(in defaults: UserDefaults = .standard) -> Result {
        guard !defaults.bool(forKey: doneKey) else { return .alreadyDone }
        let source: Source = defaults.integer(forKey: "shortcutMode") == 1 ? .launcher : .quickAdd
        let sourceKey = storageKey(source == .launcher ? "launcher" : "quickAdd")
        // A recorded shortcut is a JSON string; a removed one is `false`.
        let recorded = defaults.object(forKey: sourceKey) as? String
        if let recorded { defaults.set(recorded, forKey: targetKey) }
        for key in staleKeys { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: doneKey)
        return recorded == nil ? .keptDefault : .took(source)
    }

    private static func storageKey(_ name: String) -> String { "KeyboardShortcuts_\(name)" }
}
