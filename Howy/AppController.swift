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
///
/// **Account and notices.** `syncMonitor` reads the iCloud account at launch, on
/// `CKAccountChanged` and on wake, and checks the "failing for over an hour" rule every 5 minutes
/// (with the import nudge). The notices it raises go to `NotificationCoordinator`; a click on
/// one opens Settings with the sync line highlighted (`showSyncSettings()`).
@MainActor
@Observable
final class AppController {
    static let shared = AppController()

    private(set) var launchesAtLogin = false
    /// How big the panels are drawn (⌘+ / ⌘- / ⌘0 in a panel, the Settings slider). One value for
    /// all panels, saved on every change and applied to an open panel right away.
    private(set) var panelZoom = PanelZoom.load()

    /// `create`: the editor for a new todo (N in Browse, "Add to Quadrant", a widget's quadrant label).
    private enum PanelKind { case create, edit, archive, browse, error }

    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var panelKind: PanelKind?
    @ObservationIgnored private var activatedForPanel = false
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var purgeTimer: Timer?
    @ObservationIgnored private var importNudgeTimer: Timer?
    /// When `nudgeImport()` last posted (Core Data throttles too; this keeps the posts rare).
    @ObservationIgnored private var lastImportNudge = Date.distantPast
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
    /// The debounced reaction to sync imports (1 s), so a burst of imports reacts once.
    @ObservationIgnored private var importReaction: Task<Void, Never>?
    /// Holds the cleanups back to once per 10 minutes.
    @ObservationIgnored private var cleanupThrottle = CleanupThrottle()
    /// Per kind of work: how long its gate has been closed, to log a fault when it stays closed.
    @ObservationIgnored private var stuckWatches: [MaintenanceWork: StuckGateWatch] = [:]
    /// The open Browse or Archive panel's model, refreshed when the store changes elsewhere.
    @ObservationIgnored private weak var browseModel: BrowseModel?
    @ObservationIgnored private weak var archiveModel: ArchiveModel?
    /// The quadrant last opened in Browse or saved into, where a fresh Browse grid starts.
    @ObservationIgnored private let lastUsed = UserDefaultsLastQuadrantStore()
    @ObservationIgnored private let drafts = UserDefaultsDraftStore()
    /// Fetches a pasted link's page title for the link dialog.
    @ObservationIgnored private let linkTitles = WebPageTitleLookup()
    @ObservationIgnored private let settingsWindow = SettingsWindowController()
    @ObservationIgnored private let transferWindow = TransferWindowController()

    private static let didRegisterLoginItemKey = "didRegisterLoginItem"
    private static let panelWidth: CGFloat = 560

    /// The shared store's CloudKit mirroring and the iCloud account as the app sees them (the
    /// Settings status line, the sync notices). The remembered account and the notice cooldown
    /// live in this Mac's `UserDefaults`, outside the synced store.
    let syncMonitor = SyncMonitor(mode: .starting, defaults: UserDefaults.standard)
    /// When Settings was last asked to highlight the sync line (a click on a sync notice).
    private(set) var syncLineHighlightRequest: Date?
    /// The archive retention, shared through the iCloud key-value store.
    let retention: ArchiveRetentionStore

