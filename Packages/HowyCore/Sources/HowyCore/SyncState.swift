import CloudKit
import CoreData
import Foundation

/// One CloudKit mirroring event as plain values: what
/// `NSPersistentCloudKitContainer.eventChangedNotification` carries, taken off the notification
/// on the queue that posted it.
///
/// Mirroring posts each event twice with the same `id`: when it starts (`endDate == nil`) and
/// when it ends (`endDate` set, with `succeeded` and maybe an `error`).
public struct SyncEvent: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Preparing the CloudKit zone and subscriptions (at launch, after an account change).
        case setup
        /// Fetching changes from CloudKit into the store.
        case `import`
        /// Sending the store's changes to CloudKit.
        case export
    }

    public var id: UUID
    public var kind: Kind
    public var startDate: Date
    public var endDate: Date?
    public var succeeded: Bool
    public var error: SyncError?

    public init(id: UUID, kind: Kind, startDate: Date, endDate: Date? = nil, succeeded: Bool = false, error: SyncError? = nil) {
        self.id = id
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.succeeded = succeeded
        self.error = error
    }

    /// The values of a Core Data CloudKit event; `nil` for a type this build doesn't know.
    public init?(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: Kind
        switch event.type {
        case .setup: kind = .setup
        case .import: kind = .import
        case .export: kind = .export
        @unknown default: return nil
        }
        self.init(
            id: event.identifier, kind: kind, startDate: event.startDate, endDate: event.endDate,
            succeeded: event.succeeded, error: event.error.map(SyncError.init)
        )
    }

    /// The event's values from a notification's `userInfo`, if it carries one
    /// (`NSPersistentCloudKitContainer.eventNotificationUserInfoKey`).
    public init?(notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
            as? NSPersistentCloudKitContainer.Event else { return nil }
        self.init(event)
    }

    /// Whether this is the end of the event (it has an `endDate`).
    public var isFinished: Bool { endDate != nil }
}

/// A sync error as plain values, for the status line (`SyncStatus`) and the notification rules
/// (`SyncError.kind`, `SyncIncidents`).
public struct SyncError: Hashable, Sendable {
    public var domain: String
    public var code: Int
    public var description: String
    /// The code of the CloudKit error underneath, when the error itself is another domain's
    /// (Core Data wraps the CloudKit error it got).
    public var underlyingCloudKitCode: Int?
    /// The CloudKit codes of the per-item errors of a `partialFailure`
    /// (`CKPartialErrorsByItemIDKey`), anywhere in the error's chain: storage full or a deleted
    /// zone often only shows there.
    public var partialCloudKitCodes: Set<Int>

    public init(
        domain: String, code: Int, description: String, underlyingCloudKitCode: Int? = nil,
        partialCloudKitCodes: Set<Int> = []
    ) {
        self.domain = domain
        self.code = code
        self.description = description
        self.underlyingCloudKitCode = underlyingCloudKitCode
        self.partialCloudKitCodes = partialCloudKitCodes
    }

