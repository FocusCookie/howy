import CoreData
import Foundation
import Observation

/// The app's live `SyncState`: observes the CloudKit mirroring events and answers the
/// `SyncGate` from them.
///
/// SwiftData's CloudKit store runs on Core Data's `NSPersistentCloudKitContainer` mirroring,
/// which posts `NSPersistentCloudKitContainer.eventChangedNotification`. The notification's
/// object is that internal container, which SwiftData doesn't expose, so the observation can't be
/// narrowed to Howy's store; there is only one mirroring store per process (`SharedContainer`),
/// so every event is ours.
///
/// The event is read on the posting queue (it isn't `Sendable`), only its plain values
/// (`SyncEvent`) cross to the main actor. Tests call `receive(_:)` directly.
@MainActor
@Observable
public final class SyncMonitor {
    public private(set) var state: SyncState
    /// After an import finished successfully: reload what shows the data.
    @ObservationIgnored public var onImport: () -> Void = {}
    /// After every event (and a mode change): check the deferred maintenance again.
    @ObservationIgnored public var onChange: () -> Void = {}
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    public init(mode: SyncState.Mode, now: @escaping () -> Date = { Date() }) {
        let start = now()
        state = SyncState(mode: mode, startedAt: start)
        self.now = now
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
        onChange()
    }

    /// Takes in one event (from the notification, or a test).
    public func receive(_ event: SyncEvent) {
        let imported = state.apply(event, at: now())
        if imported { onImport() }
        onChange()
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
