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

    @Test func anEmptyCloudWaitsThenSeedsFromTheLocalChoice() {
        local.values[key] = 30
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        #expect(!store.isKnown)
        #expect(store.retention.days == 30)
        #expect(store.decisionDeadline == start.addingTimeInterval(ArchiveRetentionStore.decisionDelay))
        #expect(!store.tick(now: start.addingTimeInterval(59)))
        #expect(cloud.values[key] == nil, "not seeded before the deadline")
        #expect(store.tick(now: start.addingTimeInterval(60)))
        #expect(store.isKnown)
        #expect(cloud.values[key] as? Int == 30)
        #expect(!store.tick(now: start.addingTimeInterval(120)), "decides once")
    }

    @Test func aFreshMacNeverSeedsTheDefault() {
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        store.tick(now: start.addingTimeInterval(60))
        #expect(store.isKnown)
        #expect(store.retention == .default)
        #expect(cloud.values.isEmpty)
    }

    @Test func aValueArrivingFromTheCloudIsAdoptedAndNotOverwritten() {
        local.values[key] = 3
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        cloud.values[key] = 90 // the first download brings another Mac's choice
        store.cloudChanged()
        #expect(store.isKnown)
        #expect(store.retention.days == 90)
        #expect(local.values[key] as? Int == 90)
        store.tick(now: start.addingTimeInterval(600))
        #expect(cloud.values[key] as? Int == 90)
    }

    @Test func aLateValueAtTheDeadlineIsAdoptedNotSeeded() {
        local.values[key] = 3
        let store = ArchiveRetentionStore(local: local, cloud: cloud, now: start)
        cloud.values[key] = 14 // arrived without a change notification yet
        store.tick(now: start.addingTimeInterval(60))
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
