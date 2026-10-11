import Foundation
import Testing
@testable import HowyCore

/// The archive retention shared through the iCloud key-value store.
@MainActor
@Suite struct ArchiveRetentionStoreTests {
    final class Memory: KeyValueStoring {
        var values: [String: Any] = [:]
        var writes = 0
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) {
            values[key] = value
            writes += 1
        }
    }

    let key = ArchiveRetention.defaultsKey
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let local = Memory()
    let cloud = Memory()

    @Test func withoutTheCloudTheLocalValueIsKnownAtOnce() {
        local.values[key] = 30
        let store = ArchiveRetentionStore(local: local, cloud: nil, now: start)
        #expect(store.isKnown)
        #expect(store.retention.days == 30)
    }

    @Test func withoutAnyValueItIsTheDefault() {
        let store = ArchiveRetentionStore(local: local, cloud: nil, now: start)
        #expect(store.retention == .default)
    }

    @Test func theCloudValueWinsAndIsCachedLocally() {
        local.values[key] = 7
        cloud.values[key] = 90
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        #expect(store.isKnown)
        #expect(store.retention.days == 90)
        #expect(local.values[key] as? Int == 90)
    }

    let day: TimeInterval = 24 * 60 * 60

    @Test func anEmptyCloudWaitsADayThenSeedsFromTheUsersOwnChoice() {
        local.values[key] = 30 // chosen in Settings on this Mac
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        #expect(!store.isKnown)
        #expect(store.isExplicit)
        #expect(store.retention.days == 30)
        #expect(ArchiveRetentionStore.decisionDelay == day)
        #expect(store.decisionDeadline == start.addingTimeInterval(day))
        #expect(!store.tick(now: start.addingTimeInterval(60)), "a minute is far too early")
        #expect(!store.tick(now: start.addingTimeInterval(day - 1)))
        #expect(cloud.values[key] == nil, "not seeded before the deadline")
        #expect(store.tick(now: start.addingTimeInterval(day)))
        #expect(store.isKnown)
        #expect(cloud.values[key] as? Int == 30)
        #expect(!store.tick(now: start.addingTimeInterval(2 * day)), "decides once")
    }

    @Test func aFreshMacStaysUnknownForADayAndThenNeverSeedsTheDefault() {
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        #expect(!store.isExplicit)
        store.tick(now: start.addingTimeInterval(day - 1))
        #expect(!store.isKnown, "no purge with the default on a Mac that has seen nothing yet")
        store.tick(now: start.addingTimeInterval(day))
        #expect(store.isKnown)
        #expect(store.retention == .default)
        #expect(cloud.values[key] == nil)
    }

    @Test func aValueThatCameFromTheCloudIsNeverSeededBack() {
        cloud.values[key] = 90
        _ = ArchiveRetentionStore(local: local, cloud: cloud, now: start) // adopts: local 90, marked
        cloud.values[key] = nil // KVS lost it (an account change, say)
        let again = ArchiveRetentionStore(local: local, cloud: cloud, now: start.addingTimeInterval(10))
        #expect(!again.isKnown)
        #expect(!again.isExplicit, "the 90 came from the cloud, not from a choice here")
        again.tick(now: start.addingTimeInterval(day + 10))
        #expect(cloud.values[key] == nil)
    }

    @Test func theWaitCountsFromTheFirstLaunchNotFromEveryLaunch() {
        _ = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        let relaunched = ArchiveRetentionStore(local: local, cloud: cloud, now: start.addingTimeInterval(20 * 3600))
        #expect(relaunched.decisionDeadline == start.addingTimeInterval(day))
        #expect(!relaunched.tick(now: start.addingTimeInterval(23 * 3600)))
        #expect(relaunched.tick(now: start.addingTimeInterval(day + 1)))
    }

    @Test func aChoiceMadeInSettingsIsExplicit() {
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        store.set(ArchiveRetention(days: 14))
        #expect(store.isExplicit)
    }

    @Test func aValueArrivingFromTheCloudIsAdoptedAndNotOverwritten() {
        local.values[key] = 3
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        cloud.values[key] = 90 // the first download brings another Mac's choice
        store.cloudChanged()
        #expect(store.isKnown)
        #expect(store.retention.days == 90)
        #expect(local.values[key] as? Int == 90)
        store.tick(now: start.addingTimeInterval(day + 600))
        #expect(cloud.values[key] as? Int == 90)
    }

    @Test func aLateValueAtTheDeadlineIsAdoptedNotSeeded() {
        local.values[key] = 3
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        cloud.values[key] = 14 // arrived without a change notification yet
        store.tick(now: start.addingTimeInterval(day))
        #expect(store.retention.days == 14)
        #expect(cloud.values[key] as? Int == 14)
    }

    @Test func aChangeWithoutAValueChangesNothing() {
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        store.cloudChanged()
        #expect(!store.isKnown)
    }

    @Test func settingWritesBothAndIsKnown() {
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        store.set(ArchiveRetention(days: 14))
        #expect(store.isKnown)
        #expect(local.values[key] as? Int == 14)
        #expect(cloud.values[key] as? Int == 14)
    }

    @Test func invalidValuesAreIgnored() {
        local.values[key] = 0
        cloud.values[key] = "ninety"
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        #expect(!store.isKnown)
        #expect(store.retention == .default)
    }

    @Test func userDefaultsWorksAsTheLocalStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "howy.tests.\(UUID().uuidString)"))
        ArchiveRetention(days: 90).save(to: defaults)
        let store = ArchiveRetentionStore(local: defaults, cloud: nil, now: start)
        #expect(store.retention.days == 90)
        store.set(ArchiveRetention(days: 1))
        #expect(ArchiveRetention.load(from: defaults).days == 1)
    }
}
