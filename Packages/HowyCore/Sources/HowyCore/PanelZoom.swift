import CoreGraphics
import Foundation

/// How big everything inside a Howy panel is drawn (⌘+ / ⌘- / ⌘0 in a panel, and a slider in
/// Settings): one of four fixed steps, 100 % (the default and the smallest) to 150 %.
/// One global setting for all panels; widgets and normal windows don't zoom.
public struct PanelZoom: Hashable, Sendable, Identifiable {
    public static let defaultsKey = "panelZoomStep"
    /// The scale of each step, smallest first.
    public static let scales: [CGFloat] = [1.0, 1.15, 1.30, 1.50]
    /// The valid steps (`0...3`).
    public static let steps = 0...(scales.count - 1)
    /// Every level, smallest first (the Settings slider's stops).
    public static let all = steps.map(PanelZoom.init(step:))
    public static let minimum = PanelZoom(step: steps.lowerBound)
    public static let maximum = PanelZoom(step: steps.upperBound)
    /// 100 %: the smallest level.
    public static let `default` = minimum

    /// 0 (100 %) to 3 (150 %).
    public private(set) var step: Int

    /// A level; a step outside `steps` is clamped.
    public init(step: Int) {
        self.step = min(max(step, Self.steps.lowerBound), Self.steps.upperBound)
    }

    public var id: Int { step }

    /// The factor every font size and layout length in a panel is multiplied by.
    public var scale: CGFloat { Self.scales[step] }

    /// The scale as a whole percentage for display: 100, 115, 130 or 150.
    public var percent: Int { Int((scale * 100).rounded()) }

    public var isMinimum: Bool { step == Self.steps.lowerBound }
    public var isMaximum: Bool { step == Self.steps.upperBound }

    /// One step bigger. `false` when already at the largest level (nothing changes; the app beeps).
    @discardableResult
    public mutating func zoomIn() -> Bool {
        guard !isMaximum else { return false }
        step += 1
        return true
    }

    /// One step smaller. `false` when already at the smallest level (nothing changes; the app beeps).
    @discardableResult
    public mutating func zoomOut() -> Bool {
        guard !isMinimum else { return false }
        step -= 1
        return true
    }

    /// Back to 100 %. `false` when it already was (not a limit: no beep needed).
    @discardableResult
    public mutating func reset() -> Bool {
        guard self != .default else { return false }
        self = .default
        return true
    }

    /// The stored setting. Unset, not a whole number, or outside `steps` → the default (100 %).
    public static func load(from defaults: UserDefaults = .standard) -> PanelZoom {
        let stored: Int? =
            switch defaults.object(forKey: defaultsKey) {
            case let number as NSNumber where number.doubleValue == Double(number.intValue): number.intValue
            case let text as String: Int(text.trimmingCharacters(in: .whitespaces))
            default: nil
            }
        guard let stored, steps.contains(stored) else { return .default }
        return PanelZoom(step: stored)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(step, forKey: Self.defaultsKey)
    }
}
