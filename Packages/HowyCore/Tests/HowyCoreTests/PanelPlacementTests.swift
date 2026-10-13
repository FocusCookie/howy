import CoreGraphics
import Foundation
import Testing
@testable import HowyCore

/// Where the panel's card sits on a screen (AppKit coordinates: y points up).
@Suite struct PanelPlacementTests {
    /// A 1500×900 visible frame above a 30 pt Dock, below a 30 pt menu bar.
    static let visible = CGRect(x: 0, y: 30, width: 1500, height: 900)
    static let card = CGSize(width: 600, height: 300)
    static let inset = PanelPlacement.slotInset

    func frame(_ slot: PanelSlot, size: CGSize = card, in visible: CGRect = visible) -> CGRect {
        PanelPlacement.cardFrame(for: PanelPlacement.position(for: slot, in: visible), cardSize: size, in: visible)
    }

    // MARK: Slots

    @Test func theInsetIs24Points() {
        #expect(PanelPlacement.slotInset == 24)
    }

    @Test func everySlotOnAPlainScreen() {
        let v = Self.visible
        let w = Self.card.width, h = Self.card.height
        let left = v.minX + 24, center = v.midX - w / 2, right = v.maxX - 24 - w
        let top = v.maxY - 24 - h, middle = v.maxY - v.height * 0.22 - h, bottom = v.minY + 24
        let expected: [PanelSlot: CGPoint] = [
            .topLeading: CGPoint(x: left, y: top), .top: CGPoint(x: center, y: top), .topTrailing: CGPoint(x: right, y: top),
            .leading: CGPoint(x: left, y: middle), .center: CGPoint(x: center, y: middle), .trailing: CGPoint(x: right, y: middle),
            .bottomLeading: CGPoint(x: left, y: bottom), .bottom: CGPoint(x: center, y: bottom),
            .bottomTrailing: CGPoint(x: right, y: bottom),
        ]
        for slot in PanelSlot.allCases {
            let frame = frame(slot)
            #expect(isClose(frame.origin, expected[slot]!), "\(slot): \(frame)")
            #expect(frame.size == Self.card)
        }
    }

    @Test(arguments: [
        CGRect(x: 200, y: 80, width: 1200, height: 760), // origin not at (0, 0)
        CGRect(x: -1920, y: -120, width: 1920, height: 1050), // a second screen to the left, lower
    ])
    func cornersKeepTheInsetOnAnyScreen(visible: CGRect) {
        let topLeading = frame(.topLeading, in: visible)
        #expect(isClose(topLeading.minX, visible.minX + 24))
        #expect(isClose(topLeading.maxY, visible.maxY - 24))
        let bottomTrailing = frame(.bottomTrailing, in: visible)
        #expect(isClose(bottomTrailing.maxX, visible.maxX - 24))
        #expect(isClose(bottomTrailing.minY, visible.minY + 24))
        for slot in PanelSlot.allCases {
            #expect(visible.contains(frame(slot, in: visible)), "\(slot)")
        }
    }

    @Test func slotRowsAndColumns() {
        #expect(PanelSlot.topLeading.column == .leading)
        #expect(PanelSlot.bottom.column == .center)
        #expect(PanelSlot.trailing.column == .trailing)
        for slot in PanelSlot.allCases {
            let position = PanelPlacement.position(for: slot, in: Self.visible)
            #expect(position.column == slot.column)
            #expect(position.anchor == (slot.row == 2 ? .bottom : .top), "\(slot)")
        }
    }

    /// The middle slot is where the panel always opened before it could be moved.
    @Test func centerIsTheLegacyDefault() {
        #expect(PanelPlacement.position(for: .center, in: Self.visible) == .default)
        #expect(PanelPositionStore.legacyDefault == .default)
        let v = Self.visible
        let frame = frame(.center)
        #expect(isClose(frame.midX, v.midX))
        #expect(isClose(frame.maxY, OverviewSize.compactCardTop(in: v)))
    }

    // MARK: Normalised positions

    @Test(arguments: [
        CGRect(x: 100, y: 200, width: 600, height: 300), // upper left
        CGRect(x: 820, y: 40, width: 600, height: 200), // lower right
        CGRect(x: 450, y: 400, width: 600, height: 250), // middle
    ])
    func roundTripOnTheSameScreen(card: CGRect) {
        let position = PanelPlacement.position(fromCardFrame: card, in: Self.visible)
        let back = PanelPlacement.cardFrame(for: position, cardSize: card.size, in: Self.visible)
        #expect(isClose(back, card), "\(back) vs \(card)")
    }

    @Test func theSameRelativeSpotOnAnotherScreen() {
        let small = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let large = CGRect(x: 1000, y: -200, width: 2000, height: 1200)
        let card = CGSize(width: 200, height: 100)
        // Left edge 10 % in, top edge 20 % down.
        let onSmall = CGRect(x: 100, y: 600 - 120 - 100, width: 200, height: 100)
        let position = PanelPlacement.position(fromCardFrame: onSmall, in: small)
        let onLarge = PanelPlacement.cardFrame(for: position, cardSize: card, in: large)
        #expect(isClose(onLarge.minX, large.minX + 200))
        #expect(isClose(onLarge.maxY, large.maxY - 240))
    }

