import CloudKit
import Foundation

/// What a sync error means for the user: the CKError matrix.
///
/// | Kind | CloudKit codes | Effect |
/// | --- | --- | --- |
/// | `silent` | `networkUnavailable`, `networkFailure`, `serviceUnavailable`, `requestRateLimited`, `zoneBusy`, `accountTemporarilyUnavailable`, `serverResponseLost`, `operationCancelled` | Never notifies, never counts; the status line says offline or waiting |
/// | `account` | `notAuthenticated`, `managedAccountRestricted` | No error notification: the account check (`SyncAccountTracker`) handles sign-out |
/// | `quotaExceeded` | `quotaExceeded` | Notifies "iCloud storage is full" right away |
/// | `zoneDeleted` | `userDeletedZone` | Notifies that Howy's data was removed (a wipe) |
/// | `persistent` | everything else, and errors without a CloudKit code | Notifies once sync has failed for over an hour without a success |
///
/// Mirroring wraps the CloudKit error in a Core Data one, and a `partialFailure` carries the real
/// errors per item; all of them are looked at, and the most serious kind wins (`zoneDeleted`,
/// then `quotaExceeded`, `persistent`, `account`, `silent`). A `partialFailure` or
/// `batchRequestFailed` only stands for itself when nothing else is there.
public enum SyncErrorKind: Int, Hashable, Sendable, Comparable {
    case silent, account, persistent, quotaExceeded, zoneDeleted

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func of(_ code: CKError.Code) -> SyncErrorKind {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy,
             .accountTemporarilyUnavailable, .serverResponseLost, .operationCancelled:
            .silent
        case .notAuthenticated, .managedAccountRestricted:
            .account
        case .quotaExceeded:
            .quotaExceeded
        case .userDeletedZone:
            .zoneDeleted
        default:
            .persistent
        }
    }
}

extension SyncError {
    /// Every CloudKit code this error carries: its own (or the wrapped one) and the per-item ones.
    var allCloudKitCodes: [CKError.Code] {
        var raw = Array(partialCloudKitCodes)
        if let code = cloudKitCode?.rawValue { raw.append(code) }
        let codes = raw.compactMap(CKError.Code.init(rawValue:))
        // The umbrella codes only stand for themselves when nothing more specific is there.
        let specific = codes.filter { $0 != .partialFailure && $0 != .batchRequestFailed }
        return specific.isEmpty ? codes : specific
    }

    /// How this error is treated (see `SyncErrorKind`).
    public var kind: SyncErrorKind {
        allCloudKitCodes.map(SyncErrorKind.of).max() ?? .persistent
    }

    /// The most serious CloudKit code, the one `kind` came from.
    var leadingCloudKitCode: CKError.Code? {
        allCloudKitCodes.max { SyncErrorKind.of($0) < SyncErrorKind.of($1) }
    }

    /// A few words on what went wrong, for the status line and the "failing" notification.
    public var shortReason: String {
        guard let code = leadingCloudKitCode else {
            let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "\(domain) error \(code)" }
            return text.count > 80 ? String(text.prefix(79)) + "…" : text
        }
        switch code {
        case .quotaExceeded: return "iCloud storage is full"
        case .userDeletedZone: return "Howy's iCloud data was deleted"
        case .networkUnavailable, .networkFailure: return "offline"
        case .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost: return "iCloud is busy"
        case .notAuthenticated: return "not signed in to iCloud"
        case .accountTemporarilyUnavailable: return "iCloud account temporarily unavailable"
        case .managedAccountRestricted, .permissionFailure: return "iCloud access isn't allowed"
        case .missingEntitlement, .badContainer, .badDatabase: return "this build of Howy can't use iCloud"
        case .incompatibleVersion: return "this version of Howy is too old for iCloud"
        case .unknownItem, .invalidArguments, .serverRejectedRequest, .constraintViolation:
            return "iCloud rejected Howy's data"
        case .zoneNotFound: return "Howy's iCloud zone is missing"
        case .limitExceeded: return "too much to send at once"
        case .internalError: return "iCloud server error"
        default: return "CloudKit error \(code.rawValue)"
        }
    }
}

/// What the account check saw changing (see `SyncAccountTracker`). Either way macOS removes the
/// synced todos from this Mac.
public enum AccountChange: Hashable, Sendable {
    /// Signed out of iCloud, or iCloud turned off for Howy, after an account was remembered.
    case signedOut
    /// Another iCloud account than the remembered one.
    case switched
}

/// Why the synced todos left this Mac.
public enum DataRemovalCause: String, Hashable, Sendable, CaseIterable {
    case signedOut, accountSwitched, iCloudDataDeleted
}

