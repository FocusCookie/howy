import AppKit
import HowyCore
import KeyboardShortcuts
import os
import ServiceManagement
import SwiftUI

let log = Logger(subsystem: "lueddemann.howy", category: "app")

/// Owns the global shortcuts, the single modal panel, archive purging, the launch cleanups and
/// daily backup, the login item, and the app's side of iCloud sync (`SyncMonitor`, the shared
/// archive retention).
///
/// **Sync gate.** The cleanups, the backup and the purge ask `SyncGate` first (through
/// `syncMonitor`). While it is closed they are deferred, not dropped: `deferredMaintenance` and
/// `deferredPurge` remember them, and they are tried again on every sync event, on a key-value
/// store change, and at the date the gate names (`recheck`).
@MainActor
@Observable
final class AppController {
    static let shared = AppController()

    private(set) var launchesAtLogin = false
    /// One launcher shortcut, or separate Quick Add and Browse shortcuts (Settings).
    private(set) var shortcutMode = ShortcutMode.load()
    /// How big the panels are drawn (⌘+ / ⌘- / ⌘0 in a panel, the Settings slider). One value for
    /// all panels, saved on every change and applied to an open panel right away.
    private(set) var panelZoom = PanelZoom.load()

    /// `browseCreate`: the create screen `n` opens from Browse's list. Like `edit`, the Quick Add
    /// hotkey replaces it (its draft stashed first) instead of toggling it closed.
    private enum PanelKind { case launcher, quickEntry, browseCreate, edit, archive, browse, error }

    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var panelKind: PanelKind?
    @ObservationIgnored private var activatedForPanel = false
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var purgeTimer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var dayChangeObserver: NSObjectProtocol?
    /// The running cleanups/backup. A call that arrives meanwhile is not dropped: it sets
    /// `rerunMaintenance` (and `pendingCleanups` if it asked for the cleanups), and one more
    /// run starts when this one ends.
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var rerunMaintenance = false
    @ObservationIgnored private var pendingCleanups = false
    /// Maintenance the sync gate held back: `nil` for none, else whether it included the cleanups.
    @ObservationIgnored private var deferredMaintenance: Bool?
    /// An archive purge the sync gate held back.
    @ObservationIgnored private var deferredPurge = false
    /// The pending re-check of deferred work at a date the gate named, and that date.
    @ObservationIgnored private var recheck: Task<Void, Never>?
    @ObservationIgnored private var recheckDate: Date?
    @ObservationIgnored private var keyValueObserver: NSObjectProtocol?
    /// The open Browse or Archive panel's model, refreshed when the store changes elsewhere.
    @ObservationIgnored private weak var browseModel: BrowseModel?
    @ObservationIgnored private weak var archiveModel: ArchiveModel?
    @ObservationIgnored private let lastUsed = UserDefaultsLastQuadrantStore()
    @ObservationIgnored private let drafts = UserDefaultsDraftStore()
    /// Fetches a pasted link's page title for the link dialog.
    @ObservationIgnored private let linkTitles = WebPageTitleLookup()
    @ObservationIgnored private let settingsWindow = SettingsWindowController()
    @ObservationIgnored private let transferWindow = TransferWindowController()

    private static let didRegisterLoginItemKey = "didRegisterLoginItem"
    private static let didMigrateBrowseShortcutKey = "didMigrateBrowseShortcutToM"
    private static let panelWidth: CGFloat = 560

    /// The shared store's CloudKit mirroring as the app sees it (Phase 3c shows it in Settings).
    let syncMonitor = SyncMonitor(mode: .iCloud)
    /// The archive retention, shared through the iCloud key-value store.
    let retention: ArchiveRetentionStore

    private init() {
        let keyValueStore = NSUbiquitousKeyValueStore.default
        // `false`: no key-value store (e.g. no entitlement); the local value is the one.
        let cloud: NSUbiquitousKeyValueStore? = keyValueStore.synchronize() ? keyValueStore : nil
        if cloud == nil { log.notice("iCloud key-value store unavailable; archive retention stays local") }
        retention = ArchiveRetentionStore(local: UserDefaults.standard, cloud: cloud, now: .now)
    }

