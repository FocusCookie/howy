import CloudKit
import CoreData
import Foundation
import Network
import Observation
import os

/// The app's live `SyncState`: observes the CloudKit mirroring events and answers the
/// `SyncGate` from them. It also watches the iCloud account and turns both into the Settings
/// status line (`status`) and the sync notifications (`onAlert`).
///
/// SwiftData's CloudKit store runs on Core Data's `NSPersistentCloudKitContainer` mirroring,
/// which posts `NSPersistentCloudKitContainer.eventChangedNotification`. The notification's
/// object is that internal container, which SwiftData doesn't expose, so the observation can't be
/// narrowed to Howy's store; there is only one mirroring store per process (`SharedContainer`),
/// so every event is ours.
///
/// The event is read on the posting queue (it isn't `Sendable`), only its plain values
/// (`SyncEvent`) cross to the main actor. Tests call `receive(_:)` directly.
///
/// **Account.** `startAccountChecks(containerIdentifier:)` reads the account at launch and on
/// every `CKAccountChanged` (`AccountObservation.current(in:)`); tests call `receiveAccount(_:)`.
/// The account this Mac's store mirrored with is remembered in `defaults` per store file
/// (`accountKey(storeFileName:)`), outside the synced store, and compared by
/// `SyncAccountTracker` only while the store really mirrors (`.iCloud`): a run that fell back to
/// local wiped nothing, so it leaves the remembered account alone, and an account read before the
/// store is open is compared once it is (`setMode(_:)`).
///
/// **Network.** `startNetworkChecks()` follows the Mac's network path (`NWPathMonitor`); tests
/// call `receiveNetwork(isOnline:)`. While offline the line says so (`SyncStatus`), and
/// `onBackOnline` runs when the network returns.
///
/// **Low Power Mode.** `startLowPowerModeChecks()` reads `ProcessInfo.isLowPowerModeEnabled` and
/// follows `NSProcessInfoPowerStateDidChange`; tests call `receiveLowPowerMode(_:)`.
/// While it is on, macOS delays silent pushes and background work, so sync may come late:
/// `statusHint` says so under the line (`SyncStatus.hint(lowPowerMode:)`), and turning it on
/// notifies (`SyncIncidents.lowPowerModeChanged`: off → on only, so not at launch when it is
/// already on, and only while the store mirrors with a signed-in account). Turning it off hands
/// the notice to `onAlertResolved`, which withdraws it.
///
/// **Notifications.** Events and account changes go through `SyncIncidents` (the CKError matrix,
/// once per incident, over an hour); what it returns is handed to `onAlert`. `tick()` checks the
/// "over an hour" rule between events. When each kind was last posted is saved in `defaults`, so
/// the cooldown survives a relaunch.
@MainActor
@Observable
public final class SyncMonitor {
    public private(set) var state: SyncState
    /// The iCloud account as last read; `nil` until the first check returns.
    public private(set) var account: AccountObservation?
    /// Whether the Mac has a network path; `true` until a check says otherwise.
    public private(set) var isOnline = true
    /// Whether Low Power Mode is on; `false` until the first reading.
    public private(set) var isLowPowerMode = false
    /// Whether Low Power Mode was read at all (the first reading is the launch's, it never notifies).
    @ObservationIgnored private var lowPowerModeKnown = false
    @ObservationIgnored private var powerStateObserver: (any NSObjectProtocol)?
    /// The network came back after being offline: check for changes.
    @ObservationIgnored public var onBackOnline: () -> Void = {}
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// After an import finished successfully: reload what shows the data.
    @ObservationIgnored public var onImport: () -> Void = {}
    /// After every event (and a mode change): check the deferred maintenance again.
    @ObservationIgnored public var onChange: () -> Void = {}
    /// A sync notification to post (once per incident; see `SyncIncidents`).
    @ObservationIgnored public var onAlert: (SyncAlert) -> Void = { _ in }
    /// A notice no longer applies (Low Power Mode turned off): the app withdraws it.
    @ObservationIgnored public var onAlertResolved: (SyncAlert) -> Void = { _ in }
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private let defaults: (any KeyValueStoring)?
    @ObservationIgnored private let accountKey: String
    @ObservationIgnored private let alertsKey: String
    @ObservationIgnored private var tracker: SyncAccountTracker
    @ObservationIgnored private var incidents: SyncIncidents
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var accountObserver: (any NSObjectProtocol)?
    /// Counts account checks, so only the latest one's answer is taken.
    @ObservationIgnored private var accountCheck = 0

