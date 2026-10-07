import Foundation

/// What plays when a todo is marked done (a Settings choice): nothing, the emoji rising out of
/// the card, or that emoji with a small confetti burst as it clears the edge.
public enum DoneAnimation: String, CaseIterable, Identifiable, Hashable, Sendable {
    case off
    case emoji
    case confetti

    public static let defaultsKey = "doneAnimation"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Nothing"
        case .emoji: "Emoji"
        case .confetti: "Emoji & Confetti"
        }
    }

    /// True when anything at all is drawn.
    public var showsEmoji: Bool { self != .off }

    /// True when the emoji fires a confetti burst.
    public var showsConfetti: Bool { self == .confetti }

    /// The stored setting; confetti when unset.
    public static func load(from defaults: UserDefaults = .standard) -> DoneAnimation {
        defaults.string(forKey: defaultsKey).flatMap(DoneAnimation.init(rawValue:)) ?? .confetti
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