    /// Chooses how the shared store syncs. Called from `HowyApp.init()`, the first app code to
    /// run: a `howy://` URL that launches the app reaches `application(_:open:)` (and so
    /// `freshStore()`) before `applicationDidFinishLaunching`, and the container is built
    /// once with whatever setting it finds. The app is the one process that may mirror the store
    /// to CloudKit; the widget extension never calls this and stays `.local`.
    ///
    /// The mirroring events are observed from here on, before the container exists, so the
    /// first setup event isn't missed.
    static func configureStoreSync() {
        shared.syncMonitor.startObserving()
        let accepted = TodoStore.configureSharedSync(.iCloud(containerIdentifier: StoreSync.containerIdentifier))
        assert(accepted, "The shared store was opened before its sync setting was chosen")
        if !accepted { log.fault("Shared store sync was configured after the store was opened") }
    }

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
        // The notification delegate must be in place before launching finishes.
        NotificationCoordinator.shared.start { [weak self] id in self?.showEdit(id: id, activate: true) }
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.purgeArchive()
                NotificationCoordinator.shared.requestSync()
            }
        }
        purgeTimer?.tolerance = 60 * 60
        // Timers don't advance while the Mac sleeps, so also purge (and catch up on due dates
        // that passed meanwhile) on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.purgeArchive()
                NotificationCoordinator.shared.requestSync()
                self?.runMaintenance(cleanups: false)
            }
        }
        // A new day while Howy runs: that day's backup.
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runMaintenance(cleanups: false) }
        }
        startSync()
        // Keep the hotkey responsive: the slow launch work (login item, store open) runs after launch.
        Task { @MainActor [weak self] in
            self?.registerLoginItemOnFirstLaunch()
            self?.openStoreAndReportSync()
            self?.purgeArchive()
            self?.collectStagedAttachments()
            self?.runMaintenance(cleanups: true)
        }
    }

    // MARK: Sync

    /// Wires the sync events, the key-value store and the widget's writes to the refreshes and
    /// the deferred maintenance.
    private func startSync() {
        syncMonitor.onImport = { [weak self] in self?.storeChangedRemotely() }
        syncMonitor.onChange = { [weak self] in self?.retryDeferredWork() }
        keyValueObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retention.cloudChanged()
                self?.retryDeferredWork()
            }
        }
        // The widget's checkbox writes from its own process; the open panel reads again.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in AppController.shared.refreshOpenPanel() }
            },
            StoreChangeSignal.extensionName as CFString, nil, .deliverImmediately
        )
    }

    /// Builds the shared container (if no deep link did yet) and tells the monitor how it really
    /// opened: mirroring, or local after the CloudKit build failed.
    private func openStoreAndReportSync() {
        guard quietStore() != nil else { return }
        let reason = TodoStore.sharedSyncFallbackReason
        syncMonitor.setMode(SyncMonitor.mode(sync: TodoStore.sharedSync, fallbackReason: reason))
        if let reason { log.error("Sync unavailable: \(reason, privacy: .public)") }
    }

    /// A sync import finished: the widgets, the due-date notifications and an open panel show
    /// the new data, and the cleanups run once the gate opens.
    private func storeChangedRemotely() {
        TodoStore.reloadWidgetTimelines()
        NotificationCoordinator.shared.requestSync()
        refreshOpenPanel()
        runMaintenance(cleanups: true)
        purgeArchive()
    }

    /// Re-reads the store into an open Browse or Archive panel. An edit or create screen is left
    /// alone: the user is typing there.
    func refreshOpenPanel() {
        guard panel != nil else { return }
        switch panelKind {
        case .browse:
            guard let browseModel, let store = quietStore() else { return }
            browseModel.refresh(using: store)
        case .archive:
            guard let archiveModel, let store = quietStore() else { return }
            archiveModel.refresh(using: store)
        default:
            break
        }
    }

    private func gate(_ work: MaintenanceWork) -> SyncGate.Decision {
        syncMonitor.gate(work, retentionKnown: retention.isKnown)
    }

    /// Runs deferred maintenance and purges whose gate may have opened.
    private func retryDeferredWork() {
        retention.tick(now: .now)
        if deferredPurge {
            deferredPurge = false
            purgeArchive()
        }
        if let cleanups = deferredMaintenance {
            deferredMaintenance = nil
            runMaintenance(cleanups: cleanups)
        }
    }

    /// Plans a retry for a closed gate: at the date it names, or when the retention decides on
    /// its own. Waiting for sync needs no timer: the next sync event retries.
    private func scheduleRetry(after decision: SyncGate.Decision) {
        let date: Date? = switch decision {
        case .waitUntil(let date): date
        case .waitForRetention: retention.decisionDeadline
        case .open, .waitForSync: nil
        }
        guard let date else { return }
        if let recheckDate, recheckDate <= date, recheck != nil { return }
        recheck?.cancel()
        recheckDate = date
        recheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(date.timeIntervalSinceNow, 0) + 0.5))
            guard !Task.isCancelled, let self else { return }
            recheck = nil
            recheckDate = nil
            retryDeferredWork()
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

    // MARK: Panel zoom

    /// Sets the panel zoom (the Settings slider), saves it and applies it to the open panel.
    func setPanelZoom(_ zoom: PanelZoom) {
        guard zoom != panelZoom else { return }
        panelZoom = zoom
        zoom.save()
        panel?.setScale(zoom.scale)
    }

    /// ⌘+ / ⌘= / ⌘- / ⌘0 in a panel. Beeps when the zoom is already at that end (⌘0 at 100 % just
    /// does nothing: there is no limit to hit).
    private func handleZoomKey(_ key: QuickEntryKey) {
        var zoom = panelZoom
        switch key {
        case .zoomIn: if !zoom.zoomIn() { NSSound.beep() }
        case .zoomOut: if !zoom.zoomOut() { NSSound.beep() }
        case .zoomReset: zoom.reset()
        default: return
        }
        setPanelZoom(zoom)
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
        // Only a quick-entry panel toggles closed; an edit, Browse create or archive panel is
        // replaced by Quick Add.
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
        let flow = BrowseFlow(todos: todos, dueDates: .live())
        if let back { flow.resume(at: back) }
        if fromArchive { flow.highlightArchive() }
        let model = BrowseModel(flow: flow, store: store)
        browseModel = model
        let panel = present(.browse, activate: activate) { BrowseView(model: model) }
        panel.keyHandler = { event in
            guard let key = QuickEntryKey(event: event) else { return false }
            return model.handle(key)
        }
        model.close = { [weak self, weak panel] in
            if viaLauncher { self?.showLauncher(highlighting: .browse) } else { panel?.dismiss() }
        }
        model.openTodo = { [weak self, weak flow] id in
            self?.showEdit(id: id, returningTo: flow?.returnPoint(opening: id, viaLauncher: viaLauncher))
        }
        model.createTodo = { [weak self, weak flow] quadrant in
            guard let flow else { return }
            self?.showCreate(in: quadrant, returningTo: flow.returnPoint(viaLauncher: viaLauncher))
        }
        model.openArchive = { [weak self] in
            self?.showArchive(returning: { [weak self] in
                self?.showBrowse(resuming: nil, viaLauncher: viaLauncher, fromArchive: true)
            })
        }
        model.resizeForOverview = { [weak panel] expanded, animated, changes, completion in
            guard let panel else { changes(); completion(); return }
            panel.setOverview(expanded ? OverviewSize.load() : nil, animated: animated, changes: changes, completion: completion)
        }
        model.makeTileEditor = { [weak self, weak panel, weak model] kind in
            guard let model else { return nil }
            return self?.makeTileEditor(kind, store: model.store, panel: panel)
        }
        // Focus loss, ⌘W or another screen: an open tile edit is kept as a draft.
        panel.willClose = { model.stashTileEditor() }
    }

    /// The editor inside an Overview tile, in the Browse panel: the edit screen's flow and model
    /// for a todo, or the create screen's for a new todo in the tile's quadrant (`n`).
    private func makeTileEditor(
        _ kind: BrowseFlow.TileEditor, store: TodoStore, panel: FloatingPanel?
    ) -> QuickEntryModel? {
        let flow: QuickEntryFlow
        switch kind {
        case .edit(let id):
            guard let todo = try? store.todo(id: id), todo.completedAt == nil else { return nil }
            flow = QuickEntryFlow(
                mode: .edit(QuickEntryDraft(todo: todo, attachments: store.attachmentList(for: id))),
                lastUsed: lastUsed, drafts: drafts, linkTitles: linkTitles, dueDates: .live()
            )
        case .create(let quadrant):
            flow = createFlow(in: quadrant)
        }
        let model = QuickEntryModel(flow: flow, store: store)
        model.escapeReturns = true // back to the tile's list
        if let panel {
            model.presenter = AttachmentPresenter(panel: panel) { [weak self] in self?.activateForPanel() }
        }
        model.didFinish = { [weak self] in self?.collectStagedAttachments() }
        return model
    }

    /// With `viaLauncher`, Esc returns to the launcher (keeping the draft) instead of closing.
    /// With `startingInTitle`, the modal opens on the title field instead of the picker — for the
    /// menu bar's "Add to Quadrant", where the quadrant was already chosen.
    func showQuickEntry(
        preselected: Quadrant? = nil, startingInTitle: Bool = false,
        viaLauncher: Bool = false, activate: Bool = false
    ) {
        guard let store = freshStore(activate: activate) else { return }
        // A create screen or tile editor being replaced stashes its text now, so this flow
        // restores it (the shared create draft) instead of the one stashed before.
        stashOpenDraft()
        let flow = QuickEntryFlow(
            mode: .create(preselected: preselected, startingInTitle: startingInTitle),
            lastUsed: lastUsed, drafts: drafts,
            startQuadrant: NewTodoQuadrant.load(), linkTitles: linkTitles, dueDates: .live()
        )
        let model = QuickEntryModel(flow: flow, store: store)
        model.escapeReturns = viaLauncher
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

    /// A create flow for a new todo in a quadrant chosen in Browse, starting in the title. The
    /// quadrant wins over the "New todo starts in" setting and over the stashed draft's quadrant;
    /// the draft's text is restored.
    private func createFlow(in quadrant: Quadrant) -> QuickEntryFlow {
        QuickEntryFlow(
            mode: .create(preselected: quadrant, startingInTitle: true),
            lastUsed: lastUsed, drafts: drafts,
            startQuadrant: NewTodoQuadrant.load(), linkTitles: linkTitles, dueDates: .live()
        )
    }

    /// `n` in Browse's list: the create screen for a new todo in that quadrant. Save returns to
    /// Browse listing the quadrant it was saved into, with the new todo selected; Esc returns to
    /// `back` (the draft is stashed); losing focus still closes.
    private func showCreate(in quadrant: Quadrant, returningTo back: BrowseReturn) {
        guard let store = freshStore() else { return }
        stashOpenDraft()
        let model = QuickEntryModel(flow: createFlow(in: quadrant), store: store)
        model.escapeReturns = true
        presentQuickEntry(model, kind: .browseCreate, activate: false)
        model.close = { [weak self, weak model] in
            guard let self, let model else { return }
            self.showBrowse(resuming: back.afterCreate(model.createdTodoID, savedInto: model.flow.savedDraft?.quadrant))
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
            lastUsed: lastUsed, drafts: drafts, linkTitles: linkTitles, dueDates: .live()
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
        purgeArchive(using: store)
        let model = ArchiveModel(store: store)
        archiveModel = model
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

    /// Runs the open screen's `willClose` now (stashing its draft) instead of when it is replaced,
    /// for a screen about to read the drafts.
    private func stashOpenDraft() {
        panel?.willClose?()
        panel?.willClose = nil
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
        let newPanel = FloatingPanel(width: Self.panelWidth, scale: panelZoom.scale, content: content)
        newPanel.zoomHandler = { [weak self] key in self?.handleZoomKey(key) }
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

    /// A store with a brand-new `ModelContext` on the process's one container, so every modal
    /// starts from what is on disk now — including changes the widget extension made from its
    /// own process (e.g. completed todos). When the store can't be opened, shows an error panel
    /// instead of silently doing nothing.
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

    /// Purges the archive with the shared retention, if the sync gate allows; otherwise defers it.
    private func purgeArchive(using given: TodoStore? = nil) {
        let decision = gate(.purge)
        guard decision.isOpen else {
            deferredPurge = true
            scheduleRetry(after: decision)
            return
        }
        guard let store = given ?? quietStore() else { return }
        do {
            let removed = try store.purgeArchive(retention: retention.retention)
            if removed > 0 { log.info("Purged \(removed) archived todos") }
        } catch {
            log.error("Purge failed: \(error, privacy: .public)")
        }
    }

    // MARK: Cleanups and backups

    /// At launch and after each sync import (`cleanups`): removes duplicate todos and events and
    /// deleted todos that came back, writes the day's backup, then moves orphaned attachment
    /// folders to the trash (the backup comes first, so a store that went wrong is backed up
    /// before anything is touched). On a day change or wake: the backup alone, and only if
    /// today's isn't complete yet, checked before any store is opened. The store work runs on a
    /// background context and the file work off the main actor.
    ///
    /// Everything waits for the sync gate (`SyncGate`); a closed gate defers the run, and a gate
    /// that closes between steps defers the rest.
    ///
    /// Only one run at a time. A call during a run is coalesced: when the run ends, one more
    /// starts, with the cleanups if any of the swallowed calls asked for them.
    private func runMaintenance(cleanups: Bool) {
        if deferMaintenance(cleanups: cleanups) { return }
        guard maintenance == nil else {
            pendingCleanups = pendingCleanups || cleanups
            rerunMaintenance = true
            return
        }
        maintenance = Task { @MainActor [weak self] in
            await self?.performMaintenance(cleanups: cleanups)
            guard let self else { return }
            maintenance = nil
            if rerunMaintenance {
                let again = pendingCleanups
                rerunMaintenance = false
                pendingCleanups = false
                runMaintenance(cleanups: again)
            }
        }
    }

    /// Defers the run when the gate is closed for any of its work; returns whether it did.
    private func deferMaintenance(cleanups: Bool) -> Bool {
        let work: [MaintenanceWork] = cleanups ? [.cleanups, .backup] : [.backup]
        guard let closed = work.lazy.map(gate).first(where: { !$0.isOpen }) else { return false }
        deferredMaintenance = (deferredMaintenance ?? false) || cleanups
        scheduleRetry(after: closed)
        return true
    }

    private func performMaintenance(cleanups: Bool) async {
        let directory: URL
        do {
            directory = try DailyBackup.sharedDirectory()
        } catch {
            log.error("Backup directory unavailable: \(error, privacy: .public)")
            return
        }
        // The common case on wake and day change: today's backup exists. Build no container.
        if !cleanups, await DailyBackup.isTodayComplete(in: directory, at: .now) { return }
        guard let store = quietStore() else { return }
        if cleanups {
            do {
                let removed = try await store.removeDuplicates()
                if !removed.isEmpty {
                    log.notice("Removed \(removed.removedTodos) duplicate todos and \(removed.removedEvents) duplicate events")
                }
            } catch {
                log.error("Duplicate cleanup failed: \(error, privacy: .public)")
            }
            if deferMaintenance(cleanups: true) { return }
            do {
                let removed = try await store.removeDeletedTodos()
                if !removed.isEmpty { log.notice("Removed \(removed.count) deleted todos that came back") }
            } catch {
                log.error("Deleted-todo cleanup failed: \(error, privacy: .public)")
            }
        }
        if deferMaintenance(cleanups: cleanups) { return }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let backup = DailyBackup(store: store, directory: directory, appVersion: version)
            if case .created(let folder) = try await backup.run() {
                log.info("Backed up to \(folder.lastPathComponent, privacy: .public)")
            }
        } catch {
            log.error("Backup failed: \(error, privacy: .public)")
        }
        if cleanups {
            if deferMaintenance(cleanups: true) { return }
            do {
                let moved = try await store.removeOrphanedAttachments()
                if moved > 0 { log.notice("Moved attachments of \(moved) deleted todos to the trash") }
            } catch {
                log.error("Orphan cleanup failed: \(error, privacy: .public)")
            }
        }
    }

    /// Settings → Show in Finder: the daily backups' folder (created if no backup exists yet).
    func showBackupsInFinder() {
        do {
            let directory = try DailyBackup.sharedDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            log.error("Can't show backups: \(error, privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: Import and export

    /// Export… in the menu: every todo and attachment into a folder the user picks.
    func exportAll() {
        closePanel()
        guard let store = freshStore(activate: true) else { return }
        transferWindow.export(store: store)
    }

    /// Import… in the menu: an export folder, merged in by id after a preview.
    func importFolder() {
        closePanel()
        guard let store = freshStore(activate: true) else { return }
        transferWindow.importFolder(store: store)
    }

    // MARK: Settings

    /// A retention chosen in Settings: shared through iCloud, then purged with.
    func setArchiveRetention(_ value: ArchiveRetention) {
        guard value != retention.retention || !retention.isKnown else { return }
        retention.set(value)
        purgeArchive()
    }

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
