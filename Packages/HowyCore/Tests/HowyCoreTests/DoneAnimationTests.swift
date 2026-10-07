import Foundation
import Testing
@testable import HowyCore

@Suite struct DoneAnimationTests {
    @Test func confettiIsTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "DoneAnimationTests-\(UUID())"))
        #expect(DoneAnimation.load(from: defaults) == .confetti)
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "DoneAnimationTests-\(UUID())"))
        for setting in DoneAnimation.allCases {
            setting.save(to: defaults)
            #expect(DoneAnimation.load(from: defaults) == setting)
        }
    }

    @Test func unknownStoredValueFallsBackToConfetti() throws {
        let defaults = try #require(UserDefaults(suiteName: "DoneAnimationTests-\(UUID())"))
        defaults.set("fireworks", forKey: DoneAnimation.defaultsKey)
        #expect(DoneAnimation.load(from: defaults) == .confetti)
    }

    @Test func offDrawsNothingAndOnlyConfettiBursts() {
        #expect(DoneAnimation.off.showsEmoji == false)
        #expect(DoneAnimation.emoji.showsEmoji)
        #expect(DoneAnimation.emoji.showsConfetti == false)
        #expect(DoneAnimation.confetti.showsConfetti)
    }
}
