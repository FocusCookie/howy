import Foundation
import Testing
@testable import HowyCore

/// The order and the gates of the maintenance, the cleanup throttle and the stuck-gate watch.
@Suite struct MaintenancePlanTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func theBackupComesFirst() {
        #expect(MaintenancePlan.steps(cleanups: false) == [.backup])
        #expect(MaintenancePlan.steps(cleanups: true) == [.backup, .duplicates, .deletedTodos, .orphanedAttachments])
    }

    @Test func eachStepAsksItsOwnGate() {
        #expect(MaintenanceStep.backup.work == .backup)
        for step in [MaintenanceStep.duplicates, .deletedTodos, .orphanedAttachments] {
            #expect(step.work == .cleanups)
        }
    }

    @Test func theBlockerIsTheClosedGate() {
        let gates: (MaintenanceWork) -> SyncGate.Decision = { $0 == .backup ? .open : .waitForSync }
        #expect(MaintenancePlan.blocker(for: .backup, decide: gates) == nil)
        #expect(MaintenancePlan.blocker(for: .duplicates, decide: gates) == .waitForSync)
    }

    @Test func aRunOnAFreshlyLaunchedMirroringStoreBacksUpWhileTheCleanupsWait() {
        // Quiet for 30 s after the setup, but no import yet.
        var state = SyncState(mode: .iCloud, startedAt: start)
        let id = UUID()
        state.apply(SyncEvent(id: id, kind: .setup, startDate: at(0)), at: at(0))
        state.apply(SyncEvent(id: id, kind: .setup, startDate: at(0), endDate: at(1), succeeded: true), at: at(1))
        let decide: (MaintenanceWork) -> SyncGate.Decision = { SyncGate.decide($0, sync: state, retentionKnown: true, now: self.at(60)) }
        let blocked = MaintenancePlan.steps(cleanups: true).filter { MaintenancePlan.blocker(for: $0, decide: decide) != nil }
        #expect(blocked == [.duplicates, .deletedTodos, .orphanedAttachments])
    }

    // MARK: Throttle

    @Test func theFirstCleanupRunsAtOnce() {
        #expect(CleanupThrottle().decide(now: start) == .run)
    }

    @Test func cleanupsAreHeldBackForTenMinutes() {
        var throttle = CleanupThrottle()
        throttle.didRun(at: start)
        #expect(throttle.decide(now: at(60)) == .wait(until: at(600)))
        #expect(throttle.decide(now: at(599)) == .wait(until: at(600)))
        #expect(throttle.decide(now: at(600)) == .run)
    }

    @Test func aClockThatWentBackDoesNotBlockTheCleanups() {
        var throttle = CleanupThrottle()
        throttle.didRun(at: at(1000))
        #expect(throttle.decide(now: at(0)) == .run)
    }

    // MARK: Stuck gate

    @Test func aGateThatStaysClosedIsReportedOnce() {
        var watch = StuckGateWatch()
        let first = watch.note(.waitForSync, at: start)
        let justBefore = watch.note(.waitForSync, at: at(StuckGateWatch.threshold - 1))
        let reported = watch.note(.waitUntil(at(5)), at: at(StuckGateWatch.threshold))
        let again = watch.note(.waitForSync, at: at(StuckGateWatch.threshold + 60))
        #expect(!first && !justBefore)
        #expect(reported)
        #expect(!again, "once per stuck period")
    }

    @Test func anOpenGateResetsTheWatch() {
        var watch = StuckGateWatch()
        _ = watch.note(.waitForSync, at: start)
        let open = watch.note(.open, at: at(StuckGateWatch.threshold))
        let restarted = watch.note(.waitForSync, at: at(StuckGateWatch.threshold + 1))
        let reported = watch.note(.waitForSync, at: at(2 * StuckGateWatch.threshold + 1))
        #expect(!open && !restarted)
        #expect(reported)
    }
}
