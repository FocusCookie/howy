import AppKit
import HowyCore
import KeyboardShortcuts
import os
import ServiceManagement
import SwiftUI

let log = Logger(subsystem: "io.lichtwart.howy", category: "app")

/// Owns the global shortcuts, the single modal panel, archive purging and the login item.
@MainActor
@Observable
final class AppController {
    static let shared = AppController()

    private(set) var launchesAtLogin = false
    /// One launcher shortcut, or separate Quick Add and Browse shortcuts (Settings).
    private(set) var shortcutMode = ShortcutMode.load()

    private enum PanelKind { case launcher, quickEntry, edit, archive, browse, error }

    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var panelKind: PanelKind?
    @ObservationIgnored private var activatedForPanel = false
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var purgeTimer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let lastUsed = UserDefaultsLastQuadrantStore()
    @ObservationIgnored private let drafts = UserDefaultsDraftStore()
    @ObservationIgnored private let settingsWindow = SettingsWindowController()

    private static let didRegisterLoginItemKey = "didRegisterLoginItem"
    private static let didMigrateBrowseShortcutKey = "didMigrateBrowseShortcutToM"
    private static let panelWidth: CGFloat = 560

    private init() {}

    func start() {
        ShortcutRecorderModel.removeFunctionModifier()
        migrateBrowseShortcut()
        // All three stay registered (the launcher shares Quick Add's default keys, and disabling one
        // would unregister the shared hotkey); a press only acts in the mode its shortcut belongs to.
        KeyboardShortcuts.onKeyUp(for: .quickAdd) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.shortcutMode == .separate else { return }
                self?.toggleQuickEntry()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .browse) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.shortcutMode == .separate else { return }
                self?.toggleBrowse()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .launcher) { [weak self] in
            MainActor.assumeIsolated {
                guard self?.shortcutMode == .single else { return }
                self?.toggleLauncher()
            }
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeArchive() }
        }
        purgeTimer?.tolerance = 60 * 60
        // Timers don't advance while the Mac sleeps, so also purge on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeArchive() }
        }
        // Keep the hotkey responsive: the slow launch work (login item, store open) runs after launch.
        Task { @MainActor [weak self] in
            self?.registerLoginItemOnFirstLaunch()
            self?.purgeArchive()
            self?.collectStagedAttachments()
        }
    }

    // MARK: Deep links

    func handle(url: URL) {
        guard let link = DeepLink(url: url) else {
            log.notice("Ignoring unknown URL \(url.absoluteString, privacy: .public)")
            return
        }
        log.notice("Deep link \(url.absoluteString, privacy: .public)")
        switch link {
        case .edit(let id): showEdit(id: id, activate: true)
        case .quickAdd(let quadrant): showQuickEntry(preselected: quadrant, activate: true)
        case .archive: showArchive(activate: true)
        }
    }

    // MARK: Panels

    func setShortcutMode(_ mode: ShortcutMode) {
        mode.save()
        shortcutMode = mode
    }

    /// The launcher shortcut closes whatever is open (launcher, or a screen opened from it).
    func toggleLauncher() {
        if panel != nil { closePanel() } else { showLauncher() }
    }

    /// Without a choice (a fresh open), the highlight starts on the Settings default; coming back
    /// from a screen highlights that screen's choice.
    func showLauncher(highlighting choice: LauncherChoice? = nil) {
        let flow = LauncherFlow(highlighted: choice ?? LauncherChoice.loadDefault())
        let open: (LauncherChoice) -> Void = { [weak self] choice in
            switch choice {
            case .create: self?.showQuickEntry(viaLauncher: true)
            case .browse: self?.showBrowse(resuming: nil, viaLauncher: true)
            }
        }
        let panel = present(.launcher, activate: false) {
            LauncherView(flow: flow) { choice in
                if case .open = flow.open(choice) { open(choice) }
            }
        }
        panel.keyHandler = { [weak panel] event in
            guard let key = QuickEntryKey(event: event) else { return false }
            switch flow.handle(key) {
            case .ignored: return false
            case .handled: break
            case .open(let choice): open(choice)
            case .close: panel?.dismiss()
            }
            return true
        }
    }

    func toggleQuickEntry() {
        // Only a quick-entry panel toggles closed; an edit or archive panel is replaced by Quick Add.
        if panel != nil, panelKind == .quickEntry {
            panel?.dismiss()
        } else {
            showQuickEntry()
        }
    }

    /// Closes whatever panel is open (its draft is stashed like on any close without saving).
    func closePanel() {
        panel?.dismiss()
    }

    func toggleBrowse() {
        if panel != nil, panelKind == .browse {
            panel?.dismiss()
        } else {
            showBrowse()
        }
    }

    /// Where an edit opened from Browse returns to.
    private struct BrowseReturn {
        let quadrant: Quadrant
        let todoID: UUID
        let index: Int?
        /// Browse itself was opened from the launcher, so leaving it goes back there.
        let viaLauncher: Bool
    }

    func showBrowse(activate: Bool = false) {
        showBrowse(resuming: nil, activate: activate)
    }

    /// With `viaLauncher`, Esc on the quadrants returns to the launcher instead of closing.
    /// `fromArchive` reopens the picker with the Archive button highlighted (Esc in the archive).
    private func showBrowse(
        resuming back: BrowseReturn?, viaLauncher: Bool = false, fromArchive: Bool = false, activate: Bool = false
    ) {
        let viaLauncher = back?.viaLauncher ?? viaLauncher
        guard let store = freshStore(activate: activate) else { return }
        let todos: [Quadrant: [TodoSnapshot]]
        do {
            todos = try store.openSnapshots()
        } catch {
            log.error("Browse fetch failed: \(error, privacy: .public)")
            showError(title: "Can't read Howy's data", message: error.localizedDescription, activate: activate)
            return
        }
        let flow = BrowseFlow(todos: todos)
        if let back { flow.resumeListing(back.quadrant, selecting: back.todoID, fallbackIndex: back.index) }
        if fromArchive { flow.highlightArchive() }
        let model = BrowseModel(flow: flow, store: store)
        let panel = present(.browse, activate: activate) { BrowseView(model: model) }
        panel.keyHandler = { event in
            guard let key = QuickEntryKey(event: event) else { return false }
            return model.handle(key)
        }
        model.close = { [weak self, weak panel] in
            if viaLauncher { self?.showLauncher(highlighting: .browse) } else { panel?.dismiss() }
        }
        model.openTodo = { [weak self, weak flow] id in
            let back = flow.map {
                BrowseReturn(quadrant: $0.quadrant, todoID: id, index: $0.selectedIndex, viaLauncher: viaLauncher)
            }
            self?.showEdit(id: id, returningTo: back)
        }
        model.openArchive = { [weak self] in
            self?.showArchive(returning: { [weak self] in
                self?.showBrowse(resuming: nil, viaLauncher: viaLauncher, fromArchive: true)
            })
        }
    }

    /// With `viaLauncher`, Esc returns to the launcher (keeping the draft) instead of closing.
    /// With `startingInTitle`, the modal opens on the title field instead of the picker — for the
    /// menu bar's "Add to Quadrant", where the quadrant was already chosen.
    func showQuickEntry(
        preselected: Quadrant? = nil, startingInTitle: Bool = false,
        viaLauncher: Bool = false, activate: Bool = false
    ) {
        guard let store = freshStore(activate: activate) else { return }
        let flow = QuickEntryFlow(
            mode: .create(preselected: preselected, startingInTitle: startingInTitle),
            lastUsed: lastUsed, drafts: drafts,
            startQuadrant: NewTodoQuadrant.load()
        )
        let model = QuickEntryModel(flow: flow, store: store)
        presentQuickEntry(model, kind: .quickEntry, activate: activate)
        if viaLauncher {
            model.close = { [weak self, weak model] in
                if model?.flow.phase == .cancelled {
                    self?.showLauncher(highlighting: .create)
                } else {
                    self?.closePanel()
                }
            }
        }
    }

    func showEdit(id: UUID, activate: Bool = false) {
        showEdit(id: id, returningTo: nil, activate: activate)
    }

    /// With `back`, Esc / save / delete return to that Browse list; losing focus still closes.
    private func showEdit(id: UUID, returningTo back: BrowseReturn?, activate: Bool = false) {
        guard let store = freshStore(activate: activate) else { return }
        guard let todo = try? store.todo(id: id) else {
            log.notice("Edit link for missing todo \(id.uuidString, privacy: .public)")
            return
        }
        // A stale widget can link to a todo that has just been completed: don't edit it unseen.
        if todo.completedAt != nil {
            showArchive(activate: activate)
            return
        }
        let flow = QuickEntryFlow(
            mode: .edit(QuickEntryDraft(todo: todo, attachments: store.attachmentList(for: id))),
            lastUsed: lastUsed, drafts: drafts
        )
        let model = QuickEntryModel(flow: flow, store: store)
        presentQuickEntry(model, kind: .edit, activate: activate)
        if let back {
            model.close = { [weak self] in self?.showBrowse(resuming: back) }
        }
    }

    func showArchive(activate: Bool = false) {
        showArchive(returning: nil, activate: activate)
    }

    /// With `back`, Esc runs it (returns to Browse) instead of closing; losing focus still closes.
    private func showArchive(returning back: (() -> Void)?, activate: Bool = false) {
        guard let store = freshStore(activate: activate) else { return }
        do { try store.purgeArchive(retention: .load()) } catch { log.error("Purge failed: \(error, privacy: .public)") }
        let model = ArchiveModel(store: store)
        let panel = present(.archive, activate: activate) {
            ArchiveView(model: model, escapeHint: back == nil ? "esc close" : "esc back")
        }
        panel.keyHandler = { event in
            guard let key = QuickEntryKey(event: event) else { return false }
            return model.handle(key)
        }
        model.close = { [weak panel] in
            if let back { back() } else { panel?.dismiss() }
        }
    }

    private func presentQuickEntry(_ model: QuickEntryModel, kind: PanelKind, activate: Bool) {
        let panel = present(kind, activate: activate) { QuickEntryView(model: model) }
        panel.keyHandler = { event in
            guard let key = QuickEntryKey(event: event) else { return false }
            return model.handle(key)
        }
        model.close = { [weak panel] in panel?.dismiss() }
        model.presenter = AttachmentPresenter(panel: panel) { [weak self] in self?.activateForPanel() }
        model.didFinish = { [weak self] in self?.collectStagedAttachments() }
        // Focus loss, the hotkey, or another panel replacing this one: keep what was typed.
        // (No-op after Esc / save / delete, which finished the flow already.)
        panel.willClose = { model.flow.abandon() }
    }

    /// Makes Howy the active app for the open panel (Quick Look, a file picker need it), remembering
    /// the app in front so focus goes back there when the panel closes.
    private func activateForPanel() {
        guard !NSApp.isActive else { return }
        if !activatedForPanel {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        activatedForPanel = true
        NSApp.activate()
    }

    /// Deletes staged attachment files no unsaved draft refers to any more.
    private func collectStagedAttachments() {
        guard let files = try? AttachmentStore.shared() else { return }
        files.collectStaging(keeping: drafts.stashedAttachmentIDs())
    }

    private func showError(title: String, message: String, activate: Bool) {
        let panel = present(.error, activate: activate) { ErrorView(title: title, message: message) }
        panel.keyHandler = { [weak panel] event in
            guard QuickEntryKey(event: event) == .escape else { return false }
            panel?.dismiss()
            return true
        }
    }

    /// Shows a screen: inside the open panel when there is one (the card resizes and the contents
    /// cross-fade, e.g. Browse ↔ edit, launcher → Quick Add), otherwise in a new panel. The caller
    /// sets the returned panel's `keyHandler` / `willClose` right away.
    private func present<Content: View>(
        _ kind: PanelKind, activate: Bool, @ViewBuilder content: () -> Content
    ) -> FloatingPanel {
        if let current = panel, current.canReplaceContent {
            panelKind = kind
            current.replaceContent(content)
            if activate, !NSApp.isActive {
                if !activatedForPanel {
                    let front = NSWorkspace.shared.frontmostApplication
                    previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
                }
                activatedForPanel = true
                NSApp.activate()
            }
            return current
        }
        let newPanel = FloatingPanel(width: Self.panelWidth, content: content)
        present(newPanel, kind: kind, activate: activate)
        return newPanel
    }

    private func present(_ newPanel: FloatingPanel, kind: PanelKind, activate: Bool) {
        let previous = panel
        panel = newPanel
        panelKind = kind
        previous?.dismiss() // one panel at a time; its onClose sees it is no longer current
        cancelPendingActivation()

        let needsActivation = activate && !NSApp.isActive
        // Deep links: always hand focus back when we're done, even if LaunchServices already
        // activated us before this ran. Remember who was in front so we can return to them.
        activatedForPanel = activate
        if activate {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }

        newPanel.onClose = { [weak self, weak newPanel] in
            guard let self, let newPanel, self.panel === newPanel else { return }
            self.panel = nil
            self.panelKind = nil
            self.cancelPendingActivation()
            let byFocusLoss = newPanel.closedByFocusLoss
            if self.activatedForPanel, !byFocusLoss {
                // Hand focus back to the app the user came from.
                NSApp.hide(nil)
                self.previousApp?.activate()
            }
            self.activatedForPanel = false
            self.previousApp = nil
        }

        // Defer so a closing MenuBarExtra menu doesn't immediately steal key status back.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel === newPanel else { return }
            guard needsActivation else {
                if activate { NSApp.activate() }
                newPanel.present()
                return
            }
            // Present only once activation has landed, so it can't take key status away afterwards.
            self.activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.presentPending(newPanel) }
            }
            NSApp.activate()
            Task { @MainActor [weak self] in // fallback if activation never reports
                try? await Task.sleep(for: .milliseconds(500))
                self?.presentPending(newPanel)
            }
        }
    }

    private func presentPending(_ pending: FloatingPanel) {
        guard panel === pending, !pending.isVisible else { return }
        cancelPendingActivation()
        pending.present()
    }

    private func cancelPendingActivation() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// A store on a brand-new `ModelContainer`, so every modal starts from what is on disk now —
    /// including changes the widget extension made from its own process (e.g. completed todos).
    /// When the store can't be opened, shows an error panel instead of silently doing nothing.
    private func freshStore(activate: Bool = false) -> TodoStore? {
        do {
            return try TodoStore.shared()
        } catch {
            log.error("Could not open store: \(error, privacy: .public)")
            showError(
                title: "Can't open Howy's data",
                message: "The shared data store isn't available (\(error.localizedDescription)). "
                    + "Try rebuilding or reinstalling Howy.",
                activate: activate
            )
            return nil
        }
    }

    /// Purge with no UI on failure.
    private func quietStore() -> TodoStore? {
        do { return try TodoStore.shared() } catch {
            log.error("Could not open store: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: Archive purge

    private func purgeArchive() {
        guard let store = quietStore() else { return }
        do {
            let removed = try store.purgeArchive(retention: .load())
            if removed > 0 { log.info("Purged \(removed) archived todos") }
        } catch {
            log.error("Purge failed: \(error, privacy: .public)")
        }
    }

    // MARK: Settings

    func showSettings() {
        closePanel()
        settingsWindow.show(controller: self)
    }

    /// KeyboardShortcuts stores a name's default on first launch, so early installs kept the old
    /// ⌃⌥⇧⌘H browse default after it moved to M. Reset that once; a shortcut the user recorded
    /// later is left alone.
    private func migrateBrowseShortcut() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didMigrateBrowseShortcutKey) else { return }
        defaults.set(true, forKey: Self.didMigrateBrowseShortcutKey)
        let oldDefault = KeyboardShortcuts.Shortcut(.h, modifiers: [.control, .option, .shift, .command])
        if KeyboardShortcuts.getShortcut(for: .browse) == oldDefault {
            KeyboardShortcuts.reset(.browse)
        }
    }

    // MARK: Launch at login

    /// Re-reads the login item state (it can change in System Settings).
    func refreshLaunchesAtLogin() {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .requiresApproval { try service.register() }
            } else {
                try service.unregister()
            }
        } catch {
            log.error("Login item change failed: \(error, privacy: .public)")
        }
        if enabled, service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refreshLaunchesAtLogin()
    }

    private func registerLoginItemOnFirstLaunch() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.didRegisterLoginItemKey) {
            if SMAppService.mainApp.status == .enabled {
                defaults.set(true, forKey: Self.didRegisterLoginItemKey)
            } else {
                do {
                    try SMAppService.mainApp.register()
                    defaults.set(true, forKey: Self.didRegisterLoginItemKey) // only after success: failures retry
                } catch {
                    log.error("Login item registration failed: \(error, privacy: .public)")
                }
            }
        }
        refreshLaunchesAtLogin()
    }
}
