import CoreGraphics
import Foundation
import Testing
@testable import HowyCore

@Suite struct PanelZoomTests {
    /// A throwaway defaults domain; `body` runs with it and it is removed afterwards.
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "PanelZoomTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// Runs a mutating zoom call outside `#expect` (the macro can't call mutating members).
    func step(_ zoom: inout PanelZoom, _ change: (inout PanelZoom) -> Bool) -> Bool {
        change(&zoom)
    }

    // MARK: Levels

    @Test func theDefaultIsTheSmallestLevel() {
        #expect(PanelZoom.default.step == 0)
        #expect(PanelZoom.default.scale == 1)
        #expect(PanelZoom.default.percent == 100)
        #expect(PanelZoom.default == .minimum)
        #expect(PanelZoom.default.isMinimum)
        #expect(!PanelZoom.default.isMaximum)
    }

    @Test func fourStepsWithTheirScalesAndPercentages() {
        #expect(PanelZoom.all.map(\.step) == [0, 1, 2, 3])
        #expect(PanelZoom.all.map(\.scale) == [1.0, 1.15, 1.30, 1.50])
        #expect(PanelZoom.all.map(\.percent) == [100, 115, 130, 150])
        #expect(PanelZoom.maximum.step == 3)
        #expect(PanelZoom.maximum.isMaximum)
    }

    @Test func initClampsTheStep() {
        #expect(PanelZoom(step: -2) == .minimum)
        #expect(PanelZoom(step: 9) == .maximum)
        #expect(PanelZoom(step: 2).percent == 130)
    }

    // MARK: Stepping

    @Test func zoomingInStepsUpToTheMaximum() {
        var zoom = PanelZoom.default
        #expect(step(&zoom, { $0.zoomIn() }))
        #expect(zoom.percent == 115)
        #expect(step(&zoom, { $0.zoomIn() }))
        #expect(zoom.percent == 130)
        #expect(step(&zoom, { $0.zoomIn() }))
        #expect(zoom.percent == 150)
        #expect(!step(&zoom, { $0.zoomIn() }), "at 150 % it reports the limit (the app beeps)")
        #expect(zoom == .maximum, "and stays there")
    }

    @Test func zoomingOutStepsDownToTheMinimum() {
        var zoom = PanelZoom.maximum
        #expect(step(&zoom, { $0.zoomOut() }))
        #expect(zoom.percent == 130)
        #expect(step(&zoom, { $0.zoomOut() }))
        #expect(step(&zoom, { $0.zoomOut() }))
        #expect(zoom == .default)
        #expect(!step(&zoom, { $0.zoomOut() }), "at 100 % it reports the limit (the app beeps)")
        #expect(zoom == .default, "and stays there")
    }

    @Test(arguments: PanelZoom.all)
    func resetGoesBackToTheDefault(start: PanelZoom) {
        var zoom = start
        let changed = zoom.reset()
        #expect(zoom == .default)
        #expect(changed == (start != .default), "reports whether anything changed")
    }

    // MARK: Setting

    @Test func missingSettingIsTheDefault() throws {
        try withDefaults { defaults in
            #expect(PanelZoom.load(from: defaults) == .default)
        }
    }

    @Test(arguments: PanelZoom.all)
    func roundTripsThroughUserDefaults(zoom: PanelZoom) throws {
        try withDefaults { defaults in
            zoom.save(to: defaults)
            #expect(PanelZoom.load(from: defaults) == zoom)
        }
    }

    @Test func savesTheStepUnderItsKey() throws {
        try withDefaults { defaults in
            PanelZoom(step: 2).save(to: defaults)
            #expect(defaults.integer(forKey: PanelZoom.defaultsKey) == 2)
            #expect(PanelZoom.defaultsKey == "panelZoomStep")
        }
    }

    @Test func aStepStoredAsTextIsRead() throws {
        try withDefaults { defaults in
            defaults.set("1", forKey: PanelZoom.defaultsKey)
            #expect(PanelZoom.load(from: defaults) == PanelZoom(step: 1))
        }
    }

    @Test func invalidStoredValuesFallBackToTheDefault() throws {
        let invalid: [Any] = [-1, 4, 99, 1.5, "big", "", Data([1, 2]), [1]]
        for stored in invalid {
            try withDefaults { defaults in
                defaults.set(stored, forKey: PanelZoom.defaultsKey)
                #expect(PanelZoom.load(from: defaults) == .default, "\(stored)")
            }
        }
    }
}
