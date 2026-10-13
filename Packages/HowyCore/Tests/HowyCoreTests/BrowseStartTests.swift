import Foundation
import Testing
@testable import HowyCore

/// Where the grid's highlight starts when Open Howy opens Browse: the quadrant opened last, or
/// Do First the very first time. A way back (`resume(at:)`, the archive) still wins.
@MainActor
@Suite struct BrowseStartTests {
    func todos(_ quadrant: Quadrant, _ titles: [String]) -> [TodoSnapshot] {
        titles.map { TodoSnapshot(id: UUID(), title: $0, quadrant: quadrant) }
    }

    var data: [Quadrant: [TodoSnapshot]] {
        [
            .urgentImportant: todos(.urgentImportant, ["a", "b"]),
            .notUrgentImportant: todos(.notUrgentImportant, ["p"]),
            .urgentUnimportant: todos(.urgentUnimportant, []),
            .notUrgentUnimportant: todos(.notUrgentUnimportant, ["z"]),
        ]
    }

    @Test func theFirstOpenHighlightsDoFirst() {
        let flow = BrowseFlow(todos: data, lastOpened: MemoryLastQuadrantStore())
        #expect(flow.phase == .picking)
        #expect(flow.quadrant == .urgentImportant)
    }

    @Test func laterOpensHighlightTheQuadrantOpenedLast() {
        let flow = BrowseFlow(todos: data, lastOpened: MemoryLastQuadrantStore(.urgentUnimportant))
        #expect(flow.phase == .picking)
        #expect(flow.quadrant == .urgentUnimportant)
    }

    @Test func openingAListRemembersItsQuadrant() {
        let memory = MemoryLastQuadrantStore()
        let flow = BrowseFlow(todos: data, lastOpened: memory)
        flow.handle(.digit(4))
        #expect(memory.load() == .notUrgentUnimportant)
        flow.handle(.digit(2))
        #expect(memory.load() == .notUrgentImportant)
    }

    @Test func movingTheHighlightAloneRemembersNothing() {
        let memory = MemoryLastQuadrantStore(.notUrgentUnimportant)
        let flow = BrowseFlow(todos: data, lastOpened: memory)
        flow.handle(.up)
        flow.handle(.left)
        #expect(flow.quadrant == .urgentImportant)
        #expect(memory.load() == .notUrgentUnimportant)
    }

    @Test func focusingATileInTheOverviewRemembersIt() {
        let memory = MemoryLastQuadrantStore()
        let flow = BrowseFlow(todos: data, lastOpened: memory)
        flow.handle(.letter(BrowseFlow.overviewKey))
        flow.handle(.digit(2))
        #expect(memory.load() == .notUrgentImportant)
    }

    @Test func anExplicitQuadrantWinsOverTheRememberedOne() {
        let flow = BrowseFlow(todos: data, quadrant: .notUrgentImportant, lastOpened: MemoryLastQuadrantStore(.urgentUnimportant))
        #expect(flow.quadrant == .notUrgentImportant)
    }

    @Test func aWayBackWinsOverTheRememberedQuadrant() throws {
        let first = BrowseFlow(todos: data)
        first.handle(.digit(4))
        let back = first.returnPoint()
        let flow = BrowseFlow(todos: data, lastOpened: MemoryLastQuadrantStore(.notUrgentImportant))
        flow.resume(at: back)
        #expect(flow.phase == .listing)
        #expect(flow.quadrant == .notUrgentUnimportant)
    }
}
