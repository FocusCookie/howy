import CloudKit
import Foundation
import Testing
@testable import HowyCore

/// Low Power Mode and sync: the hint under the Settings sync line (`SyncStatus.hint`,
/// `SyncMonitor.statusHint`) and the notification when it turns on (`SyncIncidents
/// .lowPowerModeChanged`, posted through `SyncMonitor.onAlert`).
@MainActor
@Suite struct SyncLowPowerModeTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let signedIn = AccountObservation.available(userRecordName: "_alice")

    func monitor(_ mode: SyncState.Mode = .iCloud, account: AccountObservation? = Self.signedIn) -> SyncMonitor {
        let monitor = SyncMonitor(mode: mode, now: { self.start })
        if let account { monitor.receiveAccount(account) }
        return monitor
    }

    // MARK: Hint

    @Test(arguments: [SyncStatus.syncing, .upToDate(lastSync: nil), .upToDate(lastSync: Date(timeIntervalSince1970: 1)), .waiting])
    func theHintShowsWhileSyncOtherwiseWorks(status: SyncStatus) {
        #expect(status.hint(lowPowerMode: true) == SyncStatus.lowPowerModeHint)
        #expect(status.hint(lowPowerMode: false) == nil)
    }

    @Test(arguments: [
        SyncStatus.checking, .offline, .notSignedIn, .iCloudOff, .restricted, .error(reason: "x"),
        .unavailable(reason: "y"), .off,
    ])
    func otherStatesKeepTheirOwnTextAndShowNoHint(status: SyncStatus) {
        #expect(status.hint(lowPowerMode: true) == nil)
    }

    @Test func theMonitorFollowsLowPowerModeWithoutChangingTheLine() {
        let monitor = monitor()
        #expect(monitor.statusHint == nil)
        let before = monitor.status
        monitor.receiveLowPowerMode(true)
        #expect(monitor.isLowPowerMode)
        #expect(monitor.status == before, "the line itself (and Last synced) stays")
        #expect(monitor.statusHint == SyncStatus.lowPowerModeHint)
        monitor.receiveNetwork(isOnline: false)
        #expect(monitor.status == .offline)
        #expect(monitor.statusHint == nil, "offline says so instead")
        monitor.receiveNetwork(isOnline: true)
        monitor.receiveLowPowerMode(false)
        #expect(monitor.statusHint == nil)
    }

    // MARK: Notification

    @Test func turningLowPowerModeOnNotifies() {
        let monitor = monitor()
        var alerts: [SyncAlert] = []
        monitor.onAlert = { alerts.append($0) }
        monitor.receiveLowPowerMode(false) // launch: off
        monitor.receiveLowPowerMode(true)
        #expect(alerts == [.lowPowerMode])
        #expect(SyncAlert.lowPowerMode.identifier.hasPrefix(SyncAlert.identifierPrefix), "a click opens Settings at the sync line")
    }

    @Test func everyTurnOnNotifiesButStayingOnDoesNot() {
        let monitor = monitor()
        var alerts: [SyncAlert] = []
        monitor.onAlert = { alerts.append($0) }
        monitor.receiveLowPowerMode(false)
        monitor.receiveLowPowerMode(true)
        monitor.receiveLowPowerMode(true)
        #expect(alerts.count == 1, "only the change from off to on")
        monitor.receiveLowPowerMode(false)
        #expect(alerts.count == 1)
        monitor.receiveLowPowerMode(true)
        #expect(alerts.count == 2, "each time it turns on, no cooldown")
    }

    @Test func launchingWhileLowPowerModeIsOnDoesntNotify() {
        let monitor = monitor()
        var alerts: [SyncAlert] = []
        monitor.onAlert = { alerts.append($0) }
        monitor.receiveLowPowerMode(true) // the first reading is the launch's
        #expect(alerts.isEmpty)
        #expect(monitor.statusHint == SyncStatus.lowPowerModeHint, "the Settings line still says so")
    }

    @Test(arguments: [AccountObservation.noAccount, .iCloudOffForApp, .restricted])
    func noNotificationWithoutASignedInAccount(account: AccountObservation) {
        let monitor = monitor(account: account)
        var alerts: [SyncAlert] = []
        monitor.onAlert = { alerts.append($0) }
        monitor.receiveLowPowerMode(false)
        monitor.receiveLowPowerMode(true)
        #expect(alerts.isEmpty)
    }

    @Test(arguments: [SyncState.Mode.local, .unavailable(reason: "boom"), .starting])
    func noNotificationWhenTheStoreDoesntMirror(mode: SyncState.Mode) {
        let monitor = monitor(mode)
        var alerts: [SyncAlert] = []
        monitor.onAlert = { alerts.append($0) }
        monitor.receiveLowPowerMode(false)
        monitor.receiveLowPowerMode(true)
        #expect(alerts.isEmpty)
    }

    @Test func noNotificationBeforeTheAccountIsKnown() {
        let monitor = monitor(account: nil)
        var alerts: [SyncAlert] = []
        monitor.onAlert = { alerts.append($0) }
        monitor.receiveLowPowerMode(false)
        monitor.receiveLowPowerMode(true)
        #expect(alerts.isEmpty)
        monitor.receiveAccount(Self.signedIn)
        #expect(alerts.isEmpty, "a turn-on that went unnoticed isn't notified later")
    }

    @Test func turningItOffWithdrawsTheNotice() {
        let monitor = monitor()
        var resolved: [SyncAlert] = []
        monitor.onAlertResolved = { resolved.append($0) }
        monitor.receiveLowPowerMode(false) // launch: off
        monitor.receiveLowPowerMode(false)
        #expect(resolved.isEmpty)
        monitor.receiveLowPowerMode(true)
        #expect(resolved.isEmpty)
        monitor.receiveLowPowerMode(false)
        #expect(resolved == [.lowPowerMode])
    }

    @Test func aLaunchReadingOfOffDoesntWithdraw() {
        let monitor = monitor()
        var resolved: [SyncAlert] = []
        monitor.onAlertResolved = { resolved.append($0) }
        monitor.receiveLowPowerMode(false)
        #expect(resolved.isEmpty)
    }

    @Test func theDecisionIsPure() {
        let on = SyncIncidents.lowPowerModeChanged
        #expect(on(false, true, .iCloud, Self.signedIn) == [.lowPowerMode])
        #expect(on(false, true, .iCloud, .temporarilyUnavailable) == [.lowPowerMode], "signed in, just not ready")
        #expect(on(nil, true, .iCloud, Self.signedIn).isEmpty, "the launch reading")
        #expect(on(true, true, .iCloud, Self.signedIn).isEmpty)
        #expect(on(true, false, .iCloud, Self.signedIn).isEmpty)
        #expect(on(false, true, .iCloud, .couldNotDetermine).isEmpty)
        #expect(on(false, true, .local, Self.signedIn).isEmpty)
    }

    @Test func theNoticeSaysWhy() {
        #expect(SyncAlert.lowPowerMode.title == "Sync may be delayed")
        #expect(SyncAlert.lowPowerMode.body.contains("Low Power Mode"))
    }

    @Test func onlyTheProblemsAskForNotificationPermission() {
        #expect(!SyncAlert.lowPowerMode.asksForPermission)
        #expect(SyncAlert.storageFull.asksForPermission)
        #expect(SyncAlert.failing(reason: "x").asksForPermission)
        #expect(SyncAlert.dataRemoved(.signedOut).asksForPermission)
    }
}
