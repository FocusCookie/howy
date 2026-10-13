import CoreGraphics
import Foundation

/// Which edge of the panel's card stays put when the card changes height: `.top` grows it
/// downward (the card sits in the upper two thirds of the screen), `.bottom` grows it upward
/// (the card sits in the lower third).
public enum PanelAnchor: String, Codable, Hashable, Sendable {
    case top, bottom
}

/// Which horizontal third of the screen the card is in. It decides which edge stays put when the
/// card changes width (the panel zoom): the leading edge, the centre or the trailing edge.
public enum PanelColumn: String, Codable, Hashable, Sendable {
    case leading, center, trailing
}

/// The nine spots of the position picker (⌘⇧P): three rows (top, middle, bottom) of three
/// columns (leading, centre, trailing), in reading order.
public enum PanelSlot: String, CaseIterable, Hashable, Sendable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing

    /// 0 (top) to 2 (bottom).
    public var row: Int { Self.allCases.firstIndex(of: self)! / 3 }
    /// 0 (leading) to 2 (trailing).
    public var columnIndex: Int { Self.allCases.firstIndex(of: self)! % 3 }

    public var column: PanelColumn {
        switch columnIndex {
        case 0: .leading
        case 1: .center
        default: .trailing
        }
    }

    /// The slot at `row`, `column` (each 0...2), or `nil` outside the grid.
    public static func at(row: Int, column: Int) -> PanelSlot? {
        guard (0...2).contains(row), (0...2).contains(column) else { return nil }
        return allCases[row * 3 + column]
    }
}

/// Where the panel's card sits on a screen, independent of the screen's size: the card's anchor
/// point as a share of the visible frame (`visibleFrame`, without menu bar and Dock).
///
/// The anchor point is on the edges that stay put: horizontally the leading edge, the centre or
/// the trailing edge (`column`); vertically the top or the bottom edge (`anchor`). `x` runs from
/// the visible frame's leading edge (0) to its trailing edge (1), `y` from its top (0) down to its
/// bottom (1).
public struct PanelPosition: Codable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var anchor: PanelAnchor
    public var column: PanelColumn

    public init(x: CGFloat, y: CGFloat, anchor: PanelAnchor, column: PanelColumn) {
        self.x = x
        self.y = y
        self.anchor = anchor
        self.column = column
    }

    /// Where the panel always opened before it could be moved: centred horizontally, the card's
    /// top `OverviewSize.compactPanelTopFraction` of the height below the top edge. The middle
    /// slot of the position picker.
    public static let `default` = PanelPosition(x: 0.5, y: OverviewSize.compactPanelTopFraction, anchor: .top, column: .center)

    /// `x` and `y` pulled into 0...1 (a non-finite value becomes the default's).
    public var normalized: PanelPosition {
        func unit(_ value: CGFloat, _ fallback: CGFloat) -> CGFloat {
            value.isFinite ? min(max(value, 0), 1) : fallback
        }
        return PanelPosition(x: unit(x, Self.default.x), y: unit(y, Self.default.y), anchor: anchor, column: column)
    }
}

/// The window layout `FloatingPanel` uses for a position: its (mostly transparent) frame, where
/// the card sits in it and how tall the card may get.
public struct PanelLayout: Hashable, Sendable {
    /// The window's frame (screen coordinates, y up).
    public var windowFrame: CGRect
    /// The card's leading edge on screen.
    public var cardMinX: CGFloat
    /// The card's fixed edge on screen: its top (`.top`) or bottom (`.bottom`).
    public var anchorEdge: CGFloat
    public var anchor: PanelAnchor
    public var column: PanelColumn
    /// The card's corner at the fixed edge inside the window: `x` from the window's leading edge,
    /// `y` from its top edge (`.top`) or its bottom edge (`.bottom`).
    public var cardInset: CGPoint
    /// The tallest the card may get before it would leave the visible frame (keeping `edgeGap`).
    public var maxCardHeight: CGFloat

    /// Where a card `height` tall ends up on screen in this layout: at `cardMinX`, hanging from
    /// the top anchor edge or standing on the bottom one, and cut to `maxCardHeight`.
    public func cardFrame(height: CGFloat) -> CGRect {
        let height = min(height, maxCardHeight)
        let width = windowFrame.width - 2 * cardInset.x
        return CGRect(x: cardMinX, y: anchor == .top ? anchorEdge - height : anchorEdge, width: width, height: height)
    }
}

/// Turns a stored `PanelPosition` into frames on a screen and back. Pure geometry in AppKit
/// screen coordinates (y up); the app applies it to `NSScreen.visibleFrame`.
public enum PanelPlacement {
    /// How far the picker's slots sit inside the visible frame (below the menu bar, clear of the
    /// Dock and the screen's edges).
    public static let slotInset: CGFloat = 24
    /// Room the card keeps from the edge of the visible frame it grows towards.
    public static let edgeGap: CGFloat = 16
    /// The least room a layout leaves the card to grow into: a position too close to the edge it
    /// grows towards is moved away from it.
    public static let minimumRoom: CGFloat = 160

    // MARK: Slots

