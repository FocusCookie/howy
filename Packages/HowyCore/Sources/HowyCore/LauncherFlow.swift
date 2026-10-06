import Foundation
import Observation

/// Whether Howy listens to one global shortcut that opens the launcher, or to separate
/// Quick Add and Browse shortcuts (a Settings choice; separate by default).
public enum ShortcutMode: Int, Hashable, Sendable, CaseIterable {
    case separate = 0
    case single = 1

    public static let defaultsKey = "shortcutMode"

    /// The stored setting; `.separate` when unset.
    public static func load(from defaults: UserDefaults = .standard) -> ShortcutMode {
        ShortcutMode(rawValue: defaults.integer(forKey: defaultsKey)) ?? .separate
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// The two things the launcher opens, left to right.
public enum LauncherChoice: Int, Hashable, Sendable, CaseIterable {
    case create = 1
    case browse = 2

    public var shortcutNumber: Int { rawValue }

    /// Where the launcher's highlight starts (a Settings choice; New Todo by default).
    public static let defaultsKey = "launcherDefaultChoice"

    /// The stored start choice; `.create` when unset.
    public static func loadDefault(from defaults: UserDefaults = .standard) -> LauncherChoice {
        LauncherChoice(rawValue: defaults.integer(forKey: defaultsKey)) ?? .create
    }

    public func saveAsDefault(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// UI-independent state machine behind the launcher: the single-shortcut modal that offers
/// "New Todo" and "Browse" side by side.
///
/// Keys: ←/↑ highlight New Todo, →/↓ highlight Browse; 1 / 2 open that choice; Enter/Tab open
/// the highlighted one; Esc closes. Everything else is swallowed. Once closed or opened, every
/// key is `.ignored`.
@MainActor
@Observable
public final class LauncherFlow {
    public enum Outcome: Hashable, Sendable {
        case ignored
        case handled
        case open(LauncherChoice)
        case close
    }

    public private(set) var highlighted: LauncherChoice
    public private(set) var isFinished = false

    public init(highlighted: LauncherChoice = .create) {
        self.highlighted = highlighted
    }

    @discardableResult
    public func handle(_ key: QuickEntryKey) -> Outcome {
        guard !isFinished else { return .ignored }
        switch key {
        case .left, .up: highlighted = .create
        case .right, .down: highlighted = .browse
        case .digit(let n):
            if let choice = LauncherChoice(rawValue: n) { return open(choice) }
        case .enter, .tab: return open(highlighted)
        case .escape:
            isFinished = true
            return .close
        default: break
        }
        return .handled
    }

    /// Opens a choice (a click, or its key).
    @discardableResult
    public func open(_ choice: LauncherChoice) -> Outcome {
        guard !isFinished else { return .ignored }
        highlighted = choice
        isFinished = true
        return .open(choice)
    }
}