    @Test func anchorFromTheVerticalThird() {
        let v = CGRect(x: 0, y: 0, width: 900, height: 900)
        func anchor(centerY: CGFloat) -> PanelAnchor {
            PanelPlacement.position(fromCardFrame: CGRect(x: 300, y: centerY - 50, width: 300, height: 100), in: v).anchor
        }
        #expect(anchor(centerY: 100) == .bottom)
        #expect(anchor(centerY: 299) == .bottom)
        #expect(anchor(centerY: 301) == .top)
        #expect(anchor(centerY: 450) == .top)
        #expect(anchor(centerY: 800) == .top)
    }

    @Test func columnFromTheHorizontalThird() {
        let v = CGRect(x: 0, y: 0, width: 900, height: 900)
        func column(centerX: CGFloat) -> PanelColumn {
            PanelPlacement.position(fromCardFrame: CGRect(x: centerX - 100, y: 500, width: 200, height: 100), in: v).column
        }
        #expect(column(centerX: 120) == .leading)
        #expect(column(centerX: 299) == .leading)
        #expect(column(centerX: 301) == .center)
        #expect(column(centerX: 599) == .center)
        #expect(column(centerX: 601) == .trailing)
    }

    // MARK: Clamping

    @Test func clampingKeepsTheCardInside() {
        let v = Self.visible
        let offRight = CGRect(x: 1400, y: 500, width: 600, height: 300)
        #expect(PanelPlacement.clamped(offRight, in: v) == CGRect(x: 900, y: 500, width: 600, height: 300))
        let offBottomLeft = CGRect(x: -50, y: -100, width: 600, height: 300)
        #expect(PanelPlacement.clamped(offBottomLeft, in: v) == CGRect(x: 0, y: 30, width: 600, height: 300))
        let inside = CGRect(x: 100, y: 100, width: 600, height: 300)
        #expect(PanelPlacement.clamped(inside, in: v) == inside)
    }

    @Test func anOversizedCardIsPinnedToTheTopLeading() {
        let v = Self.visible
        let huge = CGRect(x: 300, y: -500, width: 1800, height: 1200)
        let clamped = PanelPlacement.clamped(huge, in: v)
        #expect(clamped.size == huge.size)
        #expect(clamped.minX == v.minX)
        #expect(clamped.maxY == v.maxY)
    }

    @Test func aPositionOffTheScreenLandsInside() {
        let position = PanelPosition(x: 1.4, y: -0.3, anchor: .top, column: .trailing)
        let frame = PanelPlacement.cardFrame(for: position, cardSize: Self.card, in: Self.visible)
        #expect(Self.visible.contains(frame))
    }

    // MARK: Nearest slot

    @Test func nearestSlotOfAFreelyDraggedCard() {
        let v = Self.visible
        let size = Self.card
        func nearest(_ origin: CGPoint) -> PanelSlot {
            PanelPlacement.nearestSlot(toCardFrame: CGRect(origin: origin, size: size), in: v)
        }
        #expect(nearest(CGPoint(x: 60, y: 580)) == .topLeading)
        #expect(nearest(CGPoint(x: 800, y: 590)) == .topTrailing)
        #expect(nearest(CGPoint(x: 460, y: 400)) == .center)
        #expect(nearest(CGPoint(x: 430, y: 70)) == .bottom)
        #expect(nearest(CGPoint(x: 880, y: 40)) == .bottomTrailing)
        for slot in PanelSlot.allCases {
            #expect(nearest(frame(slot).origin) == slot)
            let position = PanelPlacement.position(for: slot, in: v)
            #expect(PanelPlacement.nearestSlot(to: position, cardSize: size, in: v) == slot)
            #expect(PanelPlacement.slot(at: position, in: v) == slot)
        }
    }

    @Test func aDraggedPositionIsNoSlot() {
        let position = PanelPlacement.position(fromCardFrame: CGRect(x: 433, y: 377, width: 600, height: 300), in: Self.visible)
        #expect(PanelPlacement.slot(at: position, in: Self.visible) == nil)
    }

    // MARK: Window layout

    static let margin: CGFloat = 128

    @Test func topAnchoredWindowReachesDownToTheScreenBottom() {
        let v = Self.visible
        let layout = PanelPlacement.layout(for: .default, cardWidth: 600, in: v, margin: Self.margin)
        let cardTop = OverviewSize.compactCardTop(in: v)
        #expect(layout.anchor == .top)
        #expect(layout.windowFrame == CGRect(x: v.midX - 300 - 128, y: v.minY, width: 600 + 256, height: cardTop + 128 - v.minY))
        #expect(layout.cardInset == CGPoint(x: 128, y: 128))
        #expect(layout.maxCardHeight == cardTop - v.minY - PanelPlacement.edgeGap)
        #expect(layout.cardMinX == v.midX - 300)
        #expect(layout.anchorEdge == cardTop)
    }

