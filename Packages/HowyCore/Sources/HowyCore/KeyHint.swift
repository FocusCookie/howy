/// Splits a footer hint such as "⌘↩ save · ⌥↩ files · esc close" into the keys to draw as keycaps
/// and the words between them, so every panel renders its hints the same way.
///
/// Items are separated by " · ". Within an item the first word is a key; so is any later word that
/// starts with a modifier symbol ("⌘K") or is a number range ("1–4"). Everything else is label text.
/// A key's leading modifiers (⌘ ⌥ ⇧ ⌃) each become their own cap and the remainder one cap, so "⌘↩"
/// is [⌘][↩] while "←↑↓→", "esc" and "space" stay one cap each.
public enum KeyHint {
    public enum Part: Equatable, Sendable {
        case key(String)
        case text(String)
    }

    public static let separator = " · "
    static let modifiers: Set<Character> = ["⌘", "⌥", "⇧", "⌃"]

    public static func items(in hint: String) -> [[Part]] {
        hint.components(separatedBy: separator).compactMap { item in
            var parts: [Part] = []
            for (index, word) in item.split(separator: " ").map(String.init).enumerated() {
                if index == 0 || isKey(word) {
                    parts += caps(word).map(Part.key)
                } else if case .text(let previous)? = parts.last {
                    parts[parts.count - 1] = .text(previous + " " + word)
                } else {
                    parts.append(.text(word))
                }
            }
            return parts.isEmpty ? nil : parts
        }
    }

    /// "⌘↩" → ["⌘", "↩"], "⇧⇥" → ["⇧", "⇥"], "esc" → ["esc"].
    public static func caps(_ key: String) -> [String] {
        let leading = key.prefix { modifiers.contains($0) }
        let rest = key.dropFirst(leading.count)
        return leading.map(String.init) + (rest.isEmpty ? [] : [String(rest)])
    }

    static func isKey(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        if modifiers.contains(first) { return true }
        return word.contains("–") && word.allSatisfy { $0.isNumber || $0 == "–" }
    }
}
