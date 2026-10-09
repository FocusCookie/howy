import CoreGraphics
import Testing
@testable import HowyCore

/// `OverviewDropPlanner`: insertion points from fixed row geometry (y down).
@Suite struct OverviewDropPlannerTests {
    // Rows 38 pt high every 40 pt; the list starts at y 100 and is 200 pt high (5 rows in view).
    let header = CGRect(x: 0, y: 50, width: 300, height: 30) // maxY 80
    let list = CGRect(x: 0, y: 100, width: 300, height: 200)

    func plan(y: CGFloat, scroll: CGFloat = 0, rows: Int = 3, from: Int? = nil, header: CGRect? = nil) -> OverviewDropPlan {
        OverviewDropPlanner.plan(
            pointY: y, headerFrame: header ?? self.header, listFrame: list, scrollOffset: scroll,
            rowPitch: 40, rowHeight: 38, rowCount: rows, draggedFromIndex: from
        )
    }

    @Test func onTheHeaderIsTheTop() {
        #expect(plan(y: 60).index == 0)
        #expect(plan(y: 84).index == 0, "a little slop below the header")
        #expect(plan(y: 60).lineY == 101, "the line is kept inside the list")
    }

    @Test func betweenRowsIsTheNearestGap() {
        // Row 1 spans 140...178, its middle at 159.
        #expect(plan(y: 158).index == 1)
        #expect(plan(y: 159).index == 2)
        #expect(plan(y: 139).index == 1, "the lower half of row 0")
        #expect(plan(y: 118).index == 0, "the upper half of row 0")
        #expect(plan(y: 159).lineY == CGFloat(179), "the middle of the gap above row 2: 100 + 2 × 40 − 1")
    }

    @Test func belowTheLastRowIsTheEnd() {
        #expect(plan(y: 290).index == 3)
        #expect(plan(y: 290).lineY == 219)
        #expect(plan(y: 290, rows: 0).index == 0)
    }

    @Test func aScrolledListCountsTheRowsAboveTheView() {
        // Scrolled by 10 rows: row 10 starts at the list's top.
        #expect(plan(y: 105, scroll: 400, rows: 30).index == 10)
        #expect(plan(y: 125, scroll: 400, rows: 30).index == 11)
        #expect(plan(y: 125, scroll: 400, rows: 30).lineY == 139)
        #expect(plan(y: 60, scroll: 400, rows: 30).index == 0, "the header is still the top")
    }

    @Test func farOutsideIsClamped() {
        #expect(plan(y: 5000).index == 3)
        #expect(plan(y: 90, header: CGRect(x: 0, y: -100, width: 1, height: 1)).index == 0)
        #expect(plan(y: 5000, scroll: 0, rows: 20).lineY == 299, "the line stays inside the list")
    }

    @Test(arguments: [(0, true), (1, true), (2, false), (3, false)])
    func noOpPositionsInItsOwnTile(index: Int, isNoOp: Bool) {
        // Dragged from row 0: its own row (0) and the gap after it (1) leave it where it is.
        let y: CGFloat = [60, 139, 179, 290][index]
        let result = plan(y: y, from: 0)
        #expect(result.index == index)
        #expect(result.isNoOp == isNoOp)
        #expect((result.lineY == nil) == isNoOp)
    }

    @Test func fromAnotherTileIsNeverANoOp() {
        #expect(plan(y: 60).isNoOp == false)
        #expect(plan(y: 290).isNoOp == false)
    }

    @Test func noOpIsTheSameRuleAsTheFlow() {
        for from in 0..<3 {
            for index in -2...6 {
                let planned = BrowseFlow.dropIsNoOp(from: from, at: index, count: 3)
                let clamped = min(max(index, 0), 3)
                #expect(planned == (clamped == from || clamped == from + 1))
            }
        }
        #expect(BrowseFlow.dropIsNoOp(from: nil, at: 0, count: 3) == false)
    }
}
