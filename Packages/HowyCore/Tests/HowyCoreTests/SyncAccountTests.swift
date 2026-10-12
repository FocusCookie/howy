import CloudKit
import Foundation
import Testing
@testable import HowyCore

/// Telling a sign-out and an account switch from the remembered account (`SyncAccountTracker`),
/// and the monitor posting the alerts once the store really mirrors.
@MainActor
@Suite struct SyncAccountTests {
    final class Memory: KeyValueStoring {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Tracker

    @Test func theFirstAccountSeenIsRememberedQuietly() {
        var tracker = SyncAccountTracker()
        #expect(tracker.observe(.available(userRecordName: "_alice")) == nil)
        #expect(tracker.remembered == "_alice")
        #expect(tracker.observe(.available(userRecordName: "_alice")) == nil)
    }

    @Test func anotherAccountIsASwitch() {
        var tracker = SyncAccountTracker(remembered: "_alice")
        #expect(tracker.observe(.available(userRecordName: "_bob")) == .switched)
        #expect(tracker.remembered == "_bob")
        #expect(tracker.observe(.available(userRecordName: "_bob")) == nil)
    }

    @Test(arguments: [AccountObservation.noAccount, .iCloudOffForApp, .restricted])
    func losingTheAccountIsASignOut(observation: AccountObservation) {
        var tracker = SyncAccountTracker(remembered: "_alice")
        #expect(tracker.observe(observation) == .signedOut)
        #expect(tracker.remembered == nil)
        #expect(tracker.observe(observation) == nil, "once")
        #expect(tracker.observe(.available(userRecordName: "_alice")) == nil, "signing back in brings the data back")
    }

    @Test(arguments: [AccountObservation.temporarilyUnavailable, .couldNotDetermine, .available(userRecordName: nil)])
    func anUncertainStatusChangesNothing(observation: AccountObservation) {
        var tracker = SyncAccountTracker(remembered: "_alice")
        #expect(tracker.observe(observation) == nil)
        #expect(tracker.remembered == "_alice")
    }

    @Test func noAccountWithoutARememberedOneIsNoSignOut() {
        var tracker = SyncAccountTracker()
        #expect(tracker.observe(.noAccount) == nil)
    }

    // MARK: Monitor

    @Test func theMonitorRemembersTheAccountPerStoreFile() {
        let defaults = Memory()
        let monitor = SyncMonitor(mode: .iCloud, now: { self.start }, defaults: defaults, storeFileName: "Howy.store")
        monitor.receiveAccount(.available(userRecordName: "_alice"))
        #expect(defaults.values[SyncMonitor.accountKey(storeFileName: "Howy.store")] as? String == "_alice")
        #expect(defaults.values[SyncMonitor.accountKey(storeFileName: "Howy-Debug.store")] == nil)

        var alerts: [SyncAlert] = []
        let relaunched = SyncMonitor(mode: .iCloud, now: { self.start }, defaults: defaults, storeFileName: "Howy.store")
        relaunched.onAlert = { alerts.append($0) }
        relaunched.receiveAccount(.noAccount)
        #expect(alerts == [.dataRemoved(.signedOut)], "signed out while Howy wasn't running")
    }

    @Test func theAccountIsOnlyComparedOnceTheStoreMirrors() {
        let defaults = Memory()
        defaults.values[SyncMonitor.accountKey(storeFileName: "Howy.store")] = "_alice"
        var alerts: [SyncAlert] = []
        let monitor = SyncMonitor(mode: .starting, now: { self.start }, defaults: defaults, storeFileName: "Howy.store")
        monitor.onAlert = { alerts.append($0) }
        monitor.receiveAccount(.available(userRecordName: "_bob"))
        #expect(alerts.isEmpty, "the store isn't open yet")
        #expect(defaults.values[SyncMonitor.accountKey(storeFileName: "Howy.store")] as? String == "_alice")
        monitor.setMode(.iCloud)
        #expect(alerts == [.dataRemoved(.accountSwitched)])
    }

    @Test func aLocalFallbackRunLeavesTheRememberedAccountAlone() {
        let defaults = Memory()
        defaults.values[SyncMonitor.accountKey(storeFileName: "Howy.store")] = "_alice"
        var alerts: [SyncAlert] = []
        let monitor = SyncMonitor(mode: .unavailable(reason: "boom"), now: { self.start }, defaults: defaults, storeFileName: "Howy.store")
        monitor.onAlert = { alerts.append($0) }
        monitor.receiveAccount(.available(userRecordName: "_bob"))
        #expect(alerts.isEmpty, "nothing was wiped: the store didn't mirror")
        #expect(defaults.values[SyncMonitor.accountKey(storeFileName: "Howy.store")] as? String == "_alice")
    }

    @Test func theMonitorPostsEventAlertsAndKeepsTheCooldown() {
        let defaults = Memory()
        var now = start
        var alerts: [SyncAlert] = []
        let monitor = SyncMonitor(mode: .iCloud, now: { now }, defaults: defaults, storeFileName: "Howy.store")
        monitor.onAlert = { alerts.append($0) }
        let quota = SyncError(domain: CKError.errorDomain, code: CKError.Code.quotaExceeded.rawValue, description: "Quota")
        monitor.receive(SyncEvent(id: UUID(), kind: .export, startDate: now, endDate: now, succeeded: false, error: quota))
        #expect(alerts == [.storageFull])

        let serverError = SyncError(domain: CKError.errorDomain, code: CKError.Code.internalError.rawValue, description: "Internal")
        monitor.receive(SyncEvent(id: UUID(), kind: .import, startDate: now, endDate: now, succeeded: false, error: serverError))
        now = start.addingTimeInterval(3601)
        monitor.tick()
        #expect(alerts.count == 2)

        let relaunched = SyncMonitor(mode: .iCloud, now: { now }, defaults: defaults, storeFileName: "Howy.store")
        var again: [SyncAlert] = []
        relaunched.onAlert = { again.append($0) }
        relaunched.receive(SyncEvent(id: UUID(), kind: .export, startDate: now, endDate: now, succeeded: false, error: quota))
        #expect(again.isEmpty, "the day's cooldown came from the defaults")
    }
}
