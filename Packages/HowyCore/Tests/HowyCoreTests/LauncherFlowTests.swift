import Foundation
import Testing
@testable import HowyCore

@MainActor
@Suite struct LauncherFlowTests {
    @Test func startsOnNewTodo() {
        #expect(LauncherFlow().highlighted == .create)
    }

    @Test func arrowsMoveBetweenTheTwoChoices() {
        let flow = LauncherFlow()
        #expect(flow.handle(.right) == .handled)
        #expect(flow.highlighted == .browse)
        flow.handle(.right) // clamps
        #expect(flow.highlighted == .browse)
        flow.handle(.left)
        #expect(flow.highlighted == .create)
        flow.handle(.down)
        #expect(flow.highlighted == .browse)
        flow.handle(.up)
        #expect(flow.highlighted == .create)
    }

    @Test func digitsOpenDirectly() {
        #expect(LauncherFlow().handle(.digit(1)) == .open(.create))
        #expect(LauncherFlow().handle(.digit(2)) == .open(.browse))
    }

    @Test func otherDigitsAreSwallowed() {
        let flow = LauncherFlow()
        #expect(flow.handle(.digit(3)) == .handled)
        #expect(!flow.isFinished)
    }

    @Test func enterAndTabOpenTheHighlightedChoice() {
        let flow = LauncherFlow(highlighted: .browse)
        #expect(flow.handle(.enter) == .open(.browse))
        #expect(LauncherFlow().handle(.tab) == .open(.create))
    }

    @Test func escapeCloses() {
        let flow = LauncherFlow()
        #expect(flow.handle(.escape) == .close)
        #expect(flow.isFinished)
    }

    @Test func typingIsSwallowed() {
        let flow = LauncherFlow()
        #expect(flow.handle(.other) == .handled)
        #expect(flow.handle(.space) == .handled)
        #expect(flow.highlighted == .create)
    }

    @Test func finishedFlowIgnoresKeys() {
        let flow = LauncherFlow()
        flow.open(.browse)
        #expect(flow.handle(.left) == .ignored)
        #expect(flow.open(.create) == .ignored)
        #expect(flow.highlighted == .browse)
    }

    @Test func shortcutModeDefaultsToSeparate() throws {
        let defaults = try #require(UserDefaults(suiteName: "LauncherFlowTests-\(UUID())"))
        #expect(ShortcutMode.load(from: defaults) == .separate)
    }

    @Test func shortcutModeRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "LauncherFlowTests-\(UUID())"))
        for mode in ShortcutMode.allCases {
            mode.save(to: defaults)
            #expect(ShortcutMode.load(from: defaults) == mode)
        }
    }

    @Test func launcherDefaultIsNewTodoWhenUnset() throws {
        let defaults = try #require(UserDefaults(suiteName: "LauncherFlowTests-\(UUID())"))
        #expect(LauncherChoice.loadDefault(from: defaults) == .create)
    }

    @Test func launcherDefaultRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "LauncherFlowTests-\(UUID())"))
        for choice in LauncherChoice.allCases {
            choice.saveAsDefault(to: defaults)
            #expect(LauncherChoice.loadDefault(from: defaults) == choice)
        }
    }
}