    /// The position of a picker slot on a screen: 24 pt inside the visible frame at the edges;
    /// the middle row has its top edge where the panel always opened (`PanelPosition.default`).
    /// The top and middle rows grow downward, the bottom row upward.
    public static func position(for slot: PanelSlot, in visible: CGRect) -> PanelPosition {
        let x: CGFloat =
            switch slot.column {
            case .leading: slotInset / visible.width
            case .center: 0.5
            case .trailing: 1 - slotInset / visible.width
            }
        switch slot.row {
        case 0: return PanelPosition(x: x, y: slotInset / visible.height, anchor: .top, column: slot.column)
        case 1: return PanelPosition(x: x, y: PanelPosition.default.y, anchor: .top, column: slot.column)
        default: return PanelPosition(x: x, y: 1 - slotInset / visible.height, anchor: .bottom, column: slot.column)
        }
    }

    /// The slot `position` is (within a point), or `nil` for a dragged position.
    public static func slot(at position: PanelPosition, in visible: CGRect) -> PanelSlot? {
        PanelSlot.allCases.first { slot in
            let candidate = self.position(for: slot, in: visible)
            return candidate.anchor == position.anchor && candidate.column == position.column
                && abs(candidate.x - position.x) * visible.width <= 1
                && abs(candidate.y - position.y) * visible.height <= 1
        }
    }

    /// The slot whose card frame (same size) is closest to `cardFrame`, centre to centre: where
    /// the picker's selection starts.
    public static func nearestSlot(toCardFrame cardFrame: CGRect, in visible: CGRect) -> PanelSlot {
        func distance(_ slot: PanelSlot) -> CGFloat {
            let frame = self.cardFrame(for: position(for: slot, in: visible), cardSize: cardFrame.size, in: visible)
            return hypot(frame.midX - cardFrame.midX, frame.midY - cardFrame.midY)
        }
        return PanelSlot.allCases.min { distance($0) < distance($1) }!
    }

    public static func nearestSlot(to position: PanelPosition, cardSize: CGSize, in visible: CGRect) -> PanelSlot {
        nearestSlot(toCardFrame: cardFrame(for: position, cardSize: cardSize, in: visible), in: visible)
    }

    // MARK: Positions and frames

    /// The card's frame for `position` on a screen, kept fully inside the visible frame.
    public static func cardFrame(for position: PanelPosition, cardSize: CGSize, in visible: CGRect) -> CGRect {
        let point = anchorPoint(of: position.normalized, in: visible)
        let minX = minX(anchorX: point.x, width: cardSize.width, column: position.column)
        let minY = position.anchor == .top ? point.y - cardSize.height : point.y
        return clamped(CGRect(x: minX, y: minY, width: cardSize.width, height: cardSize.height), in: visible)
    }

    /// The position of a card frame on a screen (after a drag): the column from the horizontal
    /// third its centre is in, the anchor `.bottom` when its centre is in the lower third.
    public static func position(fromCardFrame frame: CGRect, in visible: CGRect) -> PanelPosition {
        let across = (frame.midX - visible.minX) / visible.width
        let column: PanelColumn = across < 1.0 / 3 ? .leading : across > 2.0 / 3 ? .trailing : .center
        let up = (frame.midY - visible.minY) / visible.height
        let anchor: PanelAnchor = up < 1.0 / 3 ? .bottom : .top
        return position(fromCardFrame: frame, in: visible, anchor: anchor, column: column)
    }

    /// The position of a card frame with a given anchor and column (the card stays where it is,
    /// only the edges that count as fixed change).
    public static func position(fromCardFrame frame: CGRect, in visible: CGRect, anchor: PanelAnchor, column: PanelColumn) -> PanelPosition {
        let edgeX: CGFloat =
            switch column {
            case .leading: frame.minX
            case .center: frame.midX
            case .trailing: frame.maxX
            }
        let edgeY = anchor == .top ? frame.maxY : frame.minY
        return PanelPosition(
            x: (edgeX - visible.minX) / visible.width, y: (visible.maxY - edgeY) / visible.height,
            anchor: anchor, column: column
        )
    }