    /// `defaults` keeps the remembered account and the notification cooldown (none: nothing is
    /// remembered across launches, as in most tests); `storeFileName` scopes their keys.
    public init(
        mode: SyncState.Mode, now: @escaping () -> Date = { Date() },
        defaults: (any KeyValueStoring)? = nil, storeFileName: String = TodoStore.storeFileName
    ) {
        let start = now()
        state = SyncState(mode: mode, startedAt: start)
        self.now = now
        self.defaults = defaults
        accountKey = Self.accountKey(storeFileName: storeFileName)
        alertsKey = Self.alertsKey(storeFileName: storeFileName)
        tracker = SyncAccountTracker(remembered: defaults?.object(forKey: accountKey) as? String)
        let posted = (defaults?.object(forKey: alertsKey) as? [String: Double]) ?? [:]
        incidents = SyncIncidents(lastPosted: posted.mapValues(Date.init(timeIntervalSince1970:)))
    }

    /// Where the account the store last mirrored with is remembered (per store file: Debug and
    /// Release mirror, and are wiped, separately).
    public static func accountKey(storeFileName: String) -> String { "howy.syncAccount.\(storeFileName)" }
    static func alertsKey(storeFileName: String) -> String { "howy.syncAlertsPosted.\(storeFileName)" }

    /// The line Settings shows now.
    public var status: SyncStatus {
        SyncStatus(state: state, account: account, isOnline: isOnline, now: now())
    }

    /// A sentence under the line, if any: the Low Power Mode hint (`SyncStatus.hint(lowPowerMode:)`).
    public var statusHint: String? {
        status.hint(lowPowerMode: isLowPowerMode)
    }

    /// The mode for how the shared store really opened: `.starting` while it isn't built,
    /// `.iCloud` if the container that was built mirrors, `.unavailable` after the CloudKit build
    /// fell back to local, `.local` otherwise. `sync` is what was actually built, never the intent.
    public static func mode(sync: StoreSync, fallbackReason: String?, isBuilt: Bool = true) -> SyncState.Mode {
        guard isBuilt else { return .starting }
        if let fallbackReason { return .unavailable(reason: fallbackReason) }
        return sync.mirrors ? .iCloud : .local
    }

    /// The Mac woke: the next import to count as the first one is one that starts now or later.
    public func noteWake() {
        state.noteWake(at: now())
        onChange()
    }

    public func setMode(_ mode: SyncState.Mode) {
        guard state.mode != mode else { return }
        state.mode = mode
        // An account read before the store was open is compared now.
        if mode == .iCloud, let account { compareAccount(account) }
        onChange()
    }

    /// Takes in one event (from the notification, or a test).
    public func receive(_ event: SyncEvent) {
        let imported = state.apply(event, at: now())
        if imported { onImport() }
        if state.acceptsEvents { post(incidents.record(event, at: now())) }
        onChange()
    }

    /// Takes in the account as just read (from `startAccountChecks`, or a test).
    public func receiveAccount(_ observation: AccountObservation) {
        account = observation
        if observation.isGone { incidents.accountUnavailable() }
        if state.mirrors { compareAccount(observation) }
    }

    /// Takes in whether the Mac has a network path (from `startNetworkChecks`, or a test).
    public func receiveNetwork(isOnline: Bool) {
        guard isOnline != self.isOnline else { return }
        self.isOnline = isOnline
        Self.log.info("Network: \(isOnline ? "online" : "offline", privacy: .public)")
        if isOnline {
            checkAccount()
            onBackOnline()
        }
    }

