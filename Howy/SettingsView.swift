import AppKit
import HowyCore
import KeyboardShortcuts
import SwiftUI

// Settings' five tabs (`AppController.SettingsTab`), each a single grouped form as tall as its
// content; `SettingsWindowController` puts them in a toolbar and sizes the window to the tab.

/// The width of every tab's form.
private let settingsWidth: CGFloat = 520

extension View {
    /// One tab's grouped form: `settingsWidth` wide and as tall as its content, so it never scrolls.
    fileprivate func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: settingsWidth)
            .fixedSize()
    }
}

/// A section footer's explanation.
private struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: General

/// Launching at login, how attachments open, the default time of due dates (and a hint when
/// notifications are off).
struct GeneralSettingsView: View {
    let controller: AppController
    @State private var openMode = AttachmentOpenMode.load()
    @State private var dueDefaultTime = DueTime.load()
    private let notifications = NotificationCoordinator.shared

    var body: some View {
        Form {
            Section {
                Toggle("Start Howy at login", isOn: Binding(
                    get: { controller.launchesAtLogin },
                    set: { controller.setLaunchesAtLogin($0) }
                ))
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
                FooterText("Click, Space or ↩ opens an attachment this way; ⌥-click or ⌥↩ opens it the other way.")
            }
            Section {
                LabeledContent("Time when none is typed:") {
                    DatePicker("Time when none is typed", selection: dueTimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                if notifications.authorization == .denied {
                    LabeledContent("Notifications off —") {
                        Button("Open System Settings") { notifications.openSystemSettings() }
                    }
                    .foregroundStyle(.red)
                }
            } header: {
                Text("Due Dates")
            } footer: {
                FooterText("⌘T in the editor or T in a list sets a due date: type \"tomorrow\", \"fri 2pm\", \"24.12.\" or \"in a week\". A day without a time is due at this time, and so is \"Tomorrow\" on a notification. Howy notifies you when a todo is due; due dates and the red bells work without notifications too.")
            }
        }
        .settingsForm()
        .onAppear { controller.refreshLaunchesAtLogin() }
        .task { await notifications.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifications.refreshAuthorization() } // back from System Settings
        }
    }

    /// The default due time as a date today, for the time picker; a new time is saved.
    private var dueTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: dueDefaultTime.hour, minute: dueDefaultTime.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let time = DueTime(hour: c.hour ?? 9, minute: c.minute ?? 0)
                guard time != dueDefaultTime else { return }
                dueDefaultTime = time
                time.save()
                notifications.registerCategory() // the Tomorrow button names the time
            }
        )
    }
}

// MARK: Appearance

/// How big the panels are drawn, how big Browse's Overview is, and what plays when a todo is done.
struct AppearanceSettingsView: View {
    let controller: AppController
    @State private var overviewSize = OverviewSize.load()
    @State private var doneAnimation = DoneAnimation.load()

    var body: some View {
        Form {
            Section {
                LabeledContent("Panel size:") { zoomSlider }
            } header: {
                Text("Panels")
            } footer: {
                FooterText("How big text and everything else is in Howy's panels. In an open panel, ⌘+ and ⌘- change it too, and ⌘0 goes back to 100 %.")
            }
            Section {
                LabeledContent("Width:") {
                    percentSlider("Overview width", value: overviewSize.widthPercent) { overviewSize.with(widthPercent: $0) }
                }
                LabeledContent("Height:") {
                    percentSlider("Overview height", value: overviewSize.heightPercent) { overviewSize.with(heightPercent: $0) }
                }
                OverviewSizePreview(size: overviewSize)
                    .frame(maxWidth: .infinity)
            } header: {
                Text("Overview")
            } footer: {
                FooterText("How much of the screen the Overview takes (O on the grid, or the button between the quadrants). The tiles never get narrower than the editor needs.")
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
                FooterText("A random emoji rises out of the panel when you mark a todo done, with a small confetti burst. Reduce Motion skips the confetti.")
            }
        }
        .settingsForm()
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
}

// MARK: iCloud

/// The sync status line (highlighted for a moment when a sync notice was clicked) and what
/// syncing does.
struct ICloudSettingsView: View {
    let controller: AppController

    var body: some View {
        Form {
            Section {
                SyncStatusRow(monitor: controller.syncMonitor, highlightRequest: controller.syncLineHighlightRequest)
            } header: {
                Text("Sync")
            } footer: {
                FooterText("Howy syncs your todos and their attachments through your iCloud account. Signing out of iCloud or turning it off for Howy removes the synced todos from this Mac (signing back in brings them back). Howy tells you when that happens, when iCloud is full, when sync has failed for over an hour, or when Low Power Mode turns on and sync may be delayed. The daily backups are under Data.")
            }
        }
        .settingsForm()
    }
}

// MARK: Data

/// How long the archive keeps done todos, import and export (with the format for an AI chat), and
/// the daily backups' folder.
struct DataSettingsView: View {
    let controller: AppController
    @State private var copiedFormat = false

