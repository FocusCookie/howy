import Testing
@testable import HowyCore

/// The choreography of Browse's grow into the Overview and back (`OverviewMorph`).
@Suite struct OverviewMorphTests {
    /// Finishes the current stage, as its animation's completion would.
    @discardableResult
    func finish(_ morph: inout OverviewMorph) -> Bool { morph.finish(morph.generation) }

    @Test func startsCompactWithCountsAndNoRows() {
        let morph = OverviewMorph()
        #expect(morph.stage == .compact)
        #expect(morph.isSettled)
        #expect(morph.showsCounts)
        #expect(!morph.showsRows)
        #expect(!morph.isExpandedLayout)
    }

    @Test func growHidesCountsThenMorphsThenRevealsRows() {
        var morph = OverviewMorph()
        let changed1 = morph.expand()
        #expect(changed1)
        #expect(morph.stage == .hidingCounts)
        #expect(!morph.showsCounts && !morph.showsRows && !morph.isExpandedLayout)

        finish(&morph)
        #expect(morph.stage == .growing)
        #expect(morph.isExpandedLayout)
        #expect(!morph.showsRows) // no rows laid out while the tiles grow

        finish(&morph)
        #expect(morph.stage == .revealingRows)
        #expect(morph.showsRows && morph.isExpandedLayout)

        finish(&morph)
        #expect(morph.stage == .expanded)
        #expect(morph.isSettled)
        let changed2 = finish(&morph)
        #expect(!changed2) // nothing after the end
    }

    @Test func shrinkHidesRowsThenMorphsThenRevealsCounts() {
        var morph = OverviewMorph(stage: .expanded)
        let changed3 = morph.collapse()
        #expect(changed3)
        #expect(morph.stage == .hidingRows)
        #expect(!morph.showsRows && morph.isExpandedLayout && !morph.showsCounts)

        finish(&morph)
        #expect(morph.stage == .shrinking)
        #expect(!morph.isExpandedLayout && !morph.showsRows && !morph.showsCounts)

        finish(&morph)
        #expect(morph.stage == .revealingCounts)
        #expect(morph.showsCounts)

        finish(&morph)
        #expect(morph.stage == .compact)
    }

    /// The footer's key hints are hidden while the tiles change size, so they never slide
    /// through the tiles while swapping between the grid's and the Overview's.
    @Test(arguments: [
        (OverviewMorph.Stage.compact, true), (.hidingCounts, false), (.growing, false), (.revealingRows, true),
        (.expanded, true), (.hidingRows, false), (.shrinking, false), (.revealingCounts, true),
    ])
    func footerOnlyShowsOutsideTheResize(stage: OverviewMorph.Stage, shows: Bool) {
        #expect(OverviewMorph(stage: stage).showsFooter == shows)
    }

    /// The middle button's icon points where the transition is heading, so it swaps in the
    /// first (fade) stage, before the tiles move, never while they do.
    @Test(arguments: [
        (OverviewMorph.Stage.compact, false), (.hidingCounts, true), (.growing, true), (.revealingRows, true),
        (.expanded, true), (.hidingRows, false), (.shrinking, false), (.revealingCounts, false),
    ])
    func buttonPointsWhereTheTransitionHeads(stage: OverviewMorph.Stage, towardsOverview: Bool) {
        #expect(OverviewMorph(stage: stage).isHeadingToOverview == towardsOverview)
    }

    @Test func aStaleCompletionDoesNothing() {
        var morph = OverviewMorph()
        morph.expand()
        let stale = morph.generation
        morph.finish(stale) // → growing
        #expect(morph.stage == .growing)
        let changed4 = morph.finish(stale)
        #expect(!changed4) // the counts' fade reporting late
        #expect(morph.stage == .growing)
    }

    @Test func repeatingTheSameDirectionChangesNothing() {
        var morph = OverviewMorph()
        morph.expand()
        let generation = morph.generation
        let changed5 = morph.expand()
        #expect(!changed5)
        #expect(morph.generation == generation)
        var fresh = OverviewMorph()
        let changed6 = fresh.collapse()
        #expect(!changed6)
        var expanded = OverviewMorph(stage: .expanded)
        let changed7 = expanded.expand()
        #expect(!changed7)
    }

    /// Esc / `o` mid-way turns around from where the transition is, without a stuck stage.
    @Test(arguments: [
        (OverviewMorph.Stage.hidingCounts, OverviewMorph.Stage.revealingCounts),
        (.growing, .shrinking),
        (.revealingRows, .hidingRows),
        (.expanded, .hidingRows),
    ])
    func collapseMidGrowTurnsAround(from: OverviewMorph.Stage, to: OverviewMorph.Stage) {
        var morph = OverviewMorph(stage: from)
        let generation = morph.generation
        let changed8 = morph.collapse()
        #expect(changed8)
        #expect(morph.stage == to)
        #expect(morph.generation != generation)
        let changed9 = morph.finish(generation)
        #expect(!changed9) // the grow's completion arrives late
        #expect(morph.stage == to)
    }

    @Test(arguments: [
        (OverviewMorph.Stage.hidingRows, OverviewMorph.Stage.revealingRows),
        (.shrinking, .growing),
        (.revealingCounts, .hidingCounts),
        (.compact, .hidingCounts),
    ])
    func expandMidShrinkTurnsAround(from: OverviewMorph.Stage, to: OverviewMorph.Stage) {
        var morph = OverviewMorph(stage: from)
        let changed10 = morph.expand()
        #expect(changed10)
        #expect(morph.stage == to)
    }

    @Test func rapidTogglesAlwaysSettle() {
        var morph = OverviewMorph()
        for _ in 0..<5 {
            morph.expand()
            finish(&morph)
            morph.collapse()
        }
        var steps = 0
        while !morph.isSettled, steps < 10 {
            finish(&morph)
            steps += 1
        }
        #expect(morph.stage == .compact)
    }
}
