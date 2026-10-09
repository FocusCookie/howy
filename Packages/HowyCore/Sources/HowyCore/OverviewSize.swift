import CoreGraphics
import Foundation

/// How much of the screen Browse's Overview takes (a Settings choice): a share of the visible
/// screen's width and height, each 50–95 %.
public struct OverviewSize: Hashable, Sendable {
    public static let widthDefaultsKey = "overviewWidthPercent"
    public static let heightDefaultsKey = "overviewHeightPercent"
    /// The percentages Settings offers.
    public static let percentRange = 50...95
    public static let `default` = OverviewSize(widthPercent: 80, heightPercent: 80)
    /// The narrowest a tile's content may be (inside its padding), so the in-tile editor stays
    /// usable. Same as `Metrics.standard.minimumTileWidth`.
    public static let minimumTileWidth: CGFloat = 360
    /// The lowest a tile may be (header and padding included), so the in-tile editor fits. Same as
    /// `Metrics.standard.minimumTileHeight`.
    public static let minimumTileHeight: CGFloat = 320
    /// The compact panel's card top sits this share of the visible height below its top edge
    /// (`FloatingPanel.present`).
    public static let compactPanelTopFraction: CGFloat = 0.22

    /// The Overview's fixed sizes in points: the smallest tile, and the chrome around the tiles.
    /// `scaled(by:)` gives the same layout on a scaled-down screen (the Settings preview).
    public struct Metrics: Hashable, Sendable {
        /// The narrowest tile content (inside `tilePadding`).
        public var minimumTileWidth: CGFloat
        /// The lowest tile, header and `tilePadding` included.
        public var minimumTileHeight: CGFloat
        /// The card's padding around the 2×2 tiles, each side.
        public var cardPadding: CGFloat
        /// The gap between two tiles.
        public var tileSpacing: CGFloat
        /// A tile's padding around its content, each side.
        public var tilePadding: CGFloat
        /// The chrome below the tiles inside the card: Browse's footer line of key hints (18 pt
        /// keycaps) and the 12 pt gap above it.
        public var footerHeight: CGFloat

        public static let standard = Metrics(
            minimumTileWidth: OverviewSize.minimumTileWidth, minimumTileHeight: OverviewSize.minimumTileHeight,
            cardPadding: 16, tileSpacing: 10, tilePadding: 12, footerHeight: 30
        )

        public init(
            minimumTileWidth: CGFloat, minimumTileHeight: CGFloat, cardPadding: CGFloat, tileSpacing: CGFloat, tilePadding: CGFloat,
            footerHeight: CGFloat = 0
        ) {
            self.minimumTileWidth = minimumTileWidth
            self.minimumTileHeight = minimumTileHeight
            self.cardPadding = cardPadding
            self.tileSpacing = tileSpacing
            self.tilePadding = tilePadding
            self.footerHeight = footerHeight
        }

        /// The narrowest Overview: two tiles of `minimumTileWidth` with their padding, the gap
        /// between them and the card's padding.
        public var minimumWidth: CGFloat {
            2 * (minimumTileWidth + 2 * tilePadding) + tileSpacing + 2 * cardPadding
        }

        /// The lowest Overview: two tiles of `minimumTileHeight`, the gap, the footer below them
        /// and the card's padding.
        public var minimumHeight: CGFloat {
            2 * minimumTileHeight + tileSpacing + footerHeight + 2 * cardPadding
        }

        /// Every size times `factor` (a screen drawn `factor` times its real size).
        public func scaled(by factor: CGFloat) -> Metrics {
            Metrics(
                minimumTileWidth: minimumTileWidth * factor, minimumTileHeight: minimumTileHeight * factor,
                cardPadding: cardPadding * factor, tileSpacing: tileSpacing * factor, tilePadding: tilePadding * factor,
                footerHeight: footerHeight * factor
            )
        }
    }

    /// Share of the visible screen width, clamped to `percentRange`.
    public let widthPercent: Int
    /// Share of the visible screen height (the most the Overview takes), clamped to `percentRange`.
    public let heightPercent: Int

    public init(widthPercent: Int, heightPercent: Int) {
        self.widthPercent = Self.clamped(widthPercent)
        self.heightPercent = Self.clamped(heightPercent)
    }