    var body: some View {
        Form {
            Section {
                Picker("Delete done todos after:", selection: Binding(
                    get: { controller.retention.retention },
                    set: { controller.setArchiveRetention($0) }
                )) {
                    ForEach(ArchiveRetention.options) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } header: {
                Text("Archive")
            } footer: {
                FooterText("Done todos and their attachments are deleted from the archive once they're older than this.")
            }
            Section {
                LabeledContent("Todos and attachments:") {
                    HStack {
                        Button("Import…") { controller.importFolder() }
                        Button("Export…") { controller.exportAll() }
                    }
                }
                LabeledContent("Convert data from other apps:") {
                    Button(copiedFormat ? "Copied" : "Copy for AI") { copyFormat() }
                }
                LabeledContent("Daily backups:") {
                    Button("Show in Finder") { controller.showBackupsInFinder() }
                }
            } header: {
                Text("Import & Export")
            } footer: {
                FooterText("Export writes a folder with howy.json and attachments/<todo id>/<file name>, and Import reads it back (also in Howy's menu). To bring in todos from another app, copy the format and paste it into an AI chat together with your data; it answers with a howy.json you can import. Howy also exports everything once a day as a backup and keeps the last 7; import one to restore it.")
            }
        }
        .settingsForm()
    }

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
}

// MARK: Keys

/// The Open Howy recorder, then every key Howy knows (`KeysReference`), by screen, read-only.
/// Only the reference scrolls, so the window stays a laptop screen's height.
struct KeysSettingsView: View {
    @State private var recorder = ShortcutRecorderModel()

    /// How tall the reference is before it scrolls.
    private static let referenceHeight: CGFloat = 440
    /// The keys column's width.
    private static let keysWidth: CGFloat = 190

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Open Howy:") { ShortcutField(name: .openHowy, model: recorder) }
                    Button("Restore Default") {
                        recorder.restoreDefaults() // ⌃⌥⇧⌘Space
                    }
                } header: {
                    Text("Shortcut")
                } footer: {
                    Text(recorder.message ?? "Opens the quadrants, or closes Howy when it is open. Click the shortcut, then press the new keys. Esc cancels, Delete removes it.")
                        .font(.caption)
                        .foregroundStyle(recorder.message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
            }
            .settingsForm()
            Form {
                ForEach(KeysReference.screens) { screen in
                    Section {
                        ForEach(screen.rows) { row in
                            referenceRow(row)
                        }
                    } header: {
                        Text(screen.title)
                    } footer: {
                        if let note = screen.note { FooterText(note) }
                    }
                }
            }
            .formStyle(.grouped)
            .contentMargins(.top, 0, for: .scrollContent)
            .frame(width: settingsWidth, height: Self.referenceHeight)
        }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            recorder.stop()
        }
    }

    private func referenceRow(_ row: KeysReference.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            keys(row.keys)
                .frame(width: Self.keysWidth, alignment: .leading)
            Text(row.action)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The alternatives as keycaps with a "/" between them: [↑][↓] / [j][k].
    @ViewBuilder private func keys(_ keys: KeysReference.Row.Keys) -> some View {
        switch keys {
        case .keys(let alternatives):
            HStack(spacing: 4) {
                ForEach(Array(alternatives.enumerated()), id: \.offset) { index, alternative in
                    if index > 0 { Text("/").foregroundStyle(.tertiary) }
                    ForEach(Array(Self.caps(alternative).enumerated()), id: \.offset) { _, text in cap(text) }
                }
            }
        case .openHowyShortcut:
            if let shortcut = recorder.shortcut(for: .openHowy) {
                HStack(spacing: 4) {
                    ForEach(Array(ShortcutField.caps(for: shortcut).enumerated()), id: \.offset) { _, text in cap(text) }
                }
            } else {
                Text("Open Howy (not set)").foregroundStyle(.secondary)
            }
        }
    }

    /// "⌘↑ ⌘↓" → ["⌘", "↑", "⌘", "↓"]; "h j k l" → ["h", "j", "k", "l"].
    private static func caps(_ alternative: String) -> [String] {
        alternative.split(separator: " ").flatMap { KeyHint.caps(String($0)) }
    }

    private func cap(_ text: String) -> some View {
        KeyCap(text: text, font: .system(size: 11, weight: .medium), minSize: 20)
    }
}

/// Settings' sync line: `SyncMonitor.status` (with `statusHint`, e.g. Low Power Mode, below it),
/// re-read every 15 seconds (whether an event still counts as running, and "last synced", depend on
/// the time). Highlighted for a moment when a sync notice was clicked
/// (`AppController.syncLineHighlightRequest`, a few seconds old at most).
private struct SyncStatusRow: View {
    let monitor: SyncMonitor
    let highlightRequest: Date?
    @State private var highlighted = false

