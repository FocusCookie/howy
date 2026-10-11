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

/// A sync error as plain values, for the status line and the notification rules of Phase 3c.
public struct SyncError: Hashable, Sendable {
    public var domain: String
    public var code: Int
    public var description: String

    public init(domain: String, code: Int, description: String) {
        self.domain = domain
        self.code = code
        self.description = description
    }

    public init(_ error: any Error) {
        let error = error as NSError
        self.init(domain: error.domain, code: error.code, description: error.localizedDescription)
    }

    /// The CloudKit error code, when it is a CloudKit error.
    public var cloudKitCode: CKError.Code? {
        domain == CKError.errorDomain ? CKError.Code(rawValue: code) : nil
    }
}

/// What the app knows about the shared store's CloudKit mirroring, fed by `SyncEvent`s
/// (`apply(_:at:)`). A value, so it is tested by feeding events in; `SyncMonitor` holds the
/// app's. Phase 3c renders it (the Settings status line, the error notifications).
public struct SyncState: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// The store doesn't mirror (the widget extension, or a build without sync).
        case local
        /// The store mirrors to CloudKit.
        case iCloud
        /// The store should mirror but couldn't be opened with CloudKit; it runs locally this run.
        case unavailable(reason: String)
    }

    /// What mirroring is doing now. Several events can run at once; setup counts first, then
    /// import, then export.
    public enum Phase: Hashable, Sendable {
        case idle, settingUp, importing, exporting
    }

    public var mode: Mode
    /// Events started and not yet finished, by id.
    public private(set) var inFlight: [UUID: SyncEvent.Kind] = [:]
    /// When the last import and export finished successfully (by their `endDate`).
    public private(set) var lastImport: Date?
    public private(set) var lastExport: Date?
    /// The error of the last event that failed; cleared by the next successful import or export.
    public private(set) var lastError: SyncError?
    /// When `lastError` came (the failed event's `endDate`).
    public private(set) var lastErrorDate: Date?
    /// Whether an import has finished successfully since launch.
    public private(set) var firstImportDone = false
    /// Whether the last setup that finished failed (e.g. no iCloud account): mirroring then
    /// does nothing until a new setup starts, so it can't be waited for.
    public private(set) var setupFailed = false
    /// When the last event (a start or an end) was received, by the receiver's clock.
    public private(set) var lastEventDate: Date?
    /// Ends that arrived before their start (the hop to the main actor may reorder them), so the
    /// late start isn't counted as in flight. Kept small.
    private var finishedEarly: [UUID] = []

    public init(mode: Mode) {
        self.mode = mode
    }

    public var mirrors: Bool { mode == .iCloud }

    public var phase: Phase {
        let kinds = Set(inFlight.values)
        if kinds.contains(.setup) { return .settingUp }
        if kinds.contains(.import) { return .importing }
        if kinds.contains(.export) { return .exporting }
        return .idle
    }

    /// Whether an import or export (or setup) is running.
    public var isBusy: Bool { !inFlight.isEmpty }

    /// Takes in an event received at `now`. Ignored unless the store mirrors. Returns `true`
    /// when it was the successful end of an import (the app then refreshes what shows the data).
    @discardableResult
    public mutating func apply(_ event: SyncEvent, at now: Date) -> Bool {
        guard mirrors else { return false }
        lastEventDate = now
        guard let end = event.endDate else {
            if let index = finishedEarly.firstIndex(of: event.id) {
                finishedEarly.remove(at: index)
            } else {
                inFlight[event.id] = event.kind
                if event.kind == .setup { setupFailed = false }
            }
            return false
        }
        if inFlight.removeValue(forKey: event.id) == nil {
            finishedEarly.append(event.id)
            if finishedEarly.count > 32 { finishedEarly.removeFirst() }
        }
        if event.succeeded {
            switch event.kind {
            case .setup: setupFailed = false
            case .import:
                lastImport = end
                firstImportDone = true
                clearError()
            case .export:
                lastExport = end
                clearError()
            }
        } else {
            if event.kind == .setup { setupFailed = true }
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
/// Without mirroring, always (the purge only once the retention is known). With mirroring, only
/// when the store has settled: the first import since launch finished successfully (or setup
/// failed, so nothing will arrive until a new setup), nothing is in flight, and no event came for
/// `quietPeriod`. A closed gate defers the work; the app checks again on every sync event and
/// at the date a `.waitUntil` gives.
public enum SyncGate {
    /// How long after the last sync event the store counts as settled.
    public static let quietPeriod: TimeInterval = 30

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
        guard sync.mirrors else { return .open }
        guard !sync.isBusy, sync.firstImportDone || sync.setupFailed else { return .waitForSync }
        if let last = sync.lastEventDate, now < last.addingTimeInterval(quietPeriod) {
            return .waitUntil(last.addingTimeInterval(quietPeriod))
        }
        return .open
    }
}
