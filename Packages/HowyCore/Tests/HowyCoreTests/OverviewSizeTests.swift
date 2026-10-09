import CoreGraphics
import Foundation
import Testing
@testable import HowyCore

@Suite struct OverviewSizeTests {
    /// A 1512×945 laptop screen with a 33 pt menu bar on top (AppKit: origin bottom-left).
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 945)
    let metrics = OverviewSize.Metrics.standard

    /// A throwaway defaults domain; `body` runs with it and it is removed afterwards.
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "OverviewSizeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // MARK: Setting

    @Test func eightyPercentIsTheDefault() throws {
        try withDefaults { defaults in
            let size = OverviewSize.load(from: defaults)
            #expect(size == .default)
            #expect(size.widthPercent == 80)
            #expect(size.heightPercent == 80)
        }
    }

    @Test func roundTripsThroughUserDefaults() throws {
        try withDefaults { defaults in
            OverviewSize(widthPercent: 65, heightPercent: 90).save(to: defaults)
            #expect(OverviewSize.load(from: defaults) == OverviewSize(widthPercent: 65, heightPercent: 90))
        }
    }

    @Test func storedValuesOutsideTheRangeAreClamped() throws {
        try withDefaults { defaults in
            defaults.set(10, forKey: OverviewSize.widthDefaultsKey)
            defaults.set(120, forKey: OverviewSize.heightDefaultsKey)
            #expect(OverviewSize.load(from: defaults) == OverviewSize(widthPercent: 50, heightPercent: 95))
        }
    }

    @Test func garbageFallsBackToTheDefaultForThatDimension() throws {
        try withDefaults { defaults in
            defaults.set("wide", forKey: OverviewSize.widthDefaultsKey)
            defaults.set(60, forKey: OverviewSize.heightDefaultsKey)
            #expect(OverviewSize.load(from: defaults) == OverviewSize(widthPercent: 80, heightPercent: 60))
            defaults.set(Data([1, 2]), forKey: OverviewSize.heightDefaultsKey)
            #expect(OverviewSize.load(from: defaults) == .default)
        }
    }

    @Test func aNumberStoredAsTextIsRead() throws {
        try withDefaults { defaults in
            defaults.set("70", forKey: OverviewSize.widthDefaultsKey)
            #expect(OverviewSize.load(from: defaults) == OverviewSize(widthPercent: 70, heightPercent: 80))
        }
    }

    @Test func onlyOneKeySetKeepsTheOtherDefault() throws {
        try withDefaults { defaults in
            defaults.set(55, forKey: OverviewSize.heightDefaultsKey)
            #expect(OverviewSize.load(from: defaults) == OverviewSize(widthPercent: 80, heightPercent: 55))
        }
    }

    @Test func initClampsToTheRange() {
        #expect(OverviewSize(widthPercent: 0, heightPercent: 100) == OverviewSize(widthPercent: 50, heightPercent: 95))
        #expect(OverviewSize.percentRange == 50...95)
    }

    @Test func withChangesOneDimensionClamped() {
        let size = OverviewSize(widthPercent: 70, heightPercent: 60)
        #expect(size.with(widthPercent: 90) == OverviewSize(widthPercent: 90, heightPercent: 60))
        #expect(size.with(heightPercent: 99) == OverviewSize(widthPercent: 70, heightPercent: 95))
        #expect(size.with(widthPercent: 1).widthPercent == 50)
    }

    // MARK: Metrics

    @Test func minimumsIncludeTheChrome() {
        // 2 tiles of 360 + their 12 pt padding, the 10 pt gap, the card's 16 pt padding; in
        // height also Browse's footer (30 pt with its gap) below the tiles.
        let width: CGFloat = 2 * 360 + 10 + 32 + 48
        let height: CGFloat = 2 * 320 + 10 + 30 + 32
        #expect(metrics.minimumWidth == width)
        #expect(metrics.minimumHeight == height)
        #expect(metrics.scaled(by: 0.5).minimumWidth == metrics.minimumWidth * 0.5)
        #expect(metrics.scaled(by: 0.5).minimumHeight == metrics.minimumHeight * 0.5)
    }

    // MARK: Frame

    @Test func defaultFrameIsEightyPercentAroundThePanelCentre() {
        let frame = OverviewSize.default.frame(in: laptop, centeredOn: CGPoint(x: 756, y: 472.5))
        #expect(frame.width == CGFloat(1512) * 80 / 100)
        #expect(frame.height == CGFloat(945) * 80 / 100)
        #expect(frame.midX == 756)
        #expect(frame.midY == 472.5)
    }

    @Test func frameIsClampedIntoTheVisibleFrame() {
        let frame = OverviewSize.default.frame(in: laptop, centeredOn: CGPoint(x: 100, y: 900))
        #expect(frame.size == CGSize(width: CGFloat(1512) * 80 / 100, height: CGFloat(945) * 80 / 100))
        #expect(frame.minX == laptop.minX)
        #expect(frame.maxY == laptop.maxY)
    }

    @Test func frameStaysOnASecondScreen() {
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1415)
        let frame = OverviewSize.default.frame(in: external, centeredOn: CGPoint(x: 4000, y: -150))
        #expect(external.contains(frame))
        #expect(frame.maxX == external.maxX)
        #expect(frame.minY == external.minY)
    }

    @Test func narrowSettingGrowsToTheMinimumWidth() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 900)
        let size = OverviewSize(widthPercent: 50, heightPercent: 80)
        let frame = size.frame(in: screen, centeredOn: CGPoint(x: 640, y: 450))
        #expect(frame.width == metrics.minimumWidth, "640 pt would make tiles narrower than 360")
        #expect(frame.midX == 640)
    }

    @Test func lowSettingGrowsToTheMinimumHeight() {
        let size = OverviewSize(widthPercent: 80, heightPercent: 50)
        let frame = size.frame(in: laptop, centeredOn: CGPoint(x: 756, y: 472.5))
        #expect(frame.height == metrics.minimumHeight, "472 pt would not fit the in-tile editor")
        #expect(frame.midY == 472.5)
    }

    @Test func smallScreenUsesTheWholeVisibleFrameAtMost() {
        let small = CGRect(x: 0, y: 0, width: 640, height: 480)
        let frame = OverviewSize.default.frame(in: small, centeredOn: CGPoint(x: 320, y: 240))
        #expect(frame == small)
    }

    @Test(arguments: [-1, 0, 1] as [CGFloat])
    func widthAtTheMinimumBoundary(delta: CGFloat) {
        // 50 % of this screen is exactly the minimum width, give or take a point.
        let screen = CGRect(x: 0, y: 0, width: 2 * metrics.minimumWidth + 2 * delta, height: 1000)
        let frame = OverviewSize(widthPercent: 50, heightPercent: 80)
            .frame(in: screen, centeredOn: CGPoint(x: screen.midX, y: screen.midY))
        #expect(frame.width == max(metrics.minimumWidth, screen.width / 2))
        #expect(screen.contains(frame))
    }

    @Test func offsetScreenWithTheCentreNearItsEdge() {
        let screen = CGRect(x: -1920, y: 300, width: 1920, height: 1050)
        let frame = OverviewSize.default.frame(in: screen, centeredOn: CGPoint(x: -5, y: 1340))
        #expect(screen.contains(frame))
        #expect(frame.maxX == screen.maxX)
        #expect(frame.maxY == screen.maxY)
        #expect(frame.width == 1920 * 0.8)
    }

    @Test func tallNarrowScreen() {
        let portrait = CGRect(x: 0, y: 0, width: 900, height: 1600)
        let frame = OverviewSize.default.frame(in: portrait, centeredOn: CGPoint(x: 450, y: 800))
        #expect(frame.width == metrics.minimumWidth, "80 % of 900 is too narrow; 810 fits")
        #expect(frame.height == 1600 * 0.8)
        #expect(portrait.contains(frame))
    }

    @Test func narrowScreenAtNinetyFivePercentTakesTheWholeWidth() {
        let narrow = CGRect(x: 100, y: 50, width: 800, height: 700)
        let frame = OverviewSize(widthPercent: 95, heightPercent: 95)
            .frame(in: narrow, centeredOn: CGPoint(x: 120, y: 60))
        #expect(frame.width == narrow.width, "below the minimum width: all of it")
        #expect(frame.height == narrow.height, "95 % is 665, below the minimum height of 712: all of it")
        #expect(narrow.contains(frame))
    }

    @Test(arguments: [
        OverviewSize.default, OverviewSize(widthPercent: 50, heightPercent: 50), OverviewSize(widthPercent: 95, heightPercent: 95),
    ])
    func everyFrameFitsAndRespectsTheMinimums(size: OverviewSize) {
        let screens = [laptop, CGRect(x: 0, y: 0, width: 1024, height: 640), CGRect(x: 3000, y: -500, width: 3840, height: 2135)]
        for screen in screens {
            let frame = size.frame(in: screen, centeredOn: CGPoint(x: screen.minX + 10, y: screen.maxY - 10))
            #expect(screen.contains(frame))
            #expect(frame.width >= metrics.minimumWidth || frame.width == screen.width)
            #expect(frame.height >= metrics.minimumHeight || frame.height == screen.height)
        }
    }

    // MARK: Preview scaling

    @Test(arguments: [
        OverviewSize.default, // the set share wins
        OverviewSize(widthPercent: 50, heightPercent: 50), // the minimums win
    ])
    func aScaledScreenGivesTheScaledFrame(size: OverviewSize) {
        let k: CGFloat = 0.125
        let real = size.frame(in: laptop, centeredOn: CGPoint(x: 700, y: 500))
        let scaledScreen = CGRect(x: laptop.minX * k, y: laptop.minY * k, width: laptop.width * k, height: laptop.height * k)
        let scaled = size.frame(in: scaledScreen, centeredOn: CGPoint(x: 700 * k, y: 500 * k), scale: k)
        #expect(abs(scaled.minX - real.minX * k) < 0.0001)
        #expect(abs(scaled.minY - real.minY * k) < 0.0001)
        #expect(abs(scaled.width - real.width * k) < 0.0001)
        #expect(abs(scaled.height - real.height * k) < 0.0001)
        let legacy = size.frame(in: scaledScreen, centeredOn: CGPoint(x: 700 * k, y: 500 * k), minimumTileWidth: OverviewSize.minimumTileWidth * k)
        #expect(legacy == scaled, "the older minimumTileWidth form scales the whole layout")
    }

    // MARK: Placement

    @Test func compactCardCentreMatchesThePanelPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let centre = OverviewSize.compactCardCenter(in: screen, cardHeight: 300)
        #expect(centre.x == 756)
        #expect(abs(centre.y - (945 - 945 * 0.22 - 150)) < 0.0001)
        #expect(OverviewSize.compactCardTop(in: screen) == 945 - 945 * 0.22)
        let flipped = OverviewSize.compactCardCenter(in: screen, cardHeight: 300, yAxisUp: false)
        #expect(abs(flipped.y - (945 * 0.22 + 150)) < 0.0001)
        #expect(abs(flipped.y + centre.y - screen.height) < 0.0001, "the same place, counted from the top")
    }

    @Test func compactCardCentreOnAnOffsetScreen() {
        let screen = CGRect(x: 1512, y: -200, width: 2560, height: 1400)
        let centre = OverviewSize.compactCardCenter(in: screen, cardHeight: 200)
        #expect(centre.x == screen.midX)
        #expect(abs(centre.y - (screen.maxY - 1400 * 0.22 - 100)) < 0.0001)
    }
}
