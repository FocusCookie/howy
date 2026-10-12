import CloudKit
import Foundation
import Testing
@testable import HowyCore

/// The one status line in Settings (`SyncStatus`), from the sync state and the account.
@Suite struct SyncStatusTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func state(_ mode: SyncState.Mode = .iCloud, events: [SyncEvent] = []) -> SyncState {
        var state = SyncState(mode: mode, startedAt: start)
        for event in events { state.apply(event, at: event.endDate ?? event.startDate) }
        return state
    }

    func done(_ kind: SyncEvent.Kind, at seconds: TimeInterval, error: CKError.Code? = nil) -> [SyncEvent] {
        let id = UUID()
        let failure = error.map { SyncError(domain: CKError.errorDomain, code: $0.rawValue, description: "CloudKit said no") }
        return [
            SyncEvent(id: id, kind: kind, startDate: at(seconds - 1)),
            SyncEvent(id: id, kind: kind, startDate: at(seconds - 1), endDate: at(seconds), succeeded: failure == nil, error: failure),
        ]
    }

    let signedIn = AccountObservation.available(userRecordName: "_alice")

    @Test func upToDateAfterASuccessfulSync() {
        let status = SyncStatus(state: state(events: done(.import, at: 10) + done(.export, at: 20)), account: signedIn, now: at(30))
        #expect(status == .upToDate(lastSync: at(20)))
        #expect(!status.isProblem)
    }

    @Test func syncingWhileAnEventRuns() {
        let running = [SyncEvent(id: UUID(), kind: .import, startDate: at(10))]
        #expect(SyncStatus(state: state(events: running), account: signedIn, now: at(11)) == .syncing)
    }

    @Test func checkingUntilTheStoreAndTheAccountAreKnown() {
        #expect(SyncStatus(state: state(.starting), account: nil, now: at(1)) == .checking)
        #expect(SyncStatus(state: state(), account: nil, now: at(1)) == .checking)
    }

    @Test func notSignedInIsLocalOnlyNotAnError() {
        let status = SyncStatus(state: state(events: done(.setup, at: 5, error: .notAuthenticated)), account: .noAccount, now: at(10))
        #expect(status == .notSignedIn)
        #expect(!status.isProblem)
        #expect(status.title.contains("Not signed in"))
        #expect(status.detail?.contains("this Mac") == true)
    }

    @Test func iCloudOffForHowyIsLocalOnlyToo() {
        let status = SyncStatus(state: state(), account: .iCloudOffForApp, now: at(1))
        #expect(status == .iCloudOff)
        #expect(!status.isProblem)
    }

    @Test func offlineIsNotAnError() {
        let status = SyncStatus(state: state(events: done(.export, at: 5, error: .networkUnavailable)), account: signedIn, now: at(10))
        #expect(status == .offline)
        #expect(!status.isProblem)
    }

    @Test func aBusyServerIsWaitingNotAnError() {
        let status = SyncStatus(state: state(events: done(.export, at: 5, error: .requestRateLimited)), account: signedIn, now: at(10))
        #expect(status == .waiting)
        #expect(!status.isProblem)
    }

    @Test func storageFullIsAnErrorWithAShortReason() {
        let status = SyncStatus(state: state(events: done(.export, at: 5, error: .quotaExceeded)), account: signedIn, now: at(10))
        #expect(status == .error(reason: "iCloud storage is full"))
        #expect(status.isProblem)
    }

    @Test func otherErrorsShowAShortReason() {
        let status = SyncStatus(state: state(events: done(.import, at: 5, error: .badContainer)), account: signedIn, now: at(10))
        guard case .error(let reason) = status else {
            Issue.record("expected an error, got \(status)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(status.title.hasPrefix("Sync error"))
    }

    @Test func anErrorClearedByASuccessIsUpToDateAgain() {
        let events = done(.export, at: 5, error: .internalError) + done(.export, at: 20)
        #expect(SyncStatus(state: state(events: events), account: signedIn, now: at(30)) == .upToDate(lastSync: at(20)))
    }

    @Test func theCloudKitFallbackIsAnError() {
        let status = SyncStatus(state: state(.unavailable(reason: "missing entitlement")), account: signedIn, now: at(1))
        #expect(status == .unavailable(reason: "missing entitlement"))
        #expect(status.isProblem)
    }

    @Test func aStoreThatDoesNotMirrorSaysSo() {
        #expect(SyncStatus(state: state(.local), account: nil, now: at(1)) == .off)
    }

    @Test func restrictedAndTemporarilyUnavailableAccounts() {
        #expect(SyncStatus(state: state(), account: .restricted, now: at(1)) == .restricted)
        #expect(SyncStatus(state: state(), account: .restricted, now: at(1)).isProblem)
        #expect(SyncStatus(state: state(), account: .temporarilyUnavailable, now: at(1)) == .waiting)
    }

    @Test func everyStatusHasATitle() {
        let all: [SyncStatus] = [
            .checking, .syncing, .upToDate(lastSync: nil), .upToDate(lastSync: start), .offline, .waiting,
            .notSignedIn, .iCloudOff, .restricted, .error(reason: "x"), .unavailable(reason: "y"), .off,
        ]
        for status in all { #expect(!status.title.isEmpty) }
    }
}