    @Test func bottomAnchoredWindowLeavesTheTransparentPartAboveTheCard() {
        let v = Self.visible
        let position = PanelPlacement.position(for: .bottomLeading, in: v)
        let layout = PanelPlacement.layout(for: position, cardWidth: 600, in: v, margin: Self.margin)
        let cardBottom = v.minY + 24
        #expect(layout.anchor == .bottom)
        #expect(layout.anchorEdge == cardBottom)
        #expect(layout.cardMinX == v.minX + 24)
        // Below the card: just the margin. Above it: room to grow up to the top, plus the margin.
        #expect(layout.windowFrame.minY == cardBottom - 128)
        #expect(layout.windowFrame.minX == v.minX + 24 - 128)
        #expect(isClose(layout.windowFrame.width, 600 + 256))
        #expect(layout.maxCardHeight == v.maxY - PanelPlacement.edgeGap - cardBottom)
        #expect(layout.windowFrame.maxY == cardBottom + layout.maxCardHeight + 128)
        #expect(layout.cardInset == CGPoint(x: 128, y: 128))
    }

    @Test func aLayoutAlwaysLeavesRoomForTheCard() {
        let v = Self.visible
        let low = PanelPosition(x: 0.5, y: 0.99, anchor: .top, column: .center)
        #expect(PanelPlacement.layout(for: low, cardWidth: 600, in: v, margin: 128).maxCardHeight >= PanelPlacement.minimumRoom - PanelPlacement.edgeGap)
        let high = PanelPosition(x: 0.5, y: 0.01, anchor: .bottom, column: .center)
        #expect(PanelPlacement.layout(for: high, cardWidth: 600, in: v, margin: 128).maxCardHeight >= PanelPlacement.minimumRoom - PanelPlacement.edgeGap)
    }

    // MARK: Zoom

    @Test func zoomKeepsTheColumnsEdge() {
        let v = Self.visible
        let card = CGRect(x: 100, y: 400, width: 600, height: 300)
        #expect(PanelPlacement.zoomedCardMinX(cardFrame: card, newWidth: 690, column: .leading, in: v) == 100)
        #expect(PanelPlacement.zoomedCardMinX(cardFrame: card, newWidth: 690, column: .center, in: v) == 55)
        #expect(PanelPlacement.zoomedCardMinX(cardFrame: card, newWidth: 690, column: .trailing, in: v) == 10)
        // Never past the screen's edge.
        #expect(PanelPlacement.zoomedCardMinX(cardFrame: card, newWidth: 900, column: .trailing, in: v) == 0)
        let right = CGRect(x: 880, y: 400, width: 600, height: 300)
        #expect(PanelPlacement.zoomedCardMinX(cardFrame: right, newWidth: 900, column: .leading, in: v) == 600)
    }

    // MARK: Helpers

    func isClose(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
    func isClose(_ a: CGPoint, _ b: CGPoint) -> Bool { isClose(a.x, b.x) && isClose(a.y, b.y) }
    func isClose(_ a: CGRect, _ b: CGRect) -> Bool { isClose(a.origin, b.origin) && isClose(a.width, b.width) && isClose(a.height, b.height) }
}

@Suite struct PanelPositionStoreTests {
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "PanelPositionStoreTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func emptyGivesTheLegacyDefault() throws {
        try withDefaults { defaults in
            #expect(PanelPositionStore(defaults: defaults).load() == .default)
        }
    }

    @Test func saveThenLoad() throws {
        try withDefaults { defaults in
            let position = PanelPosition(x: 0.1, y: 0.8, anchor: .bottom, column: .leading)
            PanelPositionStore(defaults: defaults).save(position)
            #expect(PanelPositionStore(defaults: defaults).load() == position)
            #expect(defaults.data(forKey: PanelPositionStore.defaultsKey) != nil)
        }
    }

    @Test func garbageGivesTheDefault() throws {
        try withDefaults { defaults in
            defaults.set("nonsense", forKey: PanelPositionStore.defaultsKey)
            #expect(PanelPositionStore(defaults: defaults).load() == .default)
            defaults.set(Data("{\"x\":1}".utf8), forKey: PanelPositionStore.defaultsKey)
            #expect(PanelPositionStore(defaults: defaults).load() == .default)
        }
    }

    @Test func aStoredPositionOutsideTheScreenIsPulledIn() throws {
        try withDefaults { defaults in
            PanelPositionStore(defaults: defaults).save(PanelPosition(x: 3, y: -1, anchor: .top, column: .center))
            let loaded = PanelPositionStore(defaults: defaults).load()
            #expect(loaded.x == 1)
            #expect(loaded.y == 0)
        }
    }
}
