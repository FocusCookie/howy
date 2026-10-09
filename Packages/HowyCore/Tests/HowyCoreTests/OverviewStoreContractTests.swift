import Foundation
import Testing
@testable import HowyCore

/// `BrowseFlow`'s Overview outcomes written through `TodoStore` the way the app does: after every
/// write the store's order must be the flow's rows, and ⌘Z must bring the store back.
@MainActor
@Suite struct OverviewStoreContractTests {
    let clock = FakeClock()
    let store: TodoStore
    /// The app's bookkeeping for `.moveBack`: each todo's sortDates before its moves, newest last.
    final class MoveDates { var byID: [UUID: [Date]] = [:] }
    let moveDates = MoveDates()

    init() throws {
        let clock = clock
        store = try TodoStore.inMemory(now: { clock.now })
        for (quadrant, titles) in [(Quadrant.urgentImportant, ["a", "b", "c"]), (.notUrgentImportant, ["q", "p"]), (.urgentUnimportant, ["x"])] {
            for title in titles {
                try store.add(title: title, quadrant: quadrant)
                clock.advance(by: 10)
            }
        }
    }

    func overview() throws -> BrowseFlow {
        let flow = BrowseFlow(todos: try store.openSnapshots())
        flow.toggleOverview()
        return flow
    }

    /// Writes an outcome as `BrowseModel.perform` does.
    func persist(_ outcome: BrowseFlow.Outcome, _ flow: BrowseFlow) throws {
        switch outcome {
        case .place(let id, _, let to, let index):
            moveDates.byID[id, default: []].append(try store.move(id: id, to: to, at: index))
        case .move(let id, _, let to):
            moveDates.byID[id, default: []].append(try store.move(id: id, to: to))
        case .moveBack(let id, let to):
            if let date = moveDates.byID[id]?.popLast() { try store.moveBack(id: id, to: to, sortDate: date) }
        case .reorder(let quadrant):
            try store.reorder(flow.rows(in: quadrant).map(\.id), in: quadrant)
        default:
            break
        }
        clock.advance(by: 1)
    }

    func expectStoreMatches(_ flow: BrowseFlow, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let stored = try store.openSnapshots()
        for quadrant in Quadrant.allCases {
            #expect(stored[quadrant]?.map(\.id) == flow.rows(in: quadrant).map(\.id), "\(quadrant)", sourceLocation: sourceLocation)
        }
    }

    func id(_ flow: BrowseFlow, _ title: String) throws -> UUID {
        try #require(Quadrant.allCases.flatMap { flow.rows(in: $0) }.first { $0.title == title }).id
    }

    @Test func crossTileDropsAndTheirUndosKeepTheStoreInStep() throws {
        let flow = try overview()
        let original = try store.openSnapshots().mapValues { $0.map(\.id) }
        let c = try id(flow, "c")
        let b = try id(flow, "b")
        try persist(flow.drop(id: c, on: .notUrgentImportant, at: 1), flow)
        try expectStoreMatches(flow)
        try persist(flow.drop(id: b, on: .urgentUnimportant, at: 1), flow)
        try expectStoreMatches(flow)

        try persist(try #require(flow.undo()), flow)
        flow.reload(try store.openSnapshots())
        try expectStoreMatches(flow)
        try persist(try #require(flow.undo()), flow)
        flow.reload(try store.openSnapshots())
        try expectStoreMatches(flow)
        #expect(try store.openSnapshots().mapValues { $0.map(\.id) } == original)
    }

    @Test func sameTileDropAndItsUndoKeepTheStoreInStep() throws {
        let flow = try overview()
        let original = try store.openTodos(in: .urgentImportant).map(\.id)
        let top = try #require(flow.rows(in: .urgentImportant).first).id
        try persist(flow.drop(id: top, on: .urgentImportant, at: 3), flow)
        try expectStoreMatches(flow)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) != original)

        try persist(try #require(flow.undo()), flow)
        flow.reload(try store.openSnapshots())
        try expectStoreMatches(flow)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == original)
    }

    @Test func nudgesAndMovesThenUndoingAllOfThem() throws {
        let flow = try overview()
        let original = try store.openSnapshots().mapValues { $0.map(\.id) }
        let q = try id(flow, "q")
        let a = try id(flow, "a")
        try persist(flow.nudge(id: q, by: -1), flow)
        try expectStoreMatches(flow)
        try persist(flow.move(id: a, toQuadrant: .notUrgentUnimportant), flow)
        try expectStoreMatches(flow)
        try persist(flow.handle(.moveDown), flow) // the focused tile's selection
        try expectStoreMatches(flow)
        while let outcome = flow.undo() {
            try persist(outcome, flow)
            flow.reload(try store.openSnapshots())
            try expectStoreMatches(flow)
        }
        #expect(try store.openSnapshots().mapValues { $0.map(\.id) } == original)
    }
}