    private init() {
        let keyValueStore = NSUbiquitousKeyValueStore.default
        // Observe before `synchronize()`: a change that arrives while it runs must not be missed.
        // The notification is delivered on the main queue after this initialiser has returned.
        let observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: keyValueStore, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppController.shared.keyValueStoreChanged() }
        }
        // `false`: no key-value store (e.g. no entitlement); the local value is the one.
        let cloud: NSUbiquitousKeyValueStore? = keyValueStore.synchronize() ? keyValueStore : nil
        if cloud == nil { log.notice("iCloud key-value store unavailable; archive retention stays local") }
        retention = ArchiveRetentionStore(local: UserDefaults.standard, cloud: cloud, now: .now)
        keyValueObserver = observer
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
        // Without a proper store file name (Info.plist `HowyStoreFileName`) the store would be
        // `Howy.store`, whatever the configuration: stay local rather than mirror the wrong file.
        guard TodoStore.hasValidStoreFileName else {
            assertionFailure("HowyStoreFileName is missing or invalid in Info.plist; sync stays off")
            log.fault("HowyStoreFileName is missing or invalid in Info.plist; the store stays local")
            return
        }
        let accepted = TodoStore.configureSharedSync(.iCloud(containerIdentifier: StoreSync.containerIdentifier))
        assert(accepted, "The shared store was opened before its sync setting was chosen")
        if !accepted { log.fault("Shared store sync was configured after the store was opened") }
    }

    func start() {
        // Before anything reads the Open Howy name, which stores its default when it has none.
        let migration = OpenHowyShortcutMigration.run()
        if migration != .alreadyDone { log.notice("Open Howy shortcut migration: \(String(describing: migration), privacy: .public)") }
        ShortcutRecorderModel.removeFunctionModifier()
        KeyboardShortcuts.onKeyUp(for: .openHowy) { [weak self] in
            MainActor.assumeIsolated { self?.toggleOpenHowy() }
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        // The notification delegate must be in place before launching finishes.
        NotificationCoordinator.shared.start(
            openTodo: { [weak self] id in self?.showEdit(id: id, activate: true) },
            openSyncSettings: { [weak self] in self?.showSyncSettings() }
        )
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.purgeArchive()
                NotificationCoordinator.shared.requestSync()
            }
        }
        purgeTimer?.tolerance = 60 * 60
        importNudgeTimer = Timer.scheduledTimer(withTimeInterval: Self.importNudgeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.nudgeImport()
                self?.syncMonitor.tick()
            }
        }
        importNudgeTimer?.tolerance = 60
        // Timers don't advance while the Mac sleeps, so also purge (and catch up on due dates
        // that passed meanwhile) on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // What arrived during sleep isn't imported yet: only an import that starts now
                // counts for the destructive work, which the purge asks the gate about.
                self?.syncMonitor.noteWake()
                self?.syncMonitor.checkAccount()
                self?.nudgeImport()
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
            await self?.prepareStore()
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
        syncMonitor.onAlert = { alert in NotificationCoordinator.shared.post(alert) }
        syncMonitor.onBackOnline = { [weak self] in self?.nudgeImport() }
        // Only a build that mirrors (a valid store file name) has an account worth watching.
        if TodoStore.hasValidStoreFileName {
            syncMonitor.startAccountChecks(containerIdentifier: StoreSync.containerIdentifier)
            syncMonitor.startNetworkChecks()
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

    /// The key-value store changed from outside (another Mac, the first download).
    private func keyValueStoreChanged() {
        retention.cloudChanged()
        retryDeferredWork()
    }

    /// Builds the shared container off the main actor (migration, preparation for the first
    /// mirroring, CloudKit setup). A failure is reported when the store is opened next.
    private func prepareStore() async {
        do {
            try await TodoStore.prepareSharedContainer()
        } catch {
            log.error("Could not prepare the store: \(error, privacy: .public)")
        }
    }

    /// Opens the shared store (building the container if nothing did yet), which also tells the
    /// monitor what it really is.
    private func openStoreAndReportSync() {
        guard quietStore() != nil else { return }
        if let reason = TodoStore.sharedSyncFallbackReason { log.error("Sync unavailable: \(reason, privacy: .public)") }
    }

    /// The shared store, and the sync mode taken from the container that was really built (the
    /// CloudKit fallback included), never from what was asked for.
    private func sharedStore() throws -> TodoStore {
        let store = try TodoStore.shared()
        syncMonitor.setMode(TodoStore.sharedSyncMode)
        return store
    }

    /// A sync import finished. The reaction is debounced by a second: a burst of imports (the
    /// first sync on a new Mac) reacts once, after the last one.
    private func storeChangedRemotely() {
        importReaction?.cancel()
        importReaction = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            importReaction = nil
            reactToImport()
        }
    }

    /// The widgets, the due-date notifications and an open panel show the new data, and the
    /// cleanups and the purge run once their gates open (the cleanups at most every 10 minutes).
    private func reactToImport() {
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
        let decision = syncMonitor.gate(work, retentionKnown: retention.isKnown)
        // The retention can legitimately stay unknown for a day on a fresh Mac; that isn't stuck sync.
        if decision != .waitForRetention {
            var watch = stuckWatches[work] ?? StuckGateWatch()
            if watch.note(decision, at: .now) {
                log.fault("The sync gate for \(String(describing: work), privacy: .public) has stayed closed for over \(Int(StuckGateWatch.threshold / 60)) minutes (\(String(describing: decision), privacy: .public)); maintenance is not running")
            }
            stuckWatches[work] = watch
        }
        return decision
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

    /// Plans a retry for a closed gate: at the date it names, when the retention decides on its
    /// own, or, while it waits for sync, every `SyncGate.retryInterval` (an event that is never
    /// followed by another must not leave the work waiting for good; every ask also feeds the
    /// stuck-gate log).
    private func scheduleRetry(after decision: SyncGate.Decision) {
        let date: Date? = switch decision {
        case .waitUntil(let date): date
        case .waitForRetention: retention.decisionDeadline
        case .waitForSync: Date.now.addingTimeInterval(SyncGate.retryInterval)
        case .open: nil
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
        case .quickAdd(let quadrant?): showCreate(in: quadrant, activate: true)
        case .quickAdd(nil): showBrowse(activate: true)
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

    /// Closes whatever panel is open (its draft is stashed like on any close without saving).
    func closePanel() {
        panel?.dismiss()
    }

    /// The Open Howy shortcut: opens Browse's quadrant grid, or, with any panel open, closes Howy
    /// from whatever screen it shows, like ⌘W (an unsaved todo is kept as a draft).
    func toggleOpenHowy() {
        if panel != nil { closePanel() } else { showBrowse() }
    }

    func showBrowse(activate: Bool = false) {
        showBrowse(resuming: nil, activate: activate)
    }

    /// `fromArchive` reopens the picker with the Archive button highlighted (Esc in the archive).
    private func showBrowse(resuming back: BrowseReturn?, fromArchive: Bool = false, activate: Bool = false) {
        guard let store = freshStore(activate: activate) else { return }
        let todos: [Quadrant: [TodoSnapshot]]
        do {
            todos = try store.openSnapshots()
        } catch {
            log.error("Browse fetch failed: \(error, privacy: .public)")
            showError(title: "Can't read Howy's data", message: error.localizedDescription, activate: activate)
            return
        }
        let flow = BrowseFlow(todos: todos, lastOpened: lastUsed, dueDates: .live())
        if let back { flow.resume(at: back) }
        if fromArchive { flow.highlightArchive() }
        let model = BrowseModel(flow: flow, store: store)
        browseModel = model
        let panel = present(.browse, activate: activate) { BrowseView(model: model) }
        panel.keyHandler = { event in
            guard let key = QuickEntryKey(event: event) else { return false }
            return model.handle(key)
        }
        model.close = { [weak panel] in panel?.dismiss() }
        model.openTodo = { [weak self, weak flow] id in
            self?.showEdit(id: id, returningTo: flow?.returnPoint(opening: id))
        }
        model.createTodo = { [weak self, weak flow] quadrant in
            guard let flow else { return }
            self?.showCreate(in: quadrant, returningTo: flow.returnPoint())
        }
        model.openArchive = { [weak self] in
            self?.showArchive(returning: { [weak self] in
                self?.showBrowse(resuming: nil, fromArchive: true)
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

    /// A create flow for a new todo in a chosen quadrant, starting in the title. The quadrant wins
    /// over the stashed draft's quadrant; the draft's text is restored.
    private func createFlow(in quadrant: Quadrant) -> QuickEntryFlow {
        QuickEntryFlow(
            mode: .create(quadrant), lastUsed: lastUsed, drafts: drafts, linkTitles: linkTitles, dueDates: .live()
        )
    }

    /// The editor for a new todo in `quadrant`, straight away ("Add to Quadrant", a widget's
    /// quadrant label): save and Esc close the panel (Esc keeps the draft).
    func showCreate(in quadrant: Quadrant, activate: Bool = false) {
        showCreate(in: quadrant, returningTo: nil, activate: activate)
    }

    /// With `back` (N in Browse): save returns to Browse listing the quadrant it was saved into,
    /// with the new todo selected; Esc returns to `back` (the draft is stashed). Losing focus
    /// still closes.
    private func showCreate(in quadrant: Quadrant, returningTo back: BrowseReturn?, activate: Bool = false) {
        guard let store = freshStore(activate: activate) else { return }
        // A create screen or tile editor being replaced stashes its text now, so this flow
        // restores it (the shared create draft) instead of the one stashed before.
        stashOpenDraft()
        let model = QuickEntryModel(flow: createFlow(in: quadrant), store: store)
        model.escapeReturns = back != nil
        presentQuickEntry(model, kind: .create, activate: activate)
        guard let back else { return }
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
    /// cross-fade, e.g. Browse ↔ edit, Browse → archive), otherwise in a new panel. The caller
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
        // Before the activation observer below exists, so the nudge can't present early.
        nudgeImport()

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

    /// How often `nudgeImport()` runs on its own while Howy is open.
    private static let importNudgeInterval: TimeInterval = 5 * 60

    /// Makes CloudKit mirroring look for changes from other devices, as a safety net for lost
    /// pushes: APNs doesn't guarantee delivery, and a Mac whose push connection is broken would
    /// otherwise only import at launch. Runs when a panel opens, on wake and every 5 minutes.
    ///
    /// Core Data imports when the app becomes active ("AppActivationImport"), but Howy's panels
    /// are non-activating, so it posts that notification itself. It's the only trigger Core Data
    /// offers; Howy's own observers of it (a panel waiting for activation, Settings re-reading the
    /// notification permission) tolerate a spurious one. At most once a minute.
    private func nudgeImport() {
        guard syncMonitor.state.mode == .iCloud, !NSApp.isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastImportNudge) >= 60 else { return }
        lastImportNudge = now
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
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
            return try sharedStore()
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
        do { return try sharedStore() } catch {
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

    /// At launch and after each sync import (`cleanups`): the day's backup first (so a store that
    /// went wrong is backed up before anything is touched), then removes duplicate todos and
    /// events and deleted todos that came back, and moves orphaned attachment folders to the
    /// trash (`MaintenancePlan`). On a day change or wake: the backup alone, and only if today's
    /// isn't complete yet, checked before any store is opened. The store work runs on a
    /// background context and the file work off the main actor.
    ///
    /// Every step asks the sync gate (`SyncGate`) right before it runs: the backup has the
    /// relaxed gate, the cleanups the strict one. A closed gate defers the rest of the run. The
    /// cleanups run at most once per 10 minutes (`CleanupThrottle`); a run asked for sooner does
    /// the backup now and the cleanups at the throttle's date.
    ///
    /// Only one run at a time. A call during a run is coalesced: when the run ends, one more
    /// starts, with the cleanups if any of the swallowed calls asked for them.
    private func runMaintenance(cleanups asked: Bool) {
        var cleanups = asked
        if cleanups, case .wait(let date) = cleanupThrottle.decide(now: .now) {
            cleanups = false
            deferredMaintenance = true
            scheduleRetry(after: .waitUntil(date))
        }
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

    /// Defers the rest of a run whose step is blocked.
    private func deferMaintenance(cleanups: Bool, after decision: SyncGate.Decision) {
        deferredMaintenance = (deferredMaintenance ?? false) || cleanups
        scheduleRetry(after: decision)
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
        for step in MaintenancePlan.steps(cleanups: cleanups) {
            // Asked again before every step: sync may have started meanwhile.
            if let blocked = MaintenancePlan.blocker(for: step, decide: gate) {
                deferMaintenance(cleanups: cleanups, after: blocked)
                return
            }
            if step == .duplicates { cleanupThrottle.didRun(at: .now) }
            await run(step, store: store, backupDirectory: directory)
        }
    }

    private func run(_ step: MaintenanceStep, store: TodoStore, backupDirectory directory: URL) async {
        switch step {
        case .backup:
            do {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                let backup = DailyBackup(store: store, directory: directory, appVersion: version)
                if case .created(let folder) = try await backup.run() {
                    log.info("Backed up to \(folder.lastPathComponent, privacy: .public)")
                }
            } catch {
                log.error("Backup failed: \(error, privacy: .public)")
            }
        case .duplicates:
            do {
                let removed = try await store.removeDuplicates()
                if !removed.isEmpty {
                    log.notice("Removed \(removed.removedTodos) duplicate todos and \(removed.removedEvents) duplicate events")
                }
            } catch {
                log.error("Duplicate cleanup failed: \(error, privacy: .public)")
            }
        case .deletedTodos:
            do {
                let removed = try await store.removeDeletedTodos()
                if !removed.isEmpty { log.notice("Removed \(removed.count) deleted todos that came back") }
            } catch {
                log.error("Deleted-todo cleanup failed: \(error, privacy: .public)")
            }
        case .orphanedAttachments:
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

    /// Settings with the sync line highlighted for a moment (a click on a sync notice).
    func showSyncSettings() {
        syncLineHighlightRequest = .now
        showSettings()
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
