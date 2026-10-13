import CloudKit
import Foundation

/// The one sync line in Settings, worked out from the mirroring state (`SyncState`) and the
/// account (`AccountObservation`). Local-only (no account, iCloud off for Howy) and offline read
/// as states, not errors; only `isProblem` ones are shown as errors.
///
/// In order: the store's mode (doesn't mirror, CloudKit fallback, not known yet), then the
/// account, then the network, then the last error (until a successful import or export clears
/// it), then whether something runs, else up to date.
///
/// The network comes first because mirroring reports no error while it's offline: an import
/// started then (by the import nudge) just doesn't end, which would read as syncing. The same
/// can happen with a network path but no internet behind it, which the path doesn't show; so
/// an import or export running longer than `hangsAfter` reads as waiting, not syncing.
///
/// **Low Power Mode** isn't a status of its own: sync still works, only later (macOS delays
/// silent pushes and background work). It is a hint under the line (`hint(lowPowerMode:)`) while
/// sync otherwise works (syncing, up to date, waiting), so "Last synced …" stays; every other
/// status says more than the hint would and shows its own text alone.
public enum SyncStatus: Hashable, Sendable {
    /// The store or the account isn't known yet (launch).
    case checking
    /// An import, export or setup runs.
    case syncing
    /// Nothing runs and the last import or export succeeded (at `lastSync`, if any did).
    case upToDate(lastSync: Date?)
    /// The Mac has no network, or the last attempt found none.
    case offline
    /// iCloud is busy, rate-limits Howy, or the account isn't ready yet; mirroring retries.
    case waiting
    /// No iCloud account: Howy works on this Mac only.
    case notSignedIn
    /// Signed in, but iCloud is off for Howy: Howy works on this Mac only.
    case iCloudOff
    /// iCloud isn't allowed on this Mac (parental controls, device management).
    case restricted
    /// Sync failed; a few words why (`SyncError.shortReason`).
    case error(reason: String)
    /// The CloudKit store couldn't be opened this run; Howy runs locally.
    case unavailable(reason: String)
    /// This build's store doesn't mirror.
    case off

    /// How long an import or export may run before the line stops saying syncing.
    public static let hangsAfter: TimeInterval = 3 * 60

    /// `isOnline` is whether the Mac has a network path (`NWPathMonitor`).
    public init(state: SyncState, account: AccountObservation?, isOnline: Bool = true, now: Date) {
        switch state.mode {
        case .local:
            self = .off
            return
        case .unavailable(let reason):
            self = .unavailable(reason: reason)
            return
        case .starting:
            self = .checking
            return
        case .iCloud:
            break
        }
        switch account {
        case nil, .couldNotDetermine?:
            // An event already says enough; without one, wait for the account.
            guard state.lastEventDate != nil || !isOnline else {
                self = .checking
                return
            }
        case .noAccount?:
            self = .notSignedIn
            return
        case .iCloudOffForApp?:
            self = .iCloudOff
            return
        case .restricted?:
            self = .restricted
            return
        case .temporarilyUnavailable?:
            self = isOnline ? .waiting : .offline
            return
        case .available?:
            break
        }
        guard isOnline else {
            self = .offline
            return
        }
        if let error = state.lastError {
            switch error.kind {
            case .silent:
                let code = error.leadingCloudKitCode
                self = code == .networkUnavailable || code == .networkFailure ? .offline : .waiting
            case .account:
                self = error.leadingCloudKitCode == .notAuthenticated ? .notSignedIn : .restricted
            case .quotaExceeded, .zoneDeleted, .persistent:
                self = .error(reason: error.shortReason)
            }
            return
        }
        if state.isBusy(at: now) {
            self = state.isBusy(at: now, startedWithin: Self.hangsAfter) ? .syncing : .waiting
            return
        }
        let last = [state.lastImport, state.lastExport].compactMap { $0 }.max()
        self = .upToDate(lastSync: last)
    }

    /// Whether this is shown as an error (red, with a warning sign).
    public var isProblem: Bool {
        switch self {
        case .error, .unavailable, .restricted: true
        default: false
        }
    }

    /// The line itself.
    public var title: String {
        switch self {
        case .checking: "Checking iCloud…"
        case .syncing: "Syncing…"
        case .upToDate: "Up to date"
        case .offline: "Offline"
        case .waiting: "Waiting for iCloud"
        case .notSignedIn: "Not signed in to iCloud"
        case .iCloudOff: "iCloud is off for Howy"
        case .restricted: "iCloud isn't allowed on this Mac"
        case .error(let reason): "Sync error: \(reason)"
        case .unavailable: "Sync unavailable"
        case .off: "Sync is off in this build"
        }
    }

    /// One sentence under the line, if there is more to say.
    public var detail: String? {
        switch self {
        case .checking, .syncing, .upToDate, .off: nil
        case .offline: "Changes sync when the network is back."
        case .waiting: "Howy tries again on its own."
        case .notSignedIn: "Your todos stay on this Mac. Sign in to iCloud to sync them."
        case .iCloudOff: "Your todos stay on this Mac. Turn iCloud on for Howy in System Settings to sync them."
        case .restricted: "Your todos stay on this Mac."
        case .error: "Your todos stay on this Mac. Howy keeps trying and notifies you if it lasts."
        case .unavailable(let reason): "Howy runs on this Mac only until it's restarted (\(reason))."
        }
    }

    /// The hint under the line while Low Power Mode is on.
    public static let lowPowerModeHint = "Low Power Mode is on, so sync may be delayed."

    /// A sentence shown below the line and its detail: the Low Power Mode hint while
    /// `lowPowerMode` is on and sync otherwise works (syncing, up to date, waiting); `nil` for
    /// the other statuses, whose own text takes priority.
    public func hint(lowPowerMode: Bool) -> String? {
        guard lowPowerMode else { return nil }
        switch self {
        case .syncing, .upToDate, .waiting: return Self.lowPowerModeHint
        case .checking, .offline, .notSignedIn, .iCloudOff, .restricted, .error, .unavailable, .off: return nil
        }
    }

    /// The SF Symbol for the line.
    public var symbolName: String {
        switch self {
        case .checking, .syncing: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        case .offline, .waiting: "icloud.slash"
        case .notSignedIn, .iCloudOff, .off: "icloud"
        case .restricted, .error, .unavailable: "exclamationmark.icloud"
        }
    }
}