    /// The title, then the sentences under it (each ends with its own full stop).
    private static func spoken(_ title: String, _ sentences: [String]) -> String {
        sentences.isEmpty ? title : "\(title). " + sentences.joined(separator: " ")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            let status = monitor.status
            let hint = monitor.statusHint
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .foregroundStyle(status.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    if case .upToDate(let last?) = status {
                        Text("Last synced \(last, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let detail = status.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("iCloud sync")
            .accessibilityValue(Self.spoken(status.title, [status.detail, hint].compactMap { $0 }))
        }
        .listRowBackground(highlighted ? Color.accentColor.opacity(0.18) : nil)
        .animation(.easeInOut(duration: 0.3), value: highlighted)
        .task(id: highlightRequest) {
            guard let highlightRequest, Date.now.timeIntervalSince(highlightRequest) < 5 else { return }
            highlighted = true
            try? await Task.sleep(for: .seconds(2))
            highlighted = false
        }
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


// MARK: Window

extension AppController.SettingsTab {
    var label: String {
        switch self {
        case .general: "General"
        case .keys: "Keys"
        case .appearance: "Appearance"
        case .iCloud: "iCloud"
        case .data: "Data"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .keys: "keyboard"
        case .appearance: "paintbrush"
        case .iCloud: "icloud"
        case .data: "externaldrive"
        }
    }
}

/// Settings' tabs as a toolbar of icons with labels, like macOS apps' settings. The window takes
/// each tab's size (anchored at its top edge), also when a tab's content grows or shrinks, and
/// the chosen tab is remembered on this Mac.
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private static let lastTabKey = "settingsLastTab"
    private let tabs = AppController.SettingsTab.allCases

    init(controller: AppController) {
        let lastTab = Self.lastTab // read first: adding the tabs selects (and saves) the first one
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [] // the window resize is the transition
        for tab in tabs {
            let hosting = NSHostingController(rootView: Self.view(for: tab, controller: controller))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = tab.label
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.label
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.label)
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = tabs.firstIndex(of: lastTab) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @ViewBuilder
    private static func view(for tab: AppController.SettingsTab, controller: AppController) -> some View {
        switch tab {
        case .general: GeneralSettingsView(controller: controller)
        case .keys: KeysSettingsView()
        case .appearance: AppearanceSettingsView(controller: controller)
        case .iCloud: ICloudSettingsView(controller: controller)
        case .data: DataSettingsView(controller: controller)
        }
    }

    /// The tab used last on this Mac (General the first time).
    private static var lastTab: AppController.SettingsTab {
        UserDefaults.standard.string(forKey: lastTabKey).flatMap(AppController.SettingsTab.init(rawValue:)) ?? .general
    }

    func select(_ tab: AppController.SettingsTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if tabs.indices.contains(selectedTabViewItemIndex) {
            UserDefaults.standard.set(tabs[selectedTabViewItemIndex].rawValue, forKey: Self.lastTabKey)
        }
        fitWindow(animate: viewIfLoaded?.window?.isVisible == true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === tabViewItems[safe: selectedTabViewItemIndex]?.viewController else { return }
        fitWindow(animate: viewIfLoaded?.window?.isVisible == true)
    }

    /// Sizes the window to the selected tab's content, keeping its top edge where it is.
    func fitWindow(animate: Bool) {
        guard let window = viewIfLoaded?.window,
              let content = tabViewItems[safe: selectedTabViewItemIndex]?.viewController else { return }
        let size = content.preferredContentSize == .zero ? content.view.fittingSize : content.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animate)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A regular titled window for Settings. A menu-bar-only app has no Settings scene to lean on,
/// and an accessory app's window doesn't reliably become key (clicks then only focus it), so the
/// app becomes a regular app while Settings is open and goes back to accessory mode afterwards.
///
/// It opens on the tab used last, or on the tab a caller asked for (`AppController.settingsTabRequest`,
/// each request once).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var tabs: SettingsTabViewController?
    /// The request already acted on, so an old one doesn't switch tabs again.
    private var handledRequest: AppController.SettingsTabRequest?

    func show(controller: AppController) {
        if window == nil {
            let tabs = SettingsTabViewController(controller: controller)
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.delegate = self
            self.window = window
            self.tabs = tabs
        }
        if let request = controller.settingsTabRequest, request != handledRequest {
            handledRequest = request
            tabs?.select(request.tab)
        }
        let isNew = window?.isVisible == false
        tabs?.fitWindow(animate: !isNew)
        if isNew { window?.center() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil // rebuild next time, so it re-reads login item and settings
        tabs = nil
        NSApp.returnToAccessoryUnlessWindowsAreOpen(except: notification.object as? NSWindow)
    }
}