    public init(_ error: any Error) {
        let error = error as NSError
        var underlying: Int?
        var partials = Self.partialCodes(of: error)
        var next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let inner = next, depth < 8 {
            if underlying == nil, inner.domain == CKError.errorDomain { underlying = inner.code }
            partials.formUnion(Self.partialCodes(of: inner))
            next = inner.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        self.init(
            domain: error.domain, code: error.code, description: error.localizedDescription,
            underlyingCloudKitCode: underlying, partialCloudKitCodes: partials
        )
    }

    /// The CloudKit codes of one error's per-item errors.
    private static func partialCodes(of error: NSError) -> Set<Int> {
        guard let items = error.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary else { return [] }
        var codes: Set<Int> = []
        for case let item as NSError in items.allValues where item.domain == CKError.errorDomain {
            codes.insert(item.code)
        }
        return codes
    }

    /// The CloudKit error code, when it is (or wraps) a CloudKit error.
    public var cloudKitCode: CKError.Code? {
        if domain == CKError.errorDomain { return CKError.Code(rawValue: code) }
        return underlyingCloudKitCode.flatMap { CKError.Code(rawValue: $0) }
    }

    /// Whether this says mirroring can't work until the account or the build's entitlements
    /// change: no iCloud account, a restricted one, a missing entitlement or container, or no
    /// permission. Transient failures (network, rate limits, a busy server, a temporarily
    /// unavailable account) are not.
    public var isAccountOrEntitlementProblem: Bool {
        guard let code = cloudKitCode else { return false }
        switch code {
        case .notAuthenticated, .missingEntitlement, .badContainer, .permissionFailure, .managedAccountRestricted:
            return true
        default:
            return false
        }
    }
}

/// What the app knows about the shared store's CloudKit mirroring, fed by `SyncEvent`s
/// (`apply(_:at:)`). A value, so it is tested by feeding events in; `SyncMonitor` holds the
/// app's. `SyncStatus` renders it as the Settings status line.
public struct SyncState: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// The store doesn't mirror (the widget extension, or a build without sync).
        case local
        /// The store mirrors to CloudKit.
        case iCloud
        /// The store should mirror but couldn't be opened with CloudKit; it runs locally this run.
        case unavailable(reason: String)
        /// The shared container isn't built yet, so what it will be isn't known. Events that come
        /// are taken in (the container may have been built by something else first), but no
        /// destructive work runs.
        case starting
    }

    /// What mirroring is doing now. Several events can run at once; setup counts first, then
    /// import, then export.
    public enum Phase: Hashable, Sendable {
        case idle, settingUp, importing, exporting
    }

    /// An event that was started and never ended counts as stale (and no longer as busy) after this.
    public static let staleAfter: TimeInterval = 10 * 60

    public var mode: Mode
    /// When this state began (launch), by the receiver's clock: the relaxed backup gate fails open
    /// `SyncGate.backupFailOpenDelay` after it.
    public let startedAt: Date
    /// Events started and not yet finished, by id.
    public private(set) var inFlight: [UUID: SyncEvent.Kind] = [:]
    private var inFlightSince: [UUID: Date] = [:]
    /// Imports that started before this don't count towards `firstImportDone`: launch (the
    /// beginning of time here) or the last wake.
    public private(set) var importBarrier = Date.distantPast
    /// When the last import and export finished successfully (by their `endDate`).
    public private(set) var lastImport: Date?
    public private(set) var lastExport: Date?
    /// The error of the last event that failed; cleared by the next successful import or export.
    public private(set) var lastError: SyncError?
    /// When `lastError` came (the failed event's `endDate`).
    public private(set) var lastErrorDate: Date?
    /// Whether an import that *started after* launch or the last wake (`noteWake(at:)`) has
    /// finished successfully. Reset by a new setup event: a new setup (account change) can bring
    /// everything again.
    public private(set) var firstImportDone = false
    /// Whether the last setup that finished failed for an account or entitlement reason (e.g. no
    /// iCloud account, `SyncError.isAccountOrEntitlementProblem`): mirroring then does nothing
    /// until a new setup starts, so it can't be waited for. A transient failure doesn't count.
    public private(set) var setupFailed = false
    /// When the last event (a start or an end) was received, by the receiver's clock.
    public private(set) var lastEventDate: Date?
    /// Ends that arrived before their start (the hop to the main actor may reorder them), so the
    /// late start isn't counted as in flight. Kept small.
    private var finishedEarly: [UUID] = []

    public init(mode: Mode, startedAt: Date = Date()) {
        self.mode = mode
        self.startedAt = startedAt
    }

    public var mirrors: Bool { mode == .iCloud }

    /// Whether events are taken in: the store mirrors, or it isn't known yet.
    var acceptsEvents: Bool { mode == .iCloud || mode == .starting }

    public var phase: Phase {
        let kinds = Set(inFlight.values)
        if kinds.contains(.setup) { return .settingUp }
        if kinds.contains(.import) { return .importing }
        if kinds.contains(.export) { return .exporting }
        return .idle
    }

    /// Whether an import or export (or setup) is running (stale entries included).
    public var isBusy: Bool { !inFlight.isEmpty }

    /// Whether an event is in flight that started less than `staleAfter` before `now`. An event
    /// whose end was never seen doesn't hold the gate shut for ever.
    public func isBusy(at now: Date) -> Bool {
        inFlightSince.values.contains { now.timeIntervalSince($0) < Self.staleAfter }
    }

    /// The Mac woke from sleep: what arrived meanwhile hasn't been imported yet, so only an import
    /// that starts from now on counts as the first one again.
    public mutating func noteWake(at now: Date) {
        importBarrier = now
        firstImportDone = false
    }

    /// Takes in an event received at `now`. Ignored unless the store mirrors. Returns `true`
    /// when it was the successful end of an import (the app then refreshes what shows the data).
    @discardableResult
    public mutating func apply(_ event: SyncEvent, at now: Date) -> Bool {
        guard acceptsEvents else { return false }
        lastEventDate = now
        for (id, since) in inFlightSince where now.timeIntervalSince(since) >= Self.staleAfter {
            inFlightSince[id] = nil
            inFlight[id] = nil
        }
        guard let end = event.endDate else {
            if let index = finishedEarly.firstIndex(of: event.id) {
                finishedEarly.remove(at: index)
            } else {
                inFlight[event.id] = event.kind
                inFlightSince[event.id] = now
                if event.kind == .setup {
                    setupFailed = false
                    firstImportDone = false
                }
            }
            return false
        }
        inFlightSince[event.id] = nil
        if inFlight.removeValue(forKey: event.id) == nil {
            finishedEarly.append(event.id)
            if finishedEarly.count > 32 { finishedEarly.removeFirst() }
        }
        if event.succeeded {
            switch event.kind {
            case .setup: setupFailed = false
            case .import:
                lastImport = end
                if event.startDate >= importBarrier { firstImportDone = true }
                clearError()
            case .export:
                lastExport = end
                clearError()
            }
        } else {
            if event.kind == .setup, event.error?.isAccountOrEntitlementProblem == true { setupFailed = true }
            if let error = event.error {
                lastError = error
                lastErrorDate = end
            }
        }
        return event.succeeded && event.kind == .import
    }

    private mutating func clearError() {
        lastError = nil
        lastErrorDate = nil
    }
}

