import CloudKit
import Foundation
import Testing
@testable import HowyCore

/// Which CloudKit errors are silent and which notify, and the "once per incident" and "over an
/// hour" rules (`SyncError.kind`, `SyncIncidents`).
@Suite struct SyncIncidentsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    static func ck(_ code: CKError.Code, _ description: String = "CloudKit error") -> SyncError {
        SyncError(domain: CKError.errorDomain, code: code.rawValue, description: description)
    }

    /// A Core Data error wrapping a CloudKit one, as mirroring reports it.
    static func wrapped(_ code: CKError.Code) -> SyncError {
        SyncError(domain: NSCocoaErrorDomain, code: 134_400, description: "Mirroring failed", underlyingCloudKitCode: code.rawValue)
    }

    /// The end of a failed or successful event.
    func end(_ kind: SyncEvent.Kind, at seconds: TimeInterval, error: SyncError? = nil) -> SyncEvent {
        SyncEvent(id: UUID(), kind: kind, startDate: at(seconds - 1), endDate: at(seconds), succeeded: error == nil, error: error)
    }

    // MARK: Classification

    @Test(arguments: [
        CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
        .zoneBusy, .accountTemporarilyUnavailable, .serverResponseLost, .operationCancelled,
    ])
    func offlineAndBusyErrorsAreSilent(code: CKError.Code) {
        #expect(Self.ck(code).kind == .silent)
        #expect(Self.wrapped(code).kind == .silent)
    }

    @Test func accountErrorsAreLeftToTheAccountCheck() {
        #expect(Self.ck(.notAuthenticated).kind == .account)
        #expect(Self.wrapped(.managedAccountRestricted).kind == .account)
    }

    @Test func quotaAndDeletedZoneHaveTheirOwnKinds() {
        #expect(Self.ck(.quotaExceeded).kind == .quotaExceeded)
        #expect(Self.wrapped(.quotaExceeded).kind == .quotaExceeded)
        #expect(Self.ck(.userDeletedZone).kind == .zoneDeleted)
    }

    @Test(arguments: [
        CKError.Code.internalError, .missingEntitlement, .badContainer, .permissionFailure, .unknownItem,
        .invalidArguments, .serverRejectedRequest, .zoneNotFound, .incompatibleVersion, .limitExceeded,
    ])
    func otherCloudKitErrorsCountTowardsAPersistentFailure(code: CKError.Code) {
        #expect(Self.ck(code).kind == .persistent)
    }

    @Test func anErrorOutsideCloudKitCountsTowardsAPersistentFailure() {
        let error = SyncError(domain: NSCocoaErrorDomain, code: 134_060, description: "A Core Data error occurred.")
        #expect(error.kind == .persistent)
    }

    @Test func aPartialFailureIsClassifiedByTheWorstItemError() {
        var partial = Self.ck(.partialFailure)
        partial.partialCloudKitCodes = [CKError.Code.batchRequestFailed.rawValue, CKError.Code.quotaExceeded.rawValue]
        #expect(partial.kind == .quotaExceeded)
        partial.partialCloudKitCodes = [CKError.Code.quotaExceeded.rawValue, CKError.Code.userDeletedZone.rawValue]
        #expect(partial.kind == .zoneDeleted)
        partial.partialCloudKitCodes = [CKError.Code.networkFailure.rawValue]
        #expect(partial.kind == .silent)
    }

    @Test func aPartialFailureIsReadOffTheNSError() {
        let item = NSError(domain: CKError.errorDomain, code: CKError.Code.quotaExceeded.rawValue)
        let partial = NSError(
            domain: CKError.errorDomain, code: CKError.Code.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: ["record-1": item]]
        )
        let mirroring = NSError(domain: NSCocoaErrorDomain, code: 134_400, userInfo: [NSUnderlyingErrorKey: partial])
        let error = SyncError(mirroring)
        #expect(error.partialCloudKitCodes == [CKError.Code.quotaExceeded.rawValue])
        #expect(error.kind == .quotaExceeded)
    }

    // MARK: Silent errors

    @Test func offlineNeverNotifiesHoweverLongItLasts() {
        var incidents = SyncIncidents()
        for minute in stride(from: 0, through: 300, by: 5) {
            let alerts = incidents.record(end(.export, at: TimeInterval(minute * 60), error: Self.ck(.networkUnavailable)), at: at(TimeInterval(minute * 60)))
            #expect(alerts.isEmpty)
        }
        #expect(incidents.tick(at: at(6 * 3600)).isEmpty)
    }

    @Test func accountErrorsNeverNotifyFromTheEvents() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.setup, at: 0, error: Self.ck(.notAuthenticated)), at: at(0))
        #expect(incidents.tick(at: at(2 * 3600)).isEmpty)
    }

    // MARK: Persistent failure

    @Test func aFailureThatLastsOverAnHourNotifiesOnce() {
        var incidents = SyncIncidents()
        #expect(incidents.record(end(.export, at: 0, error: Self.ck(.internalError, "Server error")), at: at(0)).isEmpty)
        #expect(incidents.record(end(.export, at: 1800, error: Self.ck(.internalError)), at: at(1800)).isEmpty)
        #expect(incidents.tick(at: at(3599)).isEmpty, "not yet an hour")
        let alerts = incidents.tick(at: at(3601))
        #expect(alerts.count == 1)
        guard case .failing = alerts.first else {
            Issue.record("expected a failing alert, got \(alerts)")
            return
        }
        #expect(incidents.record(end(.export, at: 4000, error: Self.ck(.internalError)), at: at(4000)).isEmpty, "once per incident")
        #expect(incidents.tick(at: at(8000)).isEmpty)
    }

    @Test func aFailureNotifiesFromTheEventThatPassesTheHourToo() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.import, at: 0, error: Self.ck(.zoneNotFound)), at: at(0))
        let alerts = incidents.record(end(.import, at: 3700, error: Self.ck(.zoneNotFound)), at: at(3700))
        #expect(alerts.count == 1)
    }

    @Test func aSuccessEndsTheIncident() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.export, at: 0, error: Self.ck(.internalError)), at: at(0))
        _ = incidents.record(end(.import, at: 3000), at: at(3000))
        #expect(incidents.tick(at: at(3700)).isEmpty, "the clock started again")
        _ = incidents.record(end(.export, at: 3800, error: Self.ck(.internalError)), at: at(3800))
        #expect(incidents.tick(at: at(3800 + 3601)).count == 1, "a new incident")
    }

    @Test func aSuccessfulSetupAloneDoesNotEndTheIncident() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.export, at: 0, error: Self.ck(.internalError)), at: at(0))
        _ = incidents.record(end(.setup, at: 100), at: at(100))
        #expect(incidents.tick(at: at(3601)).count == 1)
    }

    @Test func offlineAtTheMomentHoldsTheAlertBack() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.export, at: 0, error: Self.ck(.internalError)), at: at(0))
        _ = incidents.record(end(.export, at: 600, error: Self.ck(.networkUnavailable)), at: at(600))
        #expect(incidents.tick(at: at(4000)).isEmpty, "offline now: being offline never notifies")
        let back = incidents.record(end(.export, at: 4100, error: Self.ck(.internalError)), at: at(4100))
        #expect(back.count == 1, "still failing once back online, still the same incident")
    }

    @Test func aRepeatedIncidentWithinADayDoesNotNotifyAgain() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.export, at: 0, error: Self.ck(.internalError)), at: at(0))
        #expect(incidents.tick(at: at(3601)).count == 1)
        _ = incidents.record(end(.export, at: 3700), at: at(3700))
        _ = incidents.record(end(.export, at: 3800, error: Self.ck(.internalError)), at: at(3800))
        #expect(incidents.tick(at: at(3800 + 3601)).isEmpty, "within a day of the last one")
        #expect(incidents.tick(at: at(3601 + SyncIncidents.repeatCooldown)).count == 1)
    }

    @Test func theCooldownSurvivesARelaunch() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.export, at: 0, error: Self.ck(.internalError)), at: at(0))
        #expect(incidents.tick(at: at(3601)).count == 1)
        var relaunched = SyncIncidents(lastPosted: incidents.lastPosted)
        _ = relaunched.record(end(.export, at: 4000, error: Self.ck(.internalError)), at: at(4000))
        #expect(relaunched.tick(at: at(4000 + 3601)).isEmpty)
    }

    // MARK: Storage full

    @Test func storageFullNotifiesRightAwayAndOncePerIncident() {
        var incidents = SyncIncidents()
        #expect(incidents.record(end(.export, at: 0, error: Self.ck(.quotaExceeded)), at: at(0)) == [.storageFull])
        #expect(incidents.record(end(.export, at: 60, error: Self.wrapped(.quotaExceeded)), at: at(60)).isEmpty)
        #expect(incidents.tick(at: at(7200)).isEmpty, "storage full is not also a failing alert")
    }

    @Test func storageFullEndsWithASuccessfulExportOnly() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.export, at: 0, error: Self.ck(.quotaExceeded)), at: at(0))
        _ = incidents.record(end(.import, at: 100), at: at(100))
        #expect(incidents.record(end(.export, at: 200, error: Self.ck(.quotaExceeded)), at: at(200)).isEmpty, "an import doesn't end it")
        _ = incidents.record(end(.export, at: 300), at: at(300))
        let later = SyncIncidents.repeatCooldown + 400
        #expect(incidents.record(end(.export, at: later, error: Self.ck(.quotaExceeded)), at: at(later)) == [.storageFull])
    }

    // MARK: Data removed

    @Test func aDeletedZoneNotifiesThatTheDataWasRemoved() {
        var incidents = SyncIncidents()
        #expect(incidents.record(end(.import, at: 0, error: Self.ck(.userDeletedZone)), at: at(0)) == [.dataRemoved(.iCloudDataDeleted)])
        #expect(incidents.record(end(.export, at: 30, error: Self.ck(.userDeletedZone)), at: at(30)).isEmpty, "once per incident")
        _ = incidents.record(end(.import, at: 60), at: at(60))
        let later = SyncIncidents.dataRemovedDedupe + 100
        #expect(incidents.record(end(.import, at: later, error: Self.ck(.userDeletedZone)), at: at(later)) == [.dataRemoved(.iCloudDataDeleted)])
    }

    @Test(arguments: [AccountChange.signedOut, .switched])
    func anAccountChangeNotifiesThatTheDataWasRemoved(change: AccountChange) {
        var incidents = SyncIncidents()
        let expected: SyncAlert = change == .signedOut ? .dataRemoved(.signedOut) : .dataRemoved(.accountSwitched)
        #expect(incidents.accountChanged(change, at: at(0)) == [expected])
    }

    @Test func aDeletedZoneRightAfterASignOutDoesNotNotifyTwice() {
        var incidents = SyncIncidents()
        _ = incidents.accountChanged(.signedOut, at: at(0))
        #expect(incidents.record(end(.setup, at: 10, error: Self.ck(.userDeletedZone)), at: at(10)).isEmpty)
    }

    @Test func anAccountChangeEndsTheOpenIncidents() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.export, at: 0, error: Self.ck(.internalError)), at: at(0))
        _ = incidents.accountChanged(.switched, at: at(100))
        #expect(incidents.tick(at: at(3700)).isEmpty)
    }

    @Test func noAccountEndsTheFailureIncident() {
        var incidents = SyncIncidents()
        _ = incidents.record(end(.export, at: 0, error: Self.ck(.internalError)), at: at(0))
        incidents.accountUnavailable()
        #expect(incidents.tick(at: at(3700)).isEmpty)
    }

    // MARK: Texts

    @Test func everyAlertNamesTheBackupWhenDataWasRemoved() {
        for cause in [DataRemovalCause.signedOut, .accountSwitched, .iCloudDataDeleted] {
            let alert = SyncAlert.dataRemoved(cause)
            #expect(alert.body.contains("Settings → Import & Export"))
            #expect(alert.identifier.hasPrefix(SyncAlert.identifierPrefix))
        }
        #expect(SyncAlert.failing(reason: "iCloud internal error").body.contains("iCloud internal error"))
        #expect(SyncAlert.storageFull.identifier != SyncAlert.failing(reason: "x").identifier)
    }
}