    /// The same height, another width (clamped).
    public func with(widthPercent: Int) -> OverviewSize {
        OverviewSize(widthPercent: widthPercent, heightPercent: heightPercent)
    }

    /// The same width, another height (clamped).
    public func with(heightPercent: Int) -> OverviewSize {
        OverviewSize(widthPercent: widthPercent, heightPercent: heightPercent)
    }

    /// The stored setting. Each dimension on its own: unset or not a number → its default
    /// (80 %); a number outside the range is clamped.
    public static func load(from defaults: UserDefaults = .standard) -> OverviewSize {
        func stored(_ key: String, _ fallback: Int) -> Int {
            switch defaults.object(forKey: key) {
            case let number as NSNumber: number.intValue
            case let text as String: Int(text.trimmingCharacters(in: .whitespaces)) ?? fallback
            default: fallback
            }
        }
        return OverviewSize(
            widthPercent: stored(widthDefaultsKey, Self.default.widthPercent),
            heightPercent: stored(heightDefaultsKey, Self.default.heightPercent)
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(widthPercent, forKey: Self.widthDefaultsKey)
        defaults.set(heightPercent, forKey: Self.heightDefaultsKey)
    }

    /// The Overview's frame on a screen: the set share of `visibleFrame`, centred on `center`
    /// (the panel's centre, so it grows from there) and then pushed back inside `visibleFrame`.
    /// When the set share is narrower than `metrics.minimumWidth` or lower than
    /// `metrics.minimumHeight` (both times `scale`), it grows to fit, but never past the visible
    /// frame.
    ///
    /// Works in any one coordinate space (AppKit screen coordinates in the app; a screen drawn
    /// `scale` times its size in the Settings preview, with the same `metrics` and that `scale`).
    /// The result is the frame on the real screen times `scale`.
    public func frame(
        in visibleFrame: CGRect, centeredOn center: CGPoint, metrics: Metrics = .standard, scale: CGFloat = 1
    ) -> CGRect {
        let metrics = scale == 1 ? metrics : metrics.scaled(by: scale)
        let width = min(max(visibleFrame.width * CGFloat(widthPercent) / 100, metrics.minimumWidth), visibleFrame.width)
        let height = min(max(visibleFrame.height * CGFloat(heightPercent) / 100, metrics.minimumHeight), visibleFrame.height)
        let x = min(max(center.x - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(center.y - height / 2, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Older form: `minimumTileWidth` stands for the whole standard layout scaled by
    /// `minimumTileWidth / OverviewSize.minimumTileWidth` (so the preview's `360 * scale` works).
    /// Prefer `frame(in:centeredOn:metrics:scale:)`.
    public func frame(in visibleFrame: CGRect, centeredOn center: CGPoint, minimumTileWidth: CGFloat) -> CGRect {
        frame(in: visibleFrame, centeredOn: center, scale: minimumTileWidth / Self.minimumTileWidth)
    }

    /// The centre of the compact panel's card on a screen, as `FloatingPanel.present` places it:
    /// centred horizontally, its top `compactPanelTopFraction` of the height below the top edge.
    /// The point the Overview grows from when the panel was not moved.
    ///
    /// `yAxisUp`: AppKit screen coordinates (default; the top edge is `maxY`). Pass `false` for a
    /// y-down space such as a SwiftUI preview (the top edge is `minY`).
    public static func compactCardCenter(in visibleFrame: CGRect, cardHeight: CGFloat, yAxisUp: Bool = true) -> CGPoint {
        let fromTop = visibleFrame.height * compactPanelTopFraction + cardHeight / 2
        let y = yAxisUp ? visibleFrame.maxY - fromTop : visibleFrame.minY + fromTop
        return CGPoint(x: visibleFrame.midX, y: y)
    }

    /// The compact panel's card top edge (AppKit, y up) on a screen; see `compactCardCenter`.
    public static func compactCardTop(in visibleFrame: CGRect) -> CGFloat {
        visibleFrame.maxY - visibleFrame.height * compactPanelTopFraction
    }

    private static func clamped(_ percent: Int) -> Int {
        min(max(percent, percentRange.lowerBound), percentRange.upperBound)
    }
}