/// Maintenance work that `SyncGate` holds back while sync could still change the store.
public enum MaintenanceWork: Hashable, Sendable, CaseIterable {
    /// Destructive cleanups: duplicates, deleted todos that came back, orphaned attachments.
    case cleanups
    /// The daily backup.
    case backup
    /// The archive purge, which also needs the shared retention value.
    case purge
}

/// When destructive maintenance and the daily backup may run.
///
/// Without mirroring, always (the purge only once the retention is known). With mirroring:
///
/// - **Destructive work** (cleanups, purge) only when the store has settled: an import that
///   started after launch or the last wake finished successfully (or setup failed for an account
///   or entitlement reason, so nothing will arrive until a new setup), no event is in flight (one
///   that started over `SyncState.staleAfter` ago doesn't count), and none came for
///   `quietPeriod`. Until the shared container's real mode is reported (`.starting`) it waits too.
/// - **The backup** (read-only) has a relaxed gate: sync quiet (some event came, nothing in
///   flight, `quietPeriod` since the last), or `backupFailOpenDelay` since launch, whatever sync
///   does. A backup taken early is still a backup; a missing one is the worse failure.
///
/// A closed gate defers the work; the app checks again on every sync event, at the date a
/// `.waitUntil` gives, and every `retryInterval` while it waits for sync.
public enum SyncGate {
    /// How long after the last sync event the store counts as settled.
    public static let quietPeriod: TimeInterval = 30
    /// How long after launch the backup runs whatever sync is doing.
    public static let backupFailOpenDelay: TimeInterval = 10 * 60
    /// How often the app re-asks while the decision is `.waitForSync`.
    public static let retryInterval: TimeInterval = 60

    public enum Decision: Hashable, Sendable {
        case open
        /// Settled at this date, unless another event comes first.
        case waitUntil(Date)
        /// Waiting for sync: an event in flight, or the first import not done yet.
        case waitForSync
        /// Waiting for the archive retention to be known (`ArchiveRetentionStore.isKnown`).
        case waitForRetention

        public var isOpen: Bool { self == .open }
    }

    public static func decide(_ work: MaintenanceWork, sync: SyncState, retentionKnown: Bool, now: Date) -> Decision {
        if work == .purge, !retentionKnown { return .waitForRetention }
        switch sync.mode {
        case .local, .unavailable: return .open
        case .starting: return work == .backup ? backup(sync: sync, now: now) : .waitForSync
        case .iCloud: return work == .backup ? backup(sync: sync, now: now) : destructive(sync: sync, now: now)
        }
    }

    private static func destructive(sync: SyncState, now: Date) -> Decision {
        guard !sync.isBusy(at: now), sync.firstImportDone || sync.setupFailed else { return .waitForSync }
        if let last = sync.lastEventDate, now < last.addingTimeInterval(quietPeriod) {
            return .waitUntil(last.addingTimeInterval(quietPeriod))
        }
        return .open
    }

    private static func backup(sync: SyncState, now: Date) -> Decision {
        let failOpen = sync.startedAt.addingTimeInterval(backupFailOpenDelay)
        if now >= failOpen { return .open }
        guard !sync.isBusy(at: now), let last = sync.lastEventDate else { return .waitUntil(failOpen) }
        let quiet = last.addingTimeInterval(quietPeriod)
        return now < quiet ? .waitUntil(min(quiet, failOpen)) : .open
    }
}
