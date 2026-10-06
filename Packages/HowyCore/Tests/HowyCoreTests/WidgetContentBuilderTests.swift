import Foundation
import Testing
@testable import HowyCore

@Suite struct WidgetContentBuilderTests {
    func snapshots(_ count: Int, in quadrant: Quadrant) -> [TodoSnapshot] {
        (0..<count).map { TodoSnapshot(id: UUID(), title: "\(quadrant.rawValue)-\($0)", quadrant: quadrant) }
    }

    @Test func capacities() {
        #expect(WidgetContentBuilder.capacity(for: .small) == 4)
        #expect(WidgetContentBuilder.capacity(for: .medium) == 4)
        #expect(WidgetContentBuilder.capacity(for: .large) == 5)
        #expect(WidgetContentBuilder.capacity(for: .extraLarge) == 6)
    }

    @Test func singleQuadrantFamiliesShowOnlySelectedQuadrant() {
        let input: [Quadrant: [TodoSnapshot]] = [
            .urgentImportant: snapshots(2, in: .urgentImportant),
            .urgentUnimportant: snapshots(1, in: .urgentUnimportant),
        ]
        for family in [HowyWidgetFamily.small, .medium] {
            let content = WidgetContentBuilder.build(openTodos: input, family: family, selectedQuadrant: .urgentUnimportant)
            #expect(content.family == family)
            #expect(content.quadrants.map(\.quadrant) == [.urgentUnimportant])
            #expect(content.quadrants.first?.visible == input[.urgentUnimportant])
        }
    }

    @Test func singleQuadrantDefaultsToUrgentImportant() {
        let content = WidgetContentBuilder.build(openTodos: [:], family: .small, selectedQuadrant: nil)
        #expect(content.quadrants.map(\.quadrant) == [.urgentImportant])
    }

    @Test(arguments: [HowyWidgetFamily.large, .extraLarge])
    func matrixFamiliesShowAllQuadrantsInReadingOrder(family: HowyWidgetFamily) {
        let content = WidgetContentBuilder.build(openTodos: [:], family: family, selectedQuadrant: .notUrgentUnimportant)
        #expect(content.quadrants.map(\.quadrant) == Quadrant.allCases)
    }

    @Test(arguments: HowyWidgetFamily.allCases)
    func fitsExactlyShowsAllWithoutOverflow(family: HowyWidgetFamily) {
        let capacity = WidgetContentBuilder.capacity(for: family)
        let todos = snapshots(capacity, in: .urgentImportant)
        let content = WidgetContentBuilder.build(openTodos: [.urgentImportant: todos], family: family, selectedQuadrant: .urgentImportant)
        let q = content.quadrants[0]
        #expect(q.visible == todos)
        #expect(q.openCount == capacity)
        #expect(q.overflowCount == 0)
        #expect(!q.isEmpty)
    }

    @Test(arguments: HowyWidgetFamily.allCases)
    func overflowReservesOneLineForMoreRow(family: HowyWidgetFamily) {
        let capacity = WidgetContentBuilder.capacity(for: family)
        let todos = snapshots(capacity + 1, in: .urgentImportant)
        let content = WidgetContentBuilder.build(openTodos: [.urgentImportant: todos], family: family, selectedQuadrant: .urgentImportant)
        let q = content.quadrants[0]
        #expect(q.visible == Array(todos.prefix(capacity - 1)), "keeps the newest-first input order")
        #expect(q.overflowCount == 2)
        #expect(q.openCount == capacity + 1)
        #expect(q.visible.count + 1 == capacity, "titles plus the +N more row fill the capacity")
    }

    @Test func largeOverflowCounts() {
        let todos = snapshots(23, in: .notUrgentImportant)
        let content = WidgetContentBuilder.build(openTodos: [.notUrgentImportant: todos], family: .large, selectedQuadrant: nil)
        let q = content.quadrants[1]
        #expect(q.quadrant == .notUrgentImportant)
        #expect(q.visible.count == 4)
        #expect(q.overflowCount == 19)
        #expect(q.openCount == 23)
    }

    @Test func emptyQuadrant() {
        let content = WidgetContentBuilder.build(openTodos: [.urgentImportant: []], family: .large, selectedQuadrant: nil)
        for q in content.quadrants {
            #expect(q.isEmpty)
            #expect(q.visible.isEmpty)
            #expect(q.openCount == 0)
            #expect(q.overflowCount == 0)
        }
    }

    @Test func countsArePerQuadrant() {
        let input: [Quadrant: [TodoSnapshot]] = [
            .urgentImportant: snapshots(1, in: .urgentImportant),
            .notUrgentImportant: snapshots(5, in: .notUrgentImportant),
            .urgentUnimportant: snapshots(6, in: .urgentUnimportant),
        ]
        let content = WidgetContentBuilder.build(openTodos: input, family: .large, selectedQuadrant: nil)
        #expect(content.quadrants.map(\.openCount) == [1, 5, 6, 0])
        #expect(content.quadrants.map(\.overflowCount) == [0, 0, 2, 0])
        #expect(content.quadrants.map(\.visible.count) == [1, 5, 4, 0])
    }


    @Test func customCapacityOverride() {
        let todos = snapshots(3, in: .urgentImportant)
        let content = WidgetContentBuilder.build(openTodos: [.urgentImportant: todos], family: .small, selectedQuadrant: nil, capacity: 2)
        #expect(content.quadrants[0].visible.count == 1)
        #expect(content.quadrants[0].overflowCount == 2)
    }
}
