import Foundation

/// A link in a note: a Markdown link `[title](url)` or a bare URL. Ranges are UTF-16 (`NSRange`).
public struct NoteLink: Hashable, Sendable {
    /// The whole link: `[title](url)`, or the bare URL.
    public let range: NSRange
    /// The link text (the URL itself for a bare one).
    public let title: String
    public let url: String
    /// A bare URL, typed or pasted without a title.
    public let isBare: Bool

    public init(range: NSRange, title: String, url: String, isBare: Bool) {
        self.range = range
        self.title = title
        self.url = url
        self.isBare = isBare
    }

    /// A Markdown link, which the note editor shows as a chip with just its title.
    public var isChip: Bool { !isBare }
    /// The link text inside the brackets (the whole range for a bare URL).
    public var titleRange: NSRange {
        isBare ? range : NSRange(location: range.location + 1, length: (title as NSString).length)
    }
}

/// Links in the note: a pasted URL gets a title (`[title](url)`), and the editor shows such a
/// link as a chip with only its title. The chip behaves like one character: the caret never
/// stops inside it (`snap`), the first ⌫ (or ⌦) next to it selects it and the next deletes it
/// (`deleteBackward` / `deleteForward`), and an edit that would cut into it takes all of it
/// (`widen`). Bare URLs stay as typed.
///
/// Pasting a URL (`pastedURL`) over selected text on one line links that text right away
/// (`linkSelection`); otherwise the caller asks for a title and `insert`s the link. A link under
/// the caret (`link(at:in:)`) can be edited (`replace`) or turned back into plain text (`unlink`).
public enum NoteLinks {
    /// One replacement (a single undo step) and the selection to set afterwards.
    public struct Edit: Hashable, Sendable {
        /// The range in the original text to replace.
        public let range: NSRange
        public let replacement: String
        /// The selection after applying the edit, in the resulting text.
        public let selection: NSRange

        public init(range: NSRange, replacement: String, selection: NSRange) {
            self.range = range
            self.replacement = replacement
            self.selection = selection
        }
    }

    /// Every link outside code, in text order (attachment references `![…](…)` are not links).
    public static func links(in text: String) -> [NoteLink] {
        MarkdownHighlighter.links(in: text)
    }

    /// The link the caret touches (either edge counts) or the selection lies in. A caret between
    /// two links belongs to the one before it, the one it just passed.
    public static func link(at selection: NSRange, in links: [NoteLink]) -> NoteLink? {
        let hits = links.filter { selection.location >= $0.range.location && NSMaxRange(selection) <= NSMaxRange($0.range) }
        return hits.first { NSMaxRange($0.range) == selection.location && selection.length == 0 }
            ?? hits.first { selection.location > $0.range.location && NSMaxRange(selection) < NSMaxRange($0.range) }
            ?? hits.first
    }

    // MARK: Chips as one character

    /// The selection the editor should take instead of `proposed` (coming from `old`), so that
    /// neither end stops inside a chip: an end moving forward goes to the chip's end, one moving
    /// back to its start (so arrows step over a chip and a selection grows or shrinks by whole chips).
    public static func snap(_ proposed: NSRange, from old: NSRange, in text: String) -> NSRange {
        let chips = links(in: text).filter(\.isChip)
        guard !chips.isEmpty else { return proposed }
        func snapped(_ position: Int, forward: Bool) -> Int {
            guard let chip = chips.first(where: { position > $0.range.location && position < NSMaxRange($0.range) }) else {
                return position
            }
            return forward ? NSMaxRange(chip.range) : chip.range.location
        }
        let start = proposed.location, end = NSMaxRange(proposed)
        if proposed.length == 0 {
            let caret = snapped(start, forward: start >= old.location)
            return NSRange(location: caret, length: 0)
        }
        // A changed end snaps in the direction it moved; an unchanged one (or a new selection) outward.
        let newStart = snapped(start, forward: start != old.location && start > old.location)
        let newEnd = snapped(end, forward: end == NSMaxRange(old) || end > NSMaxRange(old))
        return NSRange(location: newStart, length: max(newEnd - newStart, 0))
    }

    /// ⌫ with the caret right after a chip selects the chip (the next ⌫ deletes it). Nil otherwise.
    public static func deleteBackward(in text: String, selection: NSRange) -> NSRange? {
        guard selection.length == 0 else { return nil }
        return links(in: text).first { $0.isChip && NSMaxRange($0.range) == selection.location }?.range
    }

    /// ⌦ with the caret right before a chip selects the chip (the next ⌦ deletes it). Nil otherwise.
    public static func deleteForward(in text: String, selection: NSRange) -> NSRange? {
        guard selection.length == 0 else { return nil }
        return links(in: text).first { $0.isChip && $0.range.location == selection.location }?.range
    }

    /// The range an edit of `range` should replace so that no chip is left cut in half: a chip it
    /// overlaps only partly is taken whole.
    public static func widen(_ range: NSRange, in text: String) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        for chip in links(in: text) where chip.isChip {
            let chipStart = chip.range.location, chipEnd = NSMaxRange(chip.range)
            let cuts = range.length == 0
                ? start > chipStart && start < chipEnd
                : start < chipEnd && end > chipStart && (start > chipStart || end < chipEnd)
            if cuts {
                start = min(start, chipStart)
                end = max(end, chipEnd)
            }
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Pasting

    /// The URL when the pasted text is one web address (http or https) and nothing else.
    public static func pastedURL(_ pasted: String) -> String? {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty else { return nil }
        return trimmed
    }

    /// Pasting `url` over selected text links that text, no questions asked. Nil when there's no
    /// selection, it spans lines or is blank, or it overlaps a link.
    public static func linkSelection(url: String, in text: String, selection: NSRange) -> Edit? {
        guard selection.length > 0, NSMaxRange(selection) <= (text as NSString).length else { return nil }
        let selected = (text as NSString).substring(with: selection)
        guard !selected.contains(where: \.isNewline),
              !selected.trimmingCharacters(in: .whitespaces).isEmpty,
              !links(in: text).contains(where: { NSIntersectionRange($0.range, selection).length > 0 }) else { return nil }
        return insert(title: selected, url: url, replacing: selection)
    }

    /// Inserts a link over `range`, the caret after it. A blank title inserts the bare URL.
    public static func insert(title: String, url: String, replacing range: NSRange) -> Edit {
        let link = markdown(title: title, url: url)
        return Edit(range: range, replacement: link, selection: NSRange(location: range.location + (link as NSString).length, length: 0))
    }

    // MARK: Editing

    /// Replaces a link with a new title and URL, the caret after it. A blank title leaves the bare URL.
    public static func replace(_ link: NoteLink, title: String, url: String) -> Edit {
        insert(title: title, url: url, replacing: link.range)
    }

    /// Turns a link back into its title as plain text, the caret after it.
    public static func unlink(_ link: NoteLink) -> Edit {
        Edit(range: link.range, replacement: link.title,
             selection: NSRange(location: link.range.location + (link.title as NSString).length, length: 0))
    }

    /// `[title](url)`, or the bare URL when the title is blank. Square brackets and line breaks in
    /// the title, and spaces and parentheses in the URL, would end the link early, so they change.
    public static func markdown(title: String, url: String) -> String {
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        let cleanTitle = title
            .components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespaces)
        return cleanTitle.isEmpty ? cleanURL : "[\(cleanTitle)](\(cleanURL))"
    }

    /// The site's name for a title: the host without "www.", or the URL itself without one.
    public static func domain(of url: String) -> String {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