/// A notification about sync, posted by the app (`SyncMonitor.onAlert`). Clicking one opens
/// Settings at the sync line.
public enum SyncAlert: Hashable, Sendable {
    /// Signed out, iCloud off for Howy, another account, or Howy's iCloud data deleted: the
    /// local copy was wiped.
    case dataRemoved(DataRemovalCause)
    /// iCloud storage is full; changes don't upload.
    case storageFull
    /// Sync has failed for over an hour without a success.
    case failing(reason: String)
    /// Low Power Mode turned on while the store mirrors with a signed-in account: sync may be
    /// delayed (`SyncIncidents.lowPowerModeChanged`).
    case lowPowerMode

    /// The prefix of every sync notification's identifier (a click on one is told apart by it).
    public static let identifierPrefix = "howy.sync."

    /// The notification's identifier: one per kind, so a newer one replaces the older.
    public var identifier: String { Self.identifierPrefix + cooldownKey }

    /// Whether posting this asks for notification permission when it was never asked. The
    /// problems do (the todos may have left this Mac); the Low Power Mode note only shows if
    /// notifications are already allowed: it isn't worth a permission prompt.
    public var asksForPermission: Bool {
        switch self {
        case .dataRemoved, .storageFull, .failing: true
        case .lowPowerMode: false
        }
    }

    /// The kind as a key, for the cooldown record.
    var cooldownKey: String {
        switch self {
        case .dataRemoved: "dataRemoved"
        case .storageFull: "storageFull"
        case .failing: "failing"
        case .lowPowerMode: "lowPowerMode"
        }
    }

    public var title: String {
        switch self {
        case .dataRemoved(.signedOut): "iCloud sync stopped"
        case .dataRemoved(.accountSwitched): "iCloud account changed"
        case .dataRemoved(.iCloudDataDeleted): "Howy's iCloud data was deleted"
        case .storageFull: "iCloud storage is full"
        case .failing: "iCloud sync isn't working"
        case .lowPowerMode: "Sync may be delayed"
        }
    }

    private static let backupHint = "Howy's daily backups are in Settings → Data."

    public var body: String {
        switch self {
        case .dataRemoved(.signedOut):
            "You signed out of iCloud or turned iCloud off for Howy, so macOS removed the synced todos from this Mac. Sign back in to get them again. " + Self.backupHint
        case .dataRemoved(.accountSwitched):
            "This Mac uses another iCloud account now, so macOS removed the previous account's todos from it. " + Self.backupHint
        case .dataRemoved(.iCloudDataDeleted):
            "Howy's data was deleted from iCloud, so it was removed from this Mac too. " + Self.backupHint
        case .storageFull:
            "Howy can't upload changes until there's space. Your todos stay on this Mac. Free up space in System Settings → Apple Account → iCloud."
        case .failing(let reason):
            "Howy hasn't been able to sync for over an hour (\(reason)). Your todos stay on this Mac."
        case .lowPowerMode:
            "Low Power Mode is on, so iCloud may sync your todos later than usual."
        }
    }
}

/// Turns sync events and account changes into notifications, once per incident.
///
/// - **Storage full** notifies at the first `quotaExceeded`; the incident lasts until an export
///   succeeds.
/// - **Data removed** notifies at an account change (sign-out, iCloud off for Howy, another
///   account) or a `userDeletedZone`; a deleted zone within `dataRemovedDedupe` of another
///   removal notice (the sign-out's own fallout) doesn't notify again. The incident lasts until
///   an import or export succeeds.
/// - **Failing**: a `persistent` error starts the clock; when no import or export has succeeded
///   for `persistentFailureThreshold` since, it notifies (on the next event or `tick`), unless the
///   latest error was a silent one (offline right now never notifies). A success ends it, and so
///   does losing the account (no account is local mode, not a failure).
/// - `silent` and `account` errors never notify and neither start nor end an incident.
///
/// On top of that, storage-full and failing notices don't repeat within `repeatCooldown`, also
/// across launches: `lastPosted` is what the app saves and hands back.
///
/// - **Low Power Mode** (`lowPowerModeChanged`) notifies every time it turns on (no cooldown)
///   while the store mirrors with a signed-in account; not at launch when it is already on.
///
/// A value with the time passed in (`at:`), so it is tested by feeding events and dates.
public struct SyncIncidents: Hashable, Sendable {
    /// How long sync must fail without a success before it notifies.
    public static let persistentFailureThreshold: TimeInterval = 60 * 60
    /// The least time between two storage-full or two failing notices.
    public static let repeatCooldown: TimeInterval = 24 * 60 * 60
    /// The least time between two data-removed notices.
    public static let dataRemovedDedupe: TimeInterval = 10 * 60