    /// `frame` moved (not resized) to lie fully inside `visible`. A card larger than the visible
    /// frame is pinned to its top-leading corner.
    public static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var result = frame
        result.origin.x = frame.width > visible.width ? visible.minX : min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        result.origin.y = frame.height > visible.height ? visible.maxY - frame.height : min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return result
    }

    // MARK: Window

    /// The panel window for `position`: the card `cardWidth` wide (kept on screen), with `margin`
    /// of transparent room around it for its shadow and effects. A top-anchored card has the
    /// window reach from above its top edge down to the bottom of the visible frame; a
    /// bottom-anchored one has it reach from below its bottom edge up past the top of the visible
    /// frame, so the transparent part where the card can grow is above the card. Either way the
    /// card keeps `minimumRoom` to grow into. With `screen` (the screen's whole frame) the window's
    /// top stops at the screen's top edge, and the card's inset above it shrinks to what is left.
    public static func layout(
        for position: PanelPosition, cardWidth: CGFloat, in visible: CGRect, margin: CGFloat, screen: CGRect? = nil
    ) -> PanelLayout {
        let position = position.normalized
        let point = anchorPoint(of: position, in: visible)
        var cardMinX = minX(anchorX: point.x, width: cardWidth, column: position.column)
        cardMinX = (cardWidth > visible.width ? visible.minX : min(max(cardMinX, visible.minX), visible.maxX - cardWidth)).rounded()
        let room = min(minimumRoom, visible.height)
        let windowX = cardMinX - margin
        let windowWidth = cardWidth + 2 * margin
        switch position.anchor {
        case .top:
            let top = min(max(point.y, visible.minY + room), visible.maxY).rounded()
            let windowTop = min(top + margin, screen?.maxY ?? .infinity)
            return PanelLayout(
                windowFrame: CGRect(x: windowX, y: visible.minY, width: windowWidth, height: windowTop - visible.minY),
                cardMinX: cardMinX, anchorEdge: top, anchor: .top, column: position.column,
                cardInset: CGPoint(x: margin, y: windowTop - top), maxCardHeight: top - visible.minY - edgeGap
            )
        case .bottom:
            let bottom = max(min(point.y, visible.maxY - room), visible.minY).rounded()
            let maxHeight = visible.maxY - edgeGap - bottom
            let windowTop = min(bottom + maxHeight + margin, screen?.maxY ?? .infinity)
            return PanelLayout(
                windowFrame: CGRect(x: windowX, y: bottom - margin, width: windowWidth, height: windowTop - bottom + margin),
                cardMinX: cardMinX, anchorEdge: bottom, anchor: .bottom, column: position.column,
                cardInset: CGPoint(x: margin, y: margin), maxCardHeight: maxHeight
            )
        }
    }

    /// The card's new leading edge when the zoom makes it `newWidth` wide: the column's edge
    /// stays (leading, centre or trailing), and the card stays on screen.
    public static func zoomedCardMinX(cardFrame: CGRect, newWidth: CGFloat, column: PanelColumn, in visible: CGRect) -> CGFloat {
        let minX: CGFloat =
            switch column {
            case .leading: cardFrame.minX
            case .center: cardFrame.midX - newWidth / 2
            case .trailing: cardFrame.maxX - newWidth
            }
        guard newWidth <= visible.width else { return visible.minX }
        return min(max(minX, visible.minX), visible.maxX - newWidth)
    }

    // MARK: Drag

    /// How far a drag moves the panel (its window and the card in it alike): the mouse's
    /// `translation` since the drag began, cut short so the card (`cardFrame`, where it was when
    /// the drag began) stays fully inside `visible`, the visible frame of the screen under the
    /// mouse. Whole points. The card can reach right up to the menu bar and down to the Dock: it
    /// is the card that is kept on screen, not the (larger, mostly transparent) window.
    public static func dragOffset(cardFrame: CGRect, translation: CGSize, in visible: CGRect) -> CGSize {
        let moved = cardFrame.offsetBy(dx: translation.width.rounded(), dy: translation.height.rounded())
        let kept = clamped(moved, in: visible)
        return CGSize(width: (kept.minX - cardFrame.minX).rounded(), height: (kept.minY - cardFrame.minY).rounded())
    }

    // MARK: Picker

    /// How far the position picker (`pickerSize`, centred on the card) moves so that it lies inside
    /// `bounds` (the visible frame within the window): a short card at an edge, or a zoomed picker,
    /// would otherwise reach past it. Screen coordinates (y up). A picker larger than `bounds` is
    /// pinned to its top-leading corner.
    public static func pickerOffset(pickerSize: CGSize, cardFrame: CGRect, bounds: CGRect) -> CGSize {
        let centred = CGRect(
            x: cardFrame.midX - pickerSize.width / 2, y: cardFrame.midY - pickerSize.height / 2,
            width: pickerSize.width, height: pickerSize.height
        )
        let fitted = clamped(centred, in: bounds)
        return CGSize(width: fitted.minX - centred.minX, height: fitted.minY - centred.minY)
    }

    // MARK: Helpers

    private static func anchorPoint(of position: PanelPosition, in visible: CGRect) -> CGPoint {
        CGPoint(x: visible.minX + position.x * visible.width, y: visible.maxY - position.y * visible.height)
    }

    private static func minX(anchorX: CGFloat, width: CGFloat, column: PanelColumn) -> CGFloat {
        switch column {
        case .leading: anchorX
        case .center: anchorX - width / 2
        case .trailing: anchorX - width
        }
    }
}

/// The panel's position in UserDefaults (`panelPosition`, JSON). One position for every panel.
public struct PanelPositionStore {
    public static let defaultsKey = "panelPosition"
    /// What `load()` gives when nothing (valid) is stored: where the panel always opened.
    public static let legacyDefault = PanelPosition.default

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored position, pulled into 0...1; the legacy default when none is stored or it
    /// can't be read.
    public func load() -> PanelPosition {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let position = try? JSONDecoder().decode(PanelPosition.self, from: data) else { return Self.legacyDefault }
        return position.normalized
    }

    public func save(_ position: PanelPosition) {
        guard let data = try? JSONEncoder().encode(position.normalized) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
