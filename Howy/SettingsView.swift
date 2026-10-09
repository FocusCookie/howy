import AppKit
import HowyCore
import KeyboardShortcuts
import SwiftUI

/// The things worth configuring: how big the panels are drawn, the global shortcuts (one launcher shortcut, or separate Quick Add
/// and Browse shortcuts), the quadrant new todos start on, how attachments open, what plays when a
/// todo is marked done, how big Browse's Overview is, how long the archive keeps done todos, and
/// launching at login.
struct SettingsView: View {
    let controller: AppController
    @State private var newTodoQuadrant = NewTodoQuadrant.load()
    @State private var recorder = ShortcutRecorderModel()
    @State private var launcherDefault = LauncherChoice.loadDefault()
    @State private var openMode = AttachmentOpenMode.load()
    @State private var doneAnimation = DoneAnimation.load()
    @State private var archiveRetention = ArchiveRetention.load()
    @State private var overviewSize = OverviewSize.load()
    @State private var copiedFormat = false

    /// Width of each of the two columns.
    private static let columnWidth: CGFloat = 440

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column { leftSections }
            column { rightSections }
        }
        .fixedSize()
        .animation(.snappy(duration: 0.2), value: controller.shortcutMode)
        .onAppear { controller.refreshLaunchesAtLogin() }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            recorder.stop()
        }
    }

    /// One grouped form column, as tall as its content so it never scrolls.
    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: Self.columnWidth)
            .fixedSize()
    }

    /// Appearance, Shortcuts, New Todos, Attachments and Celebration.
    @ViewBuilder private var leftSections: some View {
        Section {
            LabeledContent("Panel size:") { zoomSlider }
        } header: {
            Text("Appearance")
        } footer: {
            Text("How big text and everything else is in Howy's panels. In an open panel, ⌘+ and ⌘- change it too, and ⌘0 goes back to 100 %.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
    }

    /// Overview, Archive, Import Format and General.
    @ViewBuilder private var rightSections: some View {
        Section {
            LabeledContent("Width:") {
                percentSlider(
                    "Overview width", value: overviewSize.widthPercent,
                    set: { overviewSize.with(widthPercent: $0) }
                )
            }
            LabeledContent("Height:") {
                percentSlider(
                    "Overview height", value: overviewSize.heightPercent,
                    set: { overviewSize.with(heightPercent: $0) }
                )
            }
            OverviewSizePreview(size: overviewSize)
                .frame(maxWidth: .infinity)
        } header: {
            Text("Overview")
        } footer: {
            Text("How much of the screen Browse's Overview takes (O, or the button between the quadrants). The tiles never get narrower than the editor needs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            Picker("Delete done todos after:", selection: $archiveRetention) {
                ForEach(ArchiveRetention.options) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: archiveRetention) { _, value in value.save() }
        } header: {
            Text("Archive")
        } footer: {
            Text("Done todos and their attachments are deleted from the archive once they're older than this.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Convert data from other apps:") {
                Button(copiedFormat ? "Copied" : "Copy for AI") { copyFormat() }
            }
        } header: {
            Text("Import Format")
        } footer: {
            Text("Export writes a folder with howy.json and attachments/<todo id>/<file name>, and Import reads it back. To bring in todos from another app, copy the format and paste it into an AI chat together with your data; it answers with a howy.json you can import.")
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
}

extension SettingsView {
    /// Puts the import format description on the pasteboard and says "Copied" for a moment.
    private func copyFormat() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HowyFormat.llmDescription, forType: .string)
        copiedFormat = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedFormat = false
        }
    }

    private var overviewRange: ClosedRange<Double> {
        Double(OverviewSize.percentRange.lowerBound)...Double(OverviewSize.percentRange.upperBound)
    }

    /// A 50–95 % slider for one of the Overview's percentages (`value`), with its value; `set`
    /// gives the size with a new percentage, saved as the slider moves.
    private func percentSlider(_ label: String, value: Int, set: @escaping (Int) -> OverviewSize) -> some View {
        HStack {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { newValue in
                        let size = set(Int(newValue.rounded()))
                        guard size != overviewSize else { return }
                        overviewSize = size
                        size.save()
                    }
                ),
                in: overviewRange, step: 5
            )
            .labelsHidden()
            .accessibilityLabel(label)
            .accessibilityValue("\(value) percent")
            Text("\(value) %")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    /// The panel zoom's four stops (100 / 115 / 130 / 150 %), with the current percentage. The
    /// same value as ⌘+ / ⌘- / ⌘0 in a panel (`AppController.panelZoom`).
    private var zoomSlider: some View {
        let zoom = controller.panelZoom
        return HStack {
            Slider(
                value: Binding(
                    get: { Double(zoom.step) },
                    set: { controller.setPanelZoom(PanelZoom(step: Int($0.rounded()))) }
                ),
                in: Double(PanelZoom.steps.lowerBound)...Double(PanelZoom.steps.upperBound),
                step: 1
            )
            .labelsHidden()
            .accessibilityLabel("Panel size")
            .accessibilityValue("\(zoom.percent) percent")
            Text("\(zoom.percent) %")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var footerHint: String {
        let recording = "Click a shortcut, then press the new keys. Esc cancels, Delete removes it."
        guard controller.shortcutMode == .single else { return recording }
        return "Opens a chooser: ← or 1 for New Todo, → or 2 for Browse, ↩ for the selected one. " + recording
    }
}

/// The Overview setting's preview: the screen the Settings window is on as a rounded rectangle
/// (its aspect, its menu bar and Dock left out as on screen), with the Overview's frame on it in
/// the accent colour, worked out by the same `OverviewSize.frame` as the real panel, grown from
/// where the panel's card sits when it was not moved (`OverviewSize.compactCardCenter`).
private struct OverviewSizePreview: View {
    let size: OverviewSize
    @State private var screen: NSScreen?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 220
    /// About the height of Browse's small card (the four quadrant cards and the footer).
    private static let compactCardHeight: CGFloat = 264

    var body: some View {
        let shownScreen = screen ?? NSScreen.main
        let full = shownScreen?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = shownScreen?.visibleFrame ?? full
        let scale = Self.width / full.width
        // AppKit's origin is bottom-left; the preview's is top-left.
        let shown = CGRect(
            x: (visible.minX - full.minX) * scale, y: (full.maxY - visible.maxY) * scale,
            width: visible.width * scale, height: visible.height * scale
        )
        let center = OverviewSize.compactCardCenter(in: shown, cardHeight: Self.compactCardHeight * scale, yAxisUp: false)
        let overview = size.frame(in: shown, centeredOn: center, scale: scale)
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35))
                    .strokeBorder(Color.accentColor, lineWidth: 1)
                    .frame(width: overview.width, height: overview.height)
                    .offset(x: overview.minX, y: overview.minY)
            }
            .frame(width: Self.width, height: full.height * scale)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: size)
            .accessibilityElement()
            .accessibilityLabel("Overview size preview")
            .accessibilityValue("\(size.widthPercent) percent wide, \(size.heightPercent) percent high")
            Text("Shaped like the screen this window is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .background(ScreenReader { screen = $0 })
    }
}

/// Reports the screen its window is on, now and whenever the window moves to another one.
private struct ScreenReader: NSViewRepresentable {
    let onScreen: (NSScreen?) -> Void

    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.onScreen = onScreen
        return view
    }

    func updateNSView(_ view: ScreenView, context: Context) {
        view.onScreen = onScreen
    }

    final class ScreenView: NSView {
        var onScreen: (NSScreen?) -> Void = { _ in }
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            let screen = window?.screen
            DispatchQueue.main.async { [weak self] in self?.onScreen(screen) }
        }
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
        NSApp.returnToAccessoryUnlessWindowsAreOpen(except: notification.object as? NSWindow)
    }
}