    /// When each kind of notice was last posted (`SyncAlert.cooldownKey`).
    public private(set) var lastPosted: [String: Date]
    /// When the current failure incident started (its first `persistent` error).
    public private(set) var failingSince: Date?
    /// The latest `persistent` error of the incident, for the notice's reason.
    private var failingError: SyncError?
    private var failingNotified = false
    /// Whether the latest error was a silent one (offline, busy).
    private var latestErrorSilent = false
    private var quotaOpen = false
    private var zoneDeletedOpen = false

    public init(lastPosted: [String: Date] = [:]) {
        self.lastPosted = lastPosted
    }

    /// Takes in a finished event received at `now`; returns the notices to post.
    public mutating func record(_ event: SyncEvent, at now: Date) -> [SyncAlert] {
        guard event.isFinished else { return [] }
        if event.succeeded {
            if event.kind != .setup {
                endFailure()
                zoneDeletedOpen = false
                latestErrorSilent = false
            }
            if event.kind == .export { quotaOpen = false }
            return []
        }
        guard let error = event.error else { return check(at: now) }
        var alerts: [SyncAlert] = []
        switch error.kind {
        case .silent:
            latestErrorSilent = true
        case .account:
            break
        case .quotaExceeded:
            latestErrorSilent = false
            if !quotaOpen {
                quotaOpen = true
                if let alert = post(.storageFull, at: now, within: Self.repeatCooldown) { alerts.append(alert) }
            }
        case .zoneDeleted:
            latestErrorSilent = false
            if !zoneDeletedOpen {
                zoneDeletedOpen = true
                if let alert = post(.dataRemoved(.iCloudDataDeleted), at: now, within: Self.dataRemovedDedupe) {
                    alerts.append(alert)
                }
            }
        case .persistent:
            latestErrorSilent = false
            if failingSince == nil { failingSince = now }
            failingError = error
        }
        return alerts + check(at: now)
    }

    /// The account check saw a sign-out or another account: the local data was removed.
    public mutating func accountChanged(_ change: AccountChange, at now: Date) -> [SyncAlert] {
        endFailure()
        quotaOpen = false
        latestErrorSilent = false
        zoneDeletedOpen = true // the deleted zone that may follow is the same incident
        let cause: DataRemovalCause = change == .signedOut ? .signedOut : .accountSwitched
        return post(.dataRemoved(cause), at: now, within: Self.dataRemovedDedupe).map { [$0] } ?? []
    }

    /// No usable account: sync isn't expected to work, so a failure incident ends.
    public mutating func accountUnavailable() {
        endFailure()
        quotaOpen = false
    }

    /// Low Power Mode went from `wasOn` to `isOn` (`wasOn` is `nil` for the first reading, at
    /// launch). Notifies when it turns on (off → on; the launch reading never notifies, the
    /// Settings line shows the hint then) and sync would be affected: the store mirrors
    /// (`.iCloud`) and the account is signed in (available, or temporarily unavailable). Not for
    /// a store that doesn't mirror or fell back to local, no account, iCloud off for Howy,
    /// restricted, or an account not known yet. A turn-on while the account or store isn't known
    /// yet is not notified later, when they become known. No cooldown: each turn-on notifies.
    public static func lowPowerModeChanged(
        from wasOn: Bool?, to isOn: Bool, mode: SyncState.Mode, account: AccountObservation?
    ) -> [SyncAlert] {
        guard wasOn == false, isOn, mode == .iCloud else { return [] }
        switch account {
        case .available?, .temporarilyUnavailable?: return [.lowPowerMode]
        case nil, .noAccount?, .iCloudOffForApp?, .restricted?, .couldNotDetermine?: return []
        }
    }

    /// Checks the "over an hour" rule without an event (the app calls it every few minutes).
    public mutating func tick(at now: Date) -> [SyncAlert] {
        check(at: now)
    }

    private mutating func check(at now: Date) -> [SyncAlert] {
        guard let since = failingSince, !failingNotified, !latestErrorSilent,
              now.timeIntervalSince(since) >= Self.persistentFailureThreshold
        else { return [] }
        let reason = failingError?.shortReason ?? "unknown error"
        // Held back by the cooldown: asked again on the next event or tick, so a failure that
        // still lasts once the cooldown is over notifies then.
        guard let alert = post(.failing(reason: reason), at: now, within: Self.repeatCooldown) else { return [] }
        failingNotified = true
        return [alert]
    }

    private mutating func endFailure() {
        failingSince = nil
        failingError = nil
        failingNotified = false
    }

    /// The notice, unless one of its kind was posted less than `interval` before `now`.
    private mutating func post(_ alert: SyncAlert, at now: Date, within interval: TimeInterval) -> SyncAlert? {
        if let last = lastPosted[alert.cooldownKey], now.timeIntervalSince(last) < interval, now >= last { return nil }
        lastPosted[alert.cooldownKey] = now
        return alert
    }
}
