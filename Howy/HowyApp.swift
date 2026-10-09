import HowyCore
import KeyboardShortcuts
import SwiftUI

/// Menu-bar-only entry point (LSUIElement): no Dock icon, no main window.
/// All modal UI lives in floating panels owned by `AppController`.
@main
struct HowyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Howy", systemImage: "square.grid.2x2") {
            MenuContent(controller: AppController.shared)
        }
    }
}

private struct MenuContent: View {
    let controller: AppController

    var body: some View {
        // Shortcut hints only for the shortcuts that are live in the current mode.
        if controller.shortcutMode == .single {
            Button("Quick Add") { controller.showQuickEntry() }
            Button("Browse") { controller.showBrowse() }
        } else {
            Button("Quick Add") { controller.showQuickEntry() }
                .globalKeyboardShortcut(.quickAdd)
            Button("Browse") { controller.showBrowse() }
                .globalKeyboardShortcut(.browse)
        }
        Button("Archive") { controller.showArchive() }
        Divider()
        // Straight into a quadrant: the modal opens on the title, with the picker already answered.
        Menu("Add to Quadrant") {
            ForEach(Quadrant.allCases) { quadrant in
                Button(quadrant.displayName) {
                    controller.showQuickEntry(preselected: quadrant, startingInTitle: true)
                }
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
