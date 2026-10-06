import Foundation
import Testing
@testable import HowyCore

@MainActor
@Suite struct NewTodoQuadrantTests {
    @Test func lastUsedIsTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "NewTodoQuadrantTests-\(UUID())"))
        #expect(NewTodoQuadrant.load(from: defaults) == .lastUsed)
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "NewTodoQuadrantTests-\(UUID())"))
        for setting in NewTodoQuadrant.allCases {
            setting.save(to: defaults)
            #expect(NewTodoQuadrant.load(from: defaults) == setting)
        }
    }

    @Test func fixedQuadrantBeatsLastUsed() {
        let flow = QuickEntryFlow(
            mode: .create(), lastUsed: MemoryLastQuadrantStore(.urgentUnimportant),
            startQuadrant: .fixed(.notUrgentImportant)
        )
        #expect(flow.quadrant == .notUrgentImportant)
    }

    @Test func lastUsedSettingUsesTheRememberedQuadrant() {
        let flow = QuickEntryFlow(mode: .create(), lastUsed: MemoryLastQuadrantStore(.urgentUnimportant), startQuadrant: .lastUsed)
        #expect(flow.quadrant == .urgentUnimportant)
        let fresh = QuickEntryFlow(mode: .create(), lastUsed: MemoryLastQuadrantStore(), startQuadrant: .lastUsed)
        #expect(fresh.quadrant == .urgentImportant)
    }

    @Test func preselectedBeatsTheSetting() {
        let flow = QuickEntryFlow(
            mode: .create(preselected: .notUrgentUnimportant), lastUsed: MemoryLastQuadrantStore(),
            startQuadrant: .fixed(.notUrgentImportant)
        )
        #expect(flow.quadrant == .notUrgentUnimportant)
    }
}
