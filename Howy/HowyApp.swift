import HowyCore
import KeyboardShortcuts
import SwiftUI

/// Menu-bar-only entry point (LSUIElement): no Dock icon, no main window.
/// All modal UI lives in floating panels owned by `AppController`.
@main
struct HowyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The earliest app code: before the delegate's `applicationWillFinishLaunching`, a launching
    /// `howy://` URL and any use of the store (see `AppController.configureStoreSync`).
    init() {
        // First, before anything (the menu's `.globalKeyboardShortcut(.openHowy)`) reads the Open
        // Howy name, which stores its default when it has none.
        let migration = OpenHowyShortcutMigration.run()
        if migration != .alreadyDone {
            log.notice("Open Howy shortcut migration: \(String(describing: migration), privacy: .public)")
        }
        AppController.configureStoreSync()
    }

    var body: some Scene {
        MenuBarExtra("Howy", systemImage: "square.grid.2x2") {
            MenuContent(controller: AppController.shared)
        }
    }
}

private struct MenuContent: View {
    let controller: AppController

    var body: some View {
        Button("Open Howy") { controller.showBrowse() }
            .globalKeyboardShortcut(.openHowy)
        Button("Archive") { controller.showArchive() }
        Divider()
        // Straight into a quadrant: the editor opens on the title, the quadrant already chosen.
        Menu("Add to Quadrant") {
            ForEach(Quadrant.allCases) { quadrant in
                Button(quadrant.displayName) { controller.showCreate(in: quadrant) }
            }
        }
        Divider()
        Button("Import…") { controller.importFolder() }
        Button("Export…") { controller.exportAll() }
        Divider()
        Button("Settings…") { controller.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Howy") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
        // CloudKit mirroring imports when a silent push arrives. The `aps-environment`
        // entitlement is there; on macOS the app registers with APNs itself.
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        log.info("Registered for remote notifications (CloudKit pushes)")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("Remote notification registration failed: \(error, privacy: .public). Push-triggered imports may not arrive.")
    }

    /// Quitting with a modal open keeps its draft, like any other close without saving.
    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.closePanel()
    }

    /// `howy://` deep links from the widgets. `.onOpenURL` is unreliable for a MenuBarExtra-only app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppController.shared.handle(url: url)
        }
    }
}
