import Foundation
import Testing
@testable import HowyCore

/// The sync state as mirroring events change it, and the gate that holds back maintenance.
@MainActor
@Suite struct SyncStateTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// The start and the end of one event.
    func event(_ kind: SyncEvent.Kind, from: TimeInterval, to: TimeInterval, succeeded: Bool = true, error: SyncError? = nil) -> (SyncEvent, SyncEvent) {
        let id = UUID()
        return (
            SyncEvent(id: id, kind: kind, startDate: at(from)),
            SyncEvent(id: id, kind: kind, startDate: at(from), endDate: at(to), succeeded: succeeded, error: error)
        )
    }

    static let quota = SyncError(domain: "CKErrorDomain", code: 25, description: "Quota exceeded")

    // MARK: State

    @Test func phasesFollowTheEventsInFlight() {
        var state = SyncState(mode: .iCloud)
        #expect(state.phase == .idle)
        let setup = event(.setup, from: 0, to: 1)
        let imp = event(.import, from: 1, to: 3)
        let exp = event(.export, from: 2, to: 4)
        state.apply(setup.0, at: at(0))
        #expect(state.phase == .settingUp)
        state.apply(setup.1, at: at(1))
        state.apply(imp.0, at: at(1))
        state.apply(exp.0, at: at(2))
        #expect(state.phase == .importing, "an import counts before an export")
        state.apply(imp.1, at: at(3))
        #expect(state.phase == .exporting)
        state.apply(exp.1, at: at(4))
        #expect(state.phase == .idle)
        #expect(!state.isBusy)
    }

    @Test func aSuccessfulImportIsReportedAndRemembered() {
        var state = SyncState(mode: .iCloud)
        let imp = event(.import, from: 0, to: 2)
        let started = state.apply(imp.0, at: at(0))
        #expect(!started)
        #expect(!state.firstImportDone)
        let imported = state.apply(imp.1, at: at(2))
        #expect(imported)
        #expect(state.firstImportDone)
        #expect(state.lastImport == at(2))
        #expect(state.lastEventDate == at(2))
    }

    @Test func aFailedImportIsNotDoneAndKeepsItsError() {
        var state = SyncState(mode: .iCloud)
        let imp = event(.import, from: 0, to: 2, succeeded: false, error: Self.quota)
        state.apply(imp.0, at: at(0))
        let imported = state.apply(imp.1, at: at(2))
        #expect(!imported)
        #expect(!state.firstImportDone)
        #expect(state.lastImport == nil)
        #expect(state.lastError == Self.quota)
        #expect(state.lastError?.cloudKitCode == .quotaExceeded)
        #expect(state.lastErrorDate == at(2))
        #expect(!state.isBusy)
    }

    @Test func aSuccessfulExportClearsTheError() {
        var state = SyncState(mode: .iCloud)
        let failed = event(.export, from: 0, to: 1, succeeded: false, error: Self.quota)
        let good = event(.export, from: 5, to: 6)
        state.apply(failed.0, at: at(0))
        state.apply(failed.1, at: at(1))
        state.apply(good.0, at: at(5))
        state.apply(good.1, at: at(6))
        #expect(state.lastError == nil)
        #expect(state.lastExport == at(6))
    }

    @Test func aFailedSetupIsRememberedUntilTheNextSetupStarts() {
        var state = SyncState(mode: .iCloud)
        let failed = event(.setup, from: 0, to: 1, succeeded: false)
        state.apply(failed.0, at: at(0))
        state.apply(failed.1, at: at(1))
        #expect(state.setupFailed)
        let again = event(.setup, from: 10, to: 11)
        state.apply(again.0, at: at(10))
        #expect(!state.setupFailed)
    }

    @Test func anEndBeforeItsStartLeavesNothingInFlight() {
        var state = SyncState(mode: .iCloud)
        let imp = event(.import, from: 0, to: 1)
        state.apply(imp.1, at: at(1))
        state.apply(imp.0, at: at(1))
        #expect(!state.isBusy)
        #expect(state.firstImportDone)
    }

    @Test(arguments: [SyncState.Mode.local, .unavailable(reason: "no entitlement")])
    func eventsAreIgnoredWithoutMirroring(mode: SyncState.Mode) {
        var state = SyncState(mode: mode)
        let imp = event(.import, from: 0, to: 1)
        state.apply(imp.0, at: at(0))
        let imported = state.apply(imp.1, at: at(1))
        #expect(!imported)
        #expect(state.lastEventDate == nil)
        #expect(!state.firstImportDone)
    }

    @Test func theModeFollowsHowTheStoreOpened() {
        let iCloud = StoreSync.iCloud(containerIdentifier: StoreSync.containerIdentifier)
        #expect(SyncMonitor.mode(sync: iCloud, fallbackReason: nil) == .iCloud)
        #expect(SyncMonitor.mode(sync: .local, fallbackReason: nil) == .local)
        #expect(SyncMonitor.mode(sync: .local, fallbackReason: "boom") == .unavailable(reason: "boom"))
    }

    // MARK: Gate

    @Test(arguments: MaintenanceWork.allCases)
    func withoutMirroringTheGateIsOpen(work: MaintenanceWork) {
        for mode in [SyncState.Mode.local, .unavailable(reason: "x")] {
            #expect(SyncGate.decide(work, sync: SyncState(mode: mode), retentionKnown: true, now: start) == .open)
        }
    }

    @Test func thePurgeWaitsForTheRetentionEvenLocally() {
        #expect(SyncGate.decide(.purge, sync: SyncState(mode: .local), retentionKnown: false, now: start) == .waitForRetention)
        #expect(SyncGate.decide(.cleanups, sync: SyncState(mode: .local), retentionKnown: false, now: start) == .open)
    }

    @Test(arguments: MaintenanceWork.allCases)
    func mirroringWaitsForTheFirstImport(work: MaintenanceWork) {
        var state = SyncState(mode: .iCloud)
        #expect(SyncGate.decide(work, sync: state, retentionKnown: true, now: start) == .waitForSync)
        let setup = event(.setup, from: 0, to: 1)
        state.apply(setup.0, at: at(0))
        state.apply(setup.1, at: at(1))
        #expect(SyncGate.decide(work, sync: state, retentionKnown: true, now: at(100)) == .waitForSync)
    }

    @Test func mirroringOpensAQuietPeriodAfterTheFirstImport() {
        var state = SyncState(mode: .iCloud)
        let imp = event(.import, from: 0, to: 5)
        state.apply(imp.0, at: at(0))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(100)) == .waitForSync, "in flight")
        state.apply(imp.1, at: at(5))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(10)) == .waitUntil(at(35)))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(35)) == .open)
        #expect(SyncGate.decide(.backup, sync: state, retentionKnown: true, now: at(35)) == .open)
        #expect(SyncGate.decide(.purge, sync: state, retentionKnown: false, now: at(35)) == .waitForRetention)
        #expect(SyncGate.decide(.purge, sync: state, retentionKnown: true, now: at(35)) == .open)
    }

    @Test func anyLaterEventClosesTheGateAgain() {
        var state = SyncState(mode: .iCloud)
        let imp = event(.import, from: 0, to: 1)
        state.apply(imp.0, at: at(0))
        state.apply(imp.1, at: at(1))
        let exp = event(.export, from: 40, to: 42)
        state.apply(exp.0, at: at(40))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(41)) == .waitForSync)
        state.apply(exp.1, at: at(42))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(50)) == .waitUntil(at(72)))
    }

    @Test func aFailedImportKeepsTheGateClosed() {
        var state = SyncState(mode: .iCloud)
        let imp = event(.import, from: 0, to: 1, succeeded: false)
        state.apply(imp.0, at: at(0))
        state.apply(imp.1, at: at(1))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(1000)) == .waitForSync)
    }

    @Test func aFailedSetupOpensTheGateAfterTheQuietPeriod() {
        // No account, say: nothing will arrive until a new setup, so there is nothing to wait for.
        var state = SyncState(mode: .iCloud)
        let setup = event(.setup, from: 0, to: 1, succeeded: false)
        state.apply(setup.0, at: at(0))
        state.apply(setup.1, at: at(1))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(2)) == .waitUntil(at(31)))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(31)) == .open)
    }

    // MARK: Monitor

    @Test func theMonitorReportsImportsAndEveryChange() {
        var now = start
        let monitor = SyncMonitor(mode: .iCloud, now: { now })
        var imports = 0
        var changes = 0
        monitor.onImport = { imports += 1 }
        monitor.onChange = { changes += 1 }
        let imp = event(.import, from: 0, to: 2)
        monitor.receive(imp.0)
        now = at(2)
        monitor.receive(imp.1)
        #expect(imports == 1)
        #expect(changes == 2)
        #expect(monitor.state.lastEventDate == at(2))
        #expect(monitor.gate(.cleanups, retentionKnown: true) == .waitUntil(at(32)))
        now = at(32)
        #expect(monitor.gate(.cleanups, retentionKnown: true) == .open)
        monitor.setMode(.unavailable(reason: "x"))
        #expect(changes == 3)
    }
}
