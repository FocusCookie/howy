import Foundation

/// The emoji that shoots out of the Browse list when a todo is marked done: a random one each
/// time, never the same twice in a row, so there is always a small surprise.
public struct DoneEmoji: Sendable {
    public static let all: [String] = [
        "🎉", "✨", "🚀", "🔥", "💪", "🙌", "👏", "⭐️", "🏆", "🥳", "💥", "🎯", "✅", "🍾", "🦄",
        "🌈", "🧠", "⚡️", "🎸", "🫡", "🏁", "🤩", "💫", "🥇", "🧨", "🎊", "😎", "🍀", "🙏", "🐙",
    ]

    public private(set) var last: String?

    public init() {}

    /// The next emoji, drawn from `all` without repeating `last`.
    public mutating func next() -> String {
        var generator = SystemRandomNumberGenerator()
        return next(using: &generator)
    }

    public mutating func next(using generator: inout some RandomNumberGenerator) -> String {
        let candidates = Self.all.filter { $0 != last }
        let picked = candidates.randomElement(using: &generator) ?? "🎉"
        last = picked
        return picked
    }
}
