import Foundation

/// One step of the app's store maintenance.
public enum MaintenanceStep: Hashable, Sendable, CaseIterable {
    /// The daily backup.
    case backup
    /// Duplicate todos, events and attachments.
    case duplicates
    /// Todos that came back after a delete.
    case deletedTodos
    /// Attachments (store rows and local folders) of todos that no longer exist.
    case orphanedAttachments

    /// What the sync gate is asked about this step.
    public var work: MaintenanceWork {
        switch self {
        case .backup: .backup
        case .duplicates, .deletedTodos, .orphanedAttachments: .cleanups
        }
    }
}

/// Which maintenance runs in which order, and under which gate. Values only, so the app's
/// sequencing is tested without the app.
///
/// The backup always comes first: it is the safety net, so a store that went wrong is backed up
/// before anything destructive touches it, and it has the relaxed gate (`SyncGate`). The
/// cleanups follow, each behind the strict gate, checked again before every step.
public enum MaintenancePlan {
    /// The steps of a run: the backup alone, or the backup and then the cleanups.
    public static func steps(cleanups: Bool) -> [MaintenanceStep] {
        cleanups ? [.backup, .duplicates, .deletedTodos, .orphanedAttachments] : [.backup]
    }

    /// The first decision that keeps `step` from running now, or `nil` when it may run.
    public static func blocker(for step: MaintenanceStep, decide: (MaintenanceWork) -> SyncGate.Decision) -> SyncGate.Decision? {
        let decision = decide(step.work)
        return decision.isOpen ? nil : decision
    }
}

/// Limits how often the cleanups run: after a burst of imports once per `interval`, not after
/// every one. The first run (launch) is never held back.
public struct CleanupThrottle: Hashable, Sendable {
    public static let interval: TimeInterval = 10 * 60

    public enum Decision: Hashable, Sendable {
        case run
        /// Too soon; allowed again at this date.
        case wait(until: Date)
    }

    public private(set) var lastRun: Date?

    public init(lastRun: Date? = nil) {
        self.lastRun = lastRun
    }

    public func decide(now: Date) -> Decision {
        guard let lastRun else { return .run }
        let next = lastRun.addingTimeInterval(Self.interval)
        // A clock that went back must not hold the cleanups off for ever.
        return now >= next || now < lastRun ? .run : .wait(until: next)
    }

    public mutating func didRun(at now: Date) {
        lastRun = now
    }
}

/// Notices a gate that stays closed for too long, so the app can log a fault instead of silently
/// never running its maintenance.
public struct StuckGateWatch: Hashable, Sendable {
    public static let threshold: TimeInterval = 30 * 60

    private var since: Date?
    private var reported = false

    public init() {}

    /// Feed every decision as it is made. Returns `true` once per stuck period: when the gate
    /// has been closed without a break for `threshold`. An open decision resets it.
    public mutating func note(_ decision: SyncGate.Decision, at now: Date) -> Bool {
        guard !decision.isOpen else {
            since = nil
            reported = false
            return false
        }
        let start = since ?? now
        since = start
        guard !reported, now.timeIntervalSince(start) >= Self.threshold else { return false }
        reported = true
        return true
    }
}
