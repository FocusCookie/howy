import Foundation
import Testing
@testable import HowyCore

@Suite struct ArchiveRetentionTests {
    @Test func sevenDaysIsTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArchiveRetentionTests-\(UUID())"))
        #expect(ArchiveRetention.load(from: defaults) == ArchiveRetention(days: 7))
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArchiveRetentionTests-\(UUID())"))
        for setting in ArchiveRetention.options {
            setting.save(to: defaults)
            #expect(ArchiveRetention.load(from: defaults) == setting)
        }
    }

    @Test func nonPositiveStoredValueFallsBackToSevenDays() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArchiveRetentionTests-\(UUID())"))
        defaults.set(-3, forKey: ArchiveRetention.defaultsKey)
        #expect(ArchiveRetention.load(from: defaults) == .default)
    }

    @Test func optionsIncludeTheDefault() {
        #expect(ArchiveRetention.options.contains(.default))
    }

    @Test func displayNameIsSingularForOneDay() {
        #expect(ArchiveRetention(days: 1).displayName == "1 day")
        #expect(ArchiveRetention(days: 30).displayName == "30 days")
    }
}
