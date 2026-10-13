import CloudKit
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
    static let noAccount = SyncError(domain: "CKErrorDomain", code: CKError.Code.notAuthenticated.rawValue, description: "Not authenticated")
    static let offline = SyncError(domain: "CKErrorDomain", code: CKError.Code.networkUnavailable.rawValue, description: "Network unavailable")

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
        let failed = event(.setup, from: 0, to: 1, succeeded: false, error: Self.noAccount)
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

    @Test(arguments: [MaintenanceWork.cleanups, .purge])
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
        let setup = event(.setup, from: 0, to: 1, succeeded: false, error: Self.noAccount)
        state.apply(setup.0, at: at(0))
        state.apply(setup.1, at: at(1))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(2)) == .waitUntil(at(31)))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(31)) == .open)
    }

    // MARK: Review fixes: setup failures

    @Test func aTransientSetupFailureDoesNotOpenTheGate() {
        var state = SyncState(mode: .iCloud)
        let setup = event(.setup, from: 0, to: 1, succeeded: false, error: Self.offline)
        state.apply(setup.0, at: at(0))
        state.apply(setup.1, at: at(1))
        #expect(!state.setupFailed)
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(500)) == .waitForSync)
    }

    @Test func aSetupFailureWithoutAnErrorDoesNotOpenTheGate() {
        var state = SyncState(mode: .iCloud)
        let setup = event(.setup, from: 0, to: 1, succeeded: false)
        state.apply(setup.0, at: at(0))
        state.apply(setup.1, at: at(1))
        #expect(!state.setupFailed)
    }

    @Test(arguments: [CKError.Code.notAuthenticated, .badContainer, .missingEntitlement, .permissionFailure, .managedAccountRestricted])
    func accountAndEntitlementErrorsAreSetupProblems(code: CKError.Code) {
        let error = SyncError(domain: "CKErrorDomain", code: code.rawValue, description: "")
        #expect(error.isAccountOrEntitlementProblem)
    }

    @Test(arguments: [CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .quotaExceeded,
                      .partialFailure, .zoneBusy, .accountTemporarilyUnavailable])
    func transientErrorsAreNotSetupProblems(code: CKError.Code) {
        let error = SyncError(domain: "CKErrorDomain", code: code.rawValue, description: "")
        #expect(!error.isAccountOrEntitlementProblem)
    }

    @Test func aWrappedCloudKitErrorIsRecognised() {
        let inner = NSError(domain: "CKErrorDomain", code: CKError.Code.notAuthenticated.rawValue)
        let outer = NSError(domain: NSCocoaErrorDomain, code: 134400, userInfo: [NSUnderlyingErrorKey: inner])
        let error = SyncError(outer)
        #expect(error.cloudKitCode == .notAuthenticated)
        #expect(error.isAccountOrEntitlementProblem)
        #expect(!SyncError(domain: NSCocoaErrorDomain, code: 134400, description: "").isAccountOrEntitlementProblem)
    }

    // MARK: Review fixes: imports that count

    @Test func anImportThatStartedBeforeTheWakeDoesNotCount() {
        var state = SyncState(mode: .iCloud, startedAt: at(0))
        let first = event(.import, from: 0, to: 1)
        state.apply(first.0, at: at(0))
        state.apply(first.1, at: at(1))
        #expect(state.firstImportDone)

        state.noteWake(at: at(100))
        #expect(!state.firstImportDone)
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(200)) == .waitForSync)

        // Started at 90, before the wake, ended after it: it may have read the store before
        // everything that arrived during sleep.
        let early = event(.import, from: 90, to: 110)
        state.apply(early.0, at: at(110))
        state.apply(early.1, at: at(110))
        #expect(!state.firstImportDone)

        let after = event(.import, from: 120, to: 125)
        state.apply(after.0, at: at(120))
        state.apply(after.1, at: at(125))
        #expect(state.firstImportDone)
    }

    @Test func aNewSetupResetsTheFirstImport() {
        var state = SyncState(mode: .iCloud)
        let imp = event(.import, from: 0, to: 1)
        state.apply(imp.0, at: at(0))
        state.apply(imp.1, at: at(1))
        #expect(state.firstImportDone)
        let setup = event(.setup, from: 10, to: 11)
        state.apply(setup.0, at: at(10))
        #expect(!state.firstImportDone, "an account change can bring everything again")
        state.apply(setup.1, at: at(11))
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(100)) == .waitForSync)
    }

    @Test func anEventWithoutAnEndIsStaleAfterTenMinutes() {
        var state = SyncState(mode: .iCloud)
        let imp = event(.import, from: 0, to: 1)
        state.apply(imp.1, at: at(1))
        state.noteWake(at: at(2))
        let lost = event(.export, from: 5, to: 6)
        state.apply(lost.0, at: at(5)) // the end never comes
        let later = event(.import, from: 10, to: 11)
        state.apply(later.0, at: at(10))
        state.apply(later.1, at: at(11))
        #expect(state.firstImportDone)
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(300)) == .waitForSync, "still in flight at 5 minutes")
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(5 + 600)) == .open, "stale at 10 minutes")
        #expect(state.isBusy(at: at(100)))
        #expect(!state.isBusy(at: at(605)))
    }

    // MARK: Review fixes: the gates

    @Test func theMonitorStartsUnknownUntilTheContainerIsBuilt() {
        var state = SyncState(mode: .starting, startedAt: at(0))
        for work in [MaintenanceWork.cleanups, .purge] {
            #expect(SyncGate.decide(work, sync: state, retentionKnown: true, now: at(100)) == .waitForSync)
        }
        // Events that arrive early (a deep link built the store first) are not lost.
        let imp = event(.import, from: 1, to: 2)
        state.apply(imp.0, at: at(1))
        state.apply(imp.1, at: at(2))
        #expect(state.firstImportDone)
        state.mode = .iCloud
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(100)) == .open)
    }

    @Test func theBackupGateIsRelaxed() {
        var state = SyncState(mode: .iCloud, startedAt: at(0))
        // No event yet: not before launch + 10 min.
        #expect(SyncGate.decide(.backup, sync: state, retentionKnown: true, now: at(5)) == .waitUntil(at(600)))
        // An event came: quiet after 30 s, no import needed.
        let setup = event(.setup, from: 1, to: 2)
        state.apply(setup.0, at: at(1))
        #expect(SyncGate.decide(.backup, sync: state, retentionKnown: true, now: at(10)) == .waitUntil(at(600)), "in flight")
        state.apply(setup.1, at: at(2))
        #expect(SyncGate.decide(.backup, sync: state, retentionKnown: true, now: at(10)) == .waitUntil(at(32)))
        #expect(SyncGate.decide(.backup, sync: state, retentionKnown: true, now: at(32)) == .open)
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(32)) == .waitForSync, "cleanups still need an import")
    }

    @Test func theBackupFailsOpenAfterTenMinutesWhateverSyncDoes() {
        var state = SyncState(mode: .iCloud, startedAt: at(0))
        let stuck = event(.import, from: 1, to: 2)
        state.apply(stuck.0, at: at(1))
        #expect(SyncGate.decide(.backup, sync: state, retentionKnown: true, now: at(599)) == .waitUntil(at(600)))
        #expect(SyncGate.decide(.backup, sync: state, retentionKnown: true, now: at(600)) == .open)
        #expect(SyncGate.decide(.cleanups, sync: state, retentionKnown: true, now: at(601)) == .waitForSync)
    }

    @Test func aWakeDoesNotCloseTheBackupGate() {
        var state = SyncState(mode: .iCloud, startedAt: at(0))
        let imp = event(.import, from: 0, to: 1)
        state.apply(imp.0, at: at(0))
        state.apply(imp.1, at: at(1))
        state.noteWake(at: at(1000))
        #expect(SyncGate.decide(.backup, sync: state, retentionKnown: true, now: at(1000)) == .open)
        #expect(SyncGate.decide(.purge, sync: state, retentionKnown: true, now: at(1000)) == .waitForSync, "purge needs an import after the wake")
    }

    @Test func theMonitorNotesAWake() {
        var now = start
        let monitor = SyncMonitor(mode: .iCloud, now: { now })
        let imp = event(.import, from: 0, to: 1)
        monitor.receive(imp.0)
        monitor.receive(imp.1)
        #expect(monitor.state.firstImportDone)
        now = at(500)
        monitor.noteWake()
        #expect(!monitor.state.firstImportDone)
    }

    @Test func theMonitorsModeComesFromTheBuiltContainer() {
        #expect(SyncMonitor.mode(sync: .local, fallbackReason: nil, isBuilt: false) == .starting)
        #expect(SyncMonitor.mode(sync: .local, fallbackReason: "x", isBuilt: true) == .unavailable(reason: "x"))
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
