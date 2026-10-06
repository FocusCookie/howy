import Foundation
import Testing
@testable import HowyCore

@Suite struct QuadrantTests {
    @Test func casesAreInReadingOrderWithStableRawValues() {
        #expect(Quadrant.allCases == [.urgentImportant, .notUrgentImportant, .urgentUnimportant, .notUrgentUnimportant])
        #expect(Quadrant.allCases.map(\.rawValue) == [1, 2, 3, 4])
        #expect(Quadrant.allCases.map(\.shortcutNumber) == [1, 2, 3, 4])
    }

    @Test func displayNames() {
        #expect(Quadrant.urgentImportant.displayName == "Urgent & Important")
        #expect(Quadrant.notUrgentImportant.displayName == "Not Urgent & Important")
        #expect(Quadrant.urgentUnimportant.displayName == "Urgent & Unimportant")
        #expect(Quadrant.notUrgentUnimportant.displayName == "Not Urgent & Unimportant")
    }

    @Test func shortcutNumberLookup() {
        #expect(Quadrant(shortcutNumber: 3) == .urgentUnimportant)
        #expect(Quadrant(shortcutNumber: 0) == nil)
        #expect(Quadrant(shortcutNumber: 5) == nil)
    }

    @Test func gridPositionsFormTwoByTwoInReadingOrder() {
        #expect(Quadrant.urgentImportant.gridPosition == GridPosition(row: 0, column: 0))
        #expect(Quadrant.notUrgentImportant.gridPosition == GridPosition(row: 0, column: 1))
        #expect(Quadrant.urgentUnimportant.gridPosition == GridPosition(row: 1, column: 0))
        #expect(Quadrant.notUrgentUnimportant.gridPosition == GridPosition(row: 1, column: 1))
        for q in Quadrant.allCases {
            #expect(Quadrant(gridPosition: q.gridPosition) == q)
        }
    }

    @Test func codableRoundTripUsesRawValue() throws {
        let data = try JSONEncoder().encode([Quadrant.urgentUnimportant])
        #expect(String(decoding: data, as: UTF8.self) == "[3]")
        #expect(try JSONDecoder().decode([Quadrant].self, from: data) == [.urgentUnimportant])
    }
}
