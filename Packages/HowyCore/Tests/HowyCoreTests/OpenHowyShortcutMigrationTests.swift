import Foundation
import HowyCore
import Testing

@Suite struct OpenHowyShortcutMigrationTests {
    let quickAdd = #"{"carbonKeyCode":40,"carbonModifiers":768}"#
    let launcher = #"{"carbonKeyCode":49,"carbonModifiers":6400}"#
    let browse = #"{"carbonKeyCode":46,"carbonModifiers":6912}"#

    func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "OpenHowyShortcutMigrationTests-\(UUID())"))
    }

    var target: String { OpenHowyShortcutMigration.targetKey }

    @Test func freshInstallKeepsTheDefault() throws {
        let defaults = try makeDefaults()
        #expect(OpenHowyShortcutMigration.run(in: defaults) == .keptDefault)
        #expect(defaults.object(forKey: target) == nil)
        #expect(defaults.bool(forKey: OpenHowyShortcutMigration.doneKey))
    }

    @Test func separateShortcutsHandTheQuickAddShortcutOver() throws {
        let defaults = try makeDefaults()
        defaults.set(quickAdd, forKey: "KeyboardShortcuts_quickAdd")
        defaults.set(browse, forKey: "KeyboardShortcuts_browse")
        defaults.set(launcher, forKey: "KeyboardShortcuts_launcher")
        #expect(OpenHowyShortcutMigration.run(in: defaults) == .took(.quickAdd))
        #expect(defaults.string(forKey: target) == quickAdd)
    }

    @Test func oneShortcutModeHandsTheLauncherShortcutOver() throws {
        let defaults = try makeDefaults()
        defaults.set(1, forKey: "shortcutMode")
        defaults.set(quickAdd, forKey: "KeyboardShortcuts_quickAdd")
        defaults.set(launcher, forKey: "KeyboardShortcuts_launcher")
        #expect(OpenHowyShortcutMigration.run(in: defaults) == .took(.launcher))
        #expect(defaults.string(forKey: target) == launcher)
    }

    @Test func aRemovedSourceShortcutKeepsTheDefault() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "KeyboardShortcuts_quickAdd") // how KeyboardShortcuts stores "none"
        defaults.set(browse, forKey: "KeyboardShortcuts_browse")
        #expect(OpenHowyShortcutMigration.run(in: defaults) == .keptDefault)
        #expect(defaults.object(forKey: target) == nil)
    }

    @Test func theBrowseShortcutIsNeverTaken() throws {
        let defaults = try makeDefaults()
        defaults.set(browse, forKey: "KeyboardShortcuts_browse")
        #expect(OpenHowyShortcutMigration.run(in: defaults) == .keptDefault)
        #expect(defaults.object(forKey: target) == nil)
    }

    @Test func theOldKeysAreRemoved() throws {
        let defaults = try makeDefaults()
        for key in ["KeyboardShortcuts_quickAdd", "KeyboardShortcuts_browse", "KeyboardShortcuts_launcher"] {
            defaults.set(quickAdd, forKey: key)
        }
        defaults.set(0, forKey: "shortcutMode")
        defaults.set(true, forKey: "didMigrateBrowseShortcutToM")
        OpenHowyShortcutMigration.run(in: defaults)
        for key in OpenHowyShortcutMigration.staleKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
        #expect(OpenHowyShortcutMigration.staleKeys.contains("KeyboardShortcuts_browse"))
    }

    @Test func runsOnlyOnce() throws {
        let defaults = try makeDefaults()
        defaults.set(quickAdd, forKey: "KeyboardShortcuts_quickAdd")
        OpenHowyShortcutMigration.run(in: defaults)
        // The user records another Open Howy shortcut; a later launch must not overwrite it.
        defaults.set(launcher, forKey: target)
        defaults.set(quickAdd, forKey: "KeyboardShortcuts_quickAdd")
        #expect(OpenHowyShortcutMigration.run(in: defaults) == .alreadyDone)
        #expect(defaults.string(forKey: target) == launcher)
    }
}
