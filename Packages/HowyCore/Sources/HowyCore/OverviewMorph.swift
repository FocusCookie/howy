/// The choreography of Browse's grow from the small 2×2 grid into the Overview and back, as
/// stages the app animates one after the other:
///
/// - Grow: `hidingCounts` (the big counts fade out quickly) → `growing` (the tile shells and the
///   card grow together, in one spring, with no rows in them) → `revealingRows` (the rows fade in
///   once the tiles have their final size) → `expanded`.
/// - Shrink: `hidingRows` (the rows fade out and are gone) → `shrinking` (shells and card shrink
///   back) → `revealingCounts` → `compact`.
///
/// The app starts each stage's animation and, when it completes, calls `finish` with the
/// `generation` it started it for. Every stage change bumps `generation`, so a completion that
/// arrives after `expand`/`collapse` turned the transition around does nothing. Turning around
/// goes to the matching stage of the other direction, from wherever the transition is, so rapid
/// toggles never leave it stuck.
public struct OverviewMorph: Hashable, Sendable {
    public enum Stage: Hashable, Sendable {
        case compact, hidingCounts, growing, revealingRows, expanded, hidingRows, shrinking, revealingCounts
    }

    public private(set) var stage: Stage
    /// Bumped on every stage change; a stage's completion carries the one it was started for.
    public private(set) var generation = 0

    public init(stage: Stage = .compact) {
        self.stage = stage
    }

    /// The tiles fill the grown card (the Overview's layout) rather than sitting in the small grid.
    public var isExpandedLayout: Bool {
        switch stage {
        case .growing, .revealingRows, .expanded, .hidingRows: true
        case .compact, .hidingCounts, .shrinking, .revealingCounts: false
        }
    }

    /// The tiles' rows (and an open tile editor) are in the view: never while the tiles change size.
    public var showsRows: Bool { stage == .revealingRows || stage == .expanded }

    /// The small grid's big open counts are in the view.
    public var showsCounts: Bool { stage == .compact || stage == .revealingCounts }

    /// The footer (key hints, Archive button) is in view: hidden while the tiles change size, so
    /// it swaps between the grid's and the Overview's hints unseen instead of sliding through
    /// the tiles. It fades out and in with the counts and the rows.
    public var showsFooter: Bool { showsCounts || showsRows }

    /// Where the transition is heading (or has arrived): the Overview. Changes only in the fade
    /// stages that start a direction (`hidingCounts`, `hidingRows`), before anything moves, so
    /// what follows it, such as the middle button's icon, never swaps while the tiles move.
    public var isHeadingToOverview: Bool {
        switch stage {
        case .hidingCounts, .growing, .revealingRows, .expanded: true
        case .compact, .hidingRows, .shrinking, .revealingCounts: false
        }
    }

    /// No transition is running.
    public var isSettled: Bool { stage == .compact || stage == .expanded }

    /// Towards the Overview. `false` when it is already there or on its way.
    @discardableResult
    public mutating func expand() -> Bool {
        switch stage {
        case .compact, .revealingCounts: set(.hidingCounts)
        case .shrinking: set(.growing)
        case .hidingRows: set(.revealingRows)
        case .hidingCounts, .growing, .revealingRows, .expanded: false
        }
    }

    /// Back to the small grid. `false` when it is already there or on its way.
    @discardableResult
    public mutating func collapse() -> Bool {
        switch stage {
        case .expanded, .revealingRows: set(.hidingRows)
        case .growing: set(.shrinking)
        case .hidingCounts: set(.revealingCounts)
        case .hidingRows, .shrinking, .revealingCounts, .compact: false
        }
    }

    /// The animation of the stage started for `generation` completed: on to the next stage.
    /// `false` (nothing changes) for a stale generation or a settled stage.
    @discardableResult
    public mutating func finish(_ generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        switch stage {
        case .hidingCounts: return set(.growing)
        case .growing: return set(.revealingRows)
        case .revealingRows: return set(.expanded)
        case .hidingRows: return set(.shrinking)
        case .shrinking: return set(.revealingCounts)
        case .revealingCounts: return set(.compact)
        case .compact, .expanded: return false
        }
    }

    private mutating func set(_ next: Stage) -> Bool {
        stage = next
        generation += 1
        return true
    }
}