    /// Takes in whether Low Power Mode is on (from `startLowPowerModeChecks`, or a test). The
    /// first reading is the launch's and never notifies; after that, turning it on may
    /// (`SyncIncidents.lowPowerModeChanged`) and turning it off calls `onAlertResolved`.
    public func receiveLowPowerMode(_ isOn: Bool) {
        let wasOn: Bool? = lowPowerModeKnown ? isLowPowerMode : nil
        lowPowerModeKnown = true
        guard wasOn != isOn else { return }
        isLowPowerMode = isOn
        Self.log.info("Low Power Mode: \(isOn ? "on" : "off", privacy: .public)")
        let alerts = SyncIncidents.lowPowerModeChanged(from: wasOn, to: isOn, mode: state.mode, account: account)
        for alert in alerts { onAlert(alert) }
        if wasOn == true, !isOn { onAlertResolved(.lowPowerMode) }
    }

    /// Reads Low Power Mode now and follows its changes. Calling it again does nothing.
    public func startLowPowerModeChecks() {
        guard powerStateObserver == nil else { return }
        // Posted on a global queue; the value is read on the main actor, so the last reading wins.
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.receiveLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled) }
        }
        receiveLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private static let log = Logger(subsystem: "lueddemann.howy", category: "SyncMonitor")

    /// Follows the Mac's network path. Calling it again does nothing.
    public func startNetworkChecks() {
        guard pathMonitor == nil else { return }
        pathMonitor = Self.makePathMonitor { [weak self] isOnline in
            Task { @MainActor in self?.receiveNetwork(isOnline: isOnline) }
        }
    }

    /// Built outside the main actor, so the handler (called on the monitor's queue) doesn't
    /// inherit main-actor isolation; only the plain `Bool` crosses over.
    private nonisolated static func makePathMonitor(
        _ report: @escaping @Sendable (Bool) -> Void
    ) -> NWPathMonitor {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable path in report(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "lueddemann.howy.network"))
        return monitor
    }

    /// Checks the "failing for over an hour" rule between events (the app calls it every few
    /// minutes).
    public func tick() {
        post(incidents.tick(at: now()))
    }

    /// Reads the account now and on every `CKAccountChanged`. Calling it again only reads again.
    public func startAccountChecks(containerIdentifier: String) {
        if container == nil {
            let container = CKContainer(identifier: containerIdentifier)
            self.container = container
            // Posted on an arbitrary queue, by the container instance kept above.
            accountObserver = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.checkAccount() }
            }
        }
        checkAccount()
    }

    /// Reads the account; a check that a newer one overtook is dropped.
    public func checkAccount() {
        guard let container else { return }
        accountCheck += 1
        let check = accountCheck
        Task { @MainActor [weak self] in
            let observation = await AccountObservation.current(in: container)
            guard let self, check == self.accountCheck else { return }
            self.receiveAccount(observation)
        }
    }

    private func compareAccount(_ observation: AccountObservation) {
        let before = tracker.remembered
        let change = tracker.observe(observation)
        if tracker.remembered != before { defaults?.set(tracker.remembered, forKey: accountKey) }
        if let change { post(incidents.accountChanged(change, at: now())) }
    }

    private func post(_ alerts: [SyncAlert]) {
        guard !alerts.isEmpty else { return }
        defaults?.set(incidents.lastPosted.mapValues(\.timeIntervalSince1970), forKey: alertsKey)
        for alert in alerts { onAlert(alert) }
    }

    /// Whether `work` may run now (see `SyncGate`).
    public func gate(_ work: MaintenanceWork, retentionKnown: Bool) -> SyncGate.Decision {
        SyncGate.decide(work, sync: state, retentionKnown: retentionKnown, now: now())
    }

    /// Starts observing the mirroring events. Call it before the shared container is built, so
    /// the first setup event isn't missed. Calling it again does nothing.
    public func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let event = SyncEvent(notification: notification) else { return }
            Task { @MainActor in self?.receive(event) }
        }
    }
}
