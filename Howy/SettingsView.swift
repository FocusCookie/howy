import AppKit
import HowyCore
import KeyboardShortcuts
import SwiftUI

/// The things worth configuring: the global shortcuts (one launcher shortcut, or separate Quick Add
/// and Browse shortcuts), the quadrant new todos start on, how attachments open, what plays when a
/// todo is marked done, and launching at login.
struct SettingsView: View {
    let controller: AppController
    @State private var newTodoQuadrant = NewTodoQuadrant.load()
    @State private var recorder = ShortcutRecorderModel()
    @State private var launcherDefault = LauncherChoice.loadDefault()
    @State private var openMode = AttachmentOpenMode.load()
    @State private var doneAnimation = DoneAnimation.load()

    var body: some View {
        Form {
            Section {
                Toggle("Use one shortcut for everything", isOn: Binding(
                    get: { controller.shortcutMode == .single },
                    set: { single in
                        recorder.stop()
                        controller.setShortcutMode(single ? .single : .separate)
                    }
                ))
                if controller.shortcutMode == .single {
                    LabeledContent("Open Howy:") { ShortcutField(name: .launcher, model: recorder) }
                    Picker("Selected first:", selection: $launcherDefault) {
                        Text("New Todo").tag(LauncherChoice.create)
                        Text("Browse").tag(LauncherChoice.browse)
                    }
                    .onChange(of: launcherDefault) { _, value in value.saveAsDefault() }
                } else {
                    LabeledContent("Quick Add:") { ShortcutField(name: .quickAdd, model: recorder) }
                    LabeledContent("Browse:") { ShortcutField(name: .browse, model: recorder) }
                }
                Button("Restore Default Shortcuts") {
                    recorder.restoreDefaults() // ⌃⌥⇧⌘Space, ⌃⌥⇧⌘M and ⌃⌥⇧⌘Space
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text(recorder.message ?? footerHint)
                    .font(.caption)
                    .foregroundStyle(recorder.message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
            Section("New Todos") {
                Picker("Start on:", selection: $newTodoQuadrant) {
                    ForEach(NewTodoQuadrant.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .onChange(of: newTodoQuadrant) { _, value in value.save() }
            }
            Section {
                Picker("Open attachments in:", selection: $openMode) {
                    ForEach(AttachmentOpenMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: openMode) { _, value in value.save() }
            } header: {
                Text("Attachments")
            } footer: {
                Text("Click, Space or ↩ opens an attachment this way; ⌥-click or ⌥↩ opens it the other way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("When a todo is done:", selection: $doneAnimation) {
                    ForEach(DoneAnimation.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .onChange(of: doneAnimation) { _, value in value.save() }
            } header: {
                Text("Celebration")
            } footer: {
                Text("A random emoji rises out of the panel when you mark a todo done, with a small confetti burst. Reduce Motion skips the confetti.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Start Howy at login", isOn: Binding(
                    get: { controller.launchesAtLogin },
                    set: { controller.setLaunchesAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
        .animation(.snappy(duration: 0.2), value: controller.shortcutMode)
        .onAppear { controller.refreshLaunchesAtLogin() }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            recorder.stop()
        }
    }
}

extension SettingsView {
    private var footerHint: String {
        let recording = "Click a shortcut, then press the new keys. Esc cancels, Delete removes it."
        guard controller.shortcutMode == .single else { return recording }
        return "Opens a chooser: ← or 1 for New Todo, → or 2 for Browse, ↩ for the selected one. " + recording
    }
}

/// A regular titled window for Settings. A menu-bar-only app has no Settings scene to lean on,
/// and an accessory app's window doesn't reliably become key (clicks then only focus it), so the
/// app becomes a regular app while Settings is open and goes back to accessory mode afterwards.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(controller: AppController) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(controller: controller)))
            window.title = "Howy Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil // rebuild next time, so it re-reads login item and settings
        NSApp.setActivationPolicy(.accessory)
    }
}
