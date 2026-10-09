import Foundation

/// A styled range in Markdown source, for live highlighting in an editor. Ranges are UTF-16
/// (`NSRange`), so they apply directly to an `NSTextStorage`.
public struct MarkdownStyleSpan: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        /// A whole heading line, marker included.
        case heading(level: Int)
        case bold
        case italic
        case strikethrough
        /// Inline code, backticks included.
        case inlineCode
        /// A fenced code block, fences included.
        case codeBlock
        /// A whole quote line, marker included.
        case quote
        /// The `>` of a quote line (styled as a bar).
        case quoteMarker
        /// A list bullet or number ("-", "1.").
        case listMarker
        /// A task box, brackets included ("[ ]", "[x]"); dimmed like a list marker.
        case taskBox
        /// The "x" inside a ticked task box.
        case taskCheck
        /// The text of a ticked task item, after its box (struck through and greyed).
        case taskDone
        /// Link text, or a bare URL.
        case link
        /// Markup characters that stay in the text but should be dimmed (`**`, `#`, `](url)` ...).
        case syntax
    }

    public let style: Style
    public let range: NSRange

    public init(_ style: Style, _ range: NSRange) {
        self.style = style
        self.range = range
    }
}

/// Finds Markdown styling in source text, keeping every character in place (Bear/Typora-style
/// editing): blocks per line (headings, quotes, list markers, task boxes, fenced code), then inline
/// styles (code, bold, italic, strikethrough, links, bare URLs) outside code.
///
/// Spans may overlap (e.g. italic inside bold inside a heading); apply them in order.
public enum MarkdownHighlighter {
    /// A task box ("[ ]" or "[x]") in a list item, for hit-testing clicks.
    public struct TaskBox: Equatable, Sendable {
        /// The three box characters, brackets included.
        public let range: NSRange
        /// Ticked with "x" or "X".
        public let isChecked: Bool

        public init(range: NSRange, isChecked: Bool) {
            self.range = range
            self.isChecked = isChecked
        }
    }

    public static func spans(in text: String) -> [MarkdownStyleSpan] {
        var links: [NoteLink] = []
        return spans(in: text, links: &links)
    }

    /// Every Markdown link and bare URL outside code, in text order (`NoteLinks`). Found by the
    /// same pass as the `.link` spans, so a link is styled exactly where it is one.
    static func links(in text: String) -> [NoteLink] {
        var links: [NoteLink] = []
        _ = spans(in: text, links: &links)
        return links.sorted { $0.range.location < $1.range.location }
    }

    private static func spans(in text: String, links: inout [NoteLink]) -> [MarkdownStyleSpan] {
        var spans: [MarkdownStyleSpan] = []
        var fenceStart: Int?
        for line in lines(of: text) {
            if let fence = line.fence {
                if let start = fenceStart {
                    spans.append(.init(.codeBlock, NSRange(location: start, length: NSMaxRange(line.range) - start)))
                    spans.append(.init(.syntax, fence))
                    fenceStart = nil
                } else {
                    fenceStart = line.range.location
                    spans.append(.init(.syntax, fence))
                }
            } else if !line.isCode {
                spans += lineSpans(line.text, at: line.range.location, links: &links)
            }
        }
        if let start = fenceStart { // unclosed fence runs to the end
            spans.append(.init(.codeBlock, NSRange(location: start, length: (text as NSString).length - start)))
        }
        return spans
    }

    /// Every task box in list items outside fenced code, in text order.
    public static func taskBoxes(in text: String) -> [TaskBox] {
        lines(of: text).compactMap { line in
            guard !line.isCode, let task = taskItem(in: line.text) else { return nil }
            return TaskBox(range: NSRange(location: task.box.location + line.range.location, length: 3), isChecked: task.isChecked)
        }
    }

    // MARK: Source lines

    /// A line of source, without its line break.
    struct Line {
        let range: NSRange
        let text: String
        /// The fence ("```swift") when this line opens or closes a code block.
        let fence: NSRange?
        /// A fence line, or a line inside a fenced code block.
        let isCode: Bool
    }

    /// The text split into lines, with fenced code blocks marked (shared with `MarkdownTaskToggle`).
    static func lines(of text: String) -> [Line] {
        let ns = text as NSString
        var lines: [Line] = []
        var inFence = false
        var lineStart = 0
        while lineStart < ns.length {
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let range = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let lineText = ns.substring(with: range)
            if let fence = match(Pattern.fence, in: lineText) {
                lines.append(Line(range: range, text: lineText,
                                  fence: NSRange(location: range.location + fence.range.location, length: fence.range.length),
                                  isCode: true))
                inFence.toggle()
            } else {
                lines.append(Line(range: range, text: lineText, fence: nil, isCode: inFence))
            }
            lineStart = lineEnd
        }
        return lines
    }

    /// A list item with a task box: where the box sits in the line, whether it's ticked,
    /// and where the item text starts (after the box and its spacing).
    private static func taskItem(in line: String) -> (box: NSRange, isChecked: Bool, contentStart: Int)? {
        guard let task = match(Pattern.taskItem, in: line) else { return nil }
        let check = (line as NSString).substring(with: task.range(at: 3))
        return (task.range(at: 2), check != " ", task.range.length)
    }

    // MARK: Lines

    private static func lineSpans(_ line: String, at offset: Int, links: inout [NoteLink]) -> [MarkdownStyleSpan] {
        let ns = line as NSString
        var spans: [MarkdownStyleSpan] = []
        var contentStart = 0

        func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }

        if let heading = match(Pattern.heading, in: line) {
            let hashes = heading.range(at: 1)
            spans.append(.init(.heading(level: hashes.length), shifted(NSRange(location: 0, length: ns.length))))
            spans.append(.init(.syntax, shifted(NSRange(location: hashes.location, length: NSMaxRange(heading.range) - hashes.location))))
            contentStart = heading.range.length
        } else if let quote = match(Pattern.quote, in: line) {
            spans.append(.init(.quote, shifted(NSRange(location: 0, length: ns.length))))
            spans.append(.init(.quoteMarker, shifted(quote.range(at: 1))))
            contentStart = quote.range.length
        } else if let list = match(Pattern.listItem, in: line) {
            spans.append(.init(.listMarker, shifted(list.range(at: 1))))
            contentStart = list.range.length
            if let task = taskItem(in: line) {
                spans.append(.init(.taskBox, shifted(task.box)))
                if task.isChecked {
                    spans.append(.init(.taskCheck, shifted(NSRange(location: task.box.location + 1, length: 1))))
                    if task.contentStart < ns.length {
                        spans.append(.init(.taskDone, shifted(NSRange(location: task.contentStart, length: ns.length - task.contentStart))))
                    }
                }
                contentStart = task.contentStart
            }
        }

        let content = NSRange(location: contentStart, length: ns.length - contentStart)
        var inlineLinks: [NoteLink] = []
        spans += inlineSpans(ns.substring(with: content), links: &inlineLinks).map {
            MarkdownStyleSpan($0.style, NSRange(location: $0.range.location + content.location + offset, length: $0.range.length))
        }
        links += inlineLinks.map {
            NoteLink(range: NSRange(location: $0.range.location + content.location + offset, length: $0.range.length),
                     title: $0.title, url: $0.url, isBare: $0.isBare)
        }
        return spans
    }

    // MARK: Inline

    /// `links` gets the links found, with ranges in `text`.
    private static func inlineSpans(_ text: String, links: inout [NoteLink]) -> [MarkdownStyleSpan] {
        guard !text.isEmpty else { return [] }
        var spans: [MarkdownStyleSpan] = []
        // Matched markup is blanked out in this working copy (same UTF-16 length), so later
        // patterns don't see it: nothing is styled inside code, and `**` isn't read as two `*`.
        let work = NSMutableString(string: text)

        func blank(_ range: NSRange) {
            work.replaceCharacters(in: range, with: String(repeating: "\u{1}", count: range.length))
        }

        func delimited(_ pattern: NSRegularExpression, _ style: MarkdownStyleSpan.Style, delimiter: Int, blankAll: Bool) {
            for m in pattern.matches(in: work as String, range: NSRange(location: 0, length: work.length)) {
                let whole = m.range
                let open = NSRange(location: whole.location, length: delimiter)
                let close = NSRange(location: NSMaxRange(whole) - delimiter, length: delimiter)
                spans.append(.init(style, whole))
                spans.append(.init(.syntax, open))
                spans.append(.init(.syntax, close))
                if blankAll { blank(whole) } else { blank(open); blank(close) }
            }
        }

        delimited(Pattern.inlineCode, .inlineCode, delimiter: 1, blankAll: true)

        // Images first (an attachment reference): `![` and `](target)` dimmed, the alt text like a link.
        for m in Pattern.image.matches(in: work as String, range: NSRange(location: 0, length: work.length)) {
            let alt = m.range(at: 1)
            spans.append(.init(.syntax, NSRange(location: m.range.location, length: 2)))
            if alt.length > 0 { spans.append(.init(.link, alt)) }
            spans.append(.init(.syntax, NSRange(location: NSMaxRange(alt), length: NSMaxRange(m.range) - NSMaxRange(alt))))
            blank(m.range)
        }
        for m in Pattern.link.matches(in: work as String, range: NSRange(location: 0, length: work.length)) {
            let label = m.range(at: 1)
            let source = text as NSString
            links.append(NoteLink(range: m.range, title: source.substring(with: label),
                                  url: source.substring(with: m.range(at: 2)), isBare: false))
            spans.append(.init(.link, label))
            spans.append(.init(.syntax, NSRange(location: m.range.location, length: 1)))
            spans.append(.init(.syntax, NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label))))
            blank(NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)))
            blank(NSRange(location: m.range.location, length: 1))
        }
        for m in Pattern.bareURL.matches(in: work as String, range: NSRange(location: 0, length: work.length)) {
            spans.append(.init(.link, m.range))
            let url = (text as NSString).substring(with: m.range)
            links.append(NoteLink(range: m.range, title: url, url: url, isBare: true))
            blank(m.range)
        }

        delimited(Pattern.boldStars, .bold, delimiter: 2, blankAll: false)
        delimited(Pattern.boldUnderscores, .bold, delimiter: 2, blankAll: false)
        delimited(Pattern.strike, .strikethrough, delimiter: 2, blankAll: false)
        delimited(Pattern.italicStar, .italic, delimiter: 1, blankAll: false)
        delimited(Pattern.italicUnderscore, .italic, delimiter: 1, blankAll: false)
        return spans
    }

    // MARK: Patterns

    private static func match(_ pattern: NSRegularExpression, in line: String) -> NSTextCheckingResult? {
        pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private enum Pattern {
        // Force-tried: these literals are fixed and covered by tests.
        static let fence = regex(#"^ {0,3}(```|~~~).*$"#)
        static let heading = regex(#"^ {0,3}(#{1,6})(?:[ \t]+|$)"#)
        static let quote = regex(#"^ {0,3}(>+) ?"#)
        static let listItem = regex(#"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+"#)
        // marker, box, box character; the box is followed by spacing or the line's end
        static let taskItem = regex(#"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+(\[([ xX])\])(?:[ \t]+|$)"#)
        static let inlineCode = regex(#"`[^`\n]+`"#)
        static let image = regex(#"!\[([^\]\n]*)\]\(([^)\s]+)\)"#)
        static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
        static let bareURL = regex(#"\bhttps?://[^\s<>()\u0001]+[^\s<>()\u0001.,;:!?'"]"#)
        static let boldStars = regex(#"\*\*(?=\S)(?:[^*\n]|\*(?!\*))+?(?<=\S)\*\*"#)
        static let boldUnderscores = regex(#"(?<![\w_])__(?=\S)[^\n]+?(?<=\S)__(?![\w_])"#)
        static let strike = regex(#"~~(?=\S)[^~\n]+?(?<=\S)~~"#)
        static let italicStar = regex(#"(?<![*\w])\*(?=[^\s*])[^*\n]*?(?<=[^\s*])\*(?![*\w])"#)
        static let italicUnderscore = regex(#"(?<![\w_])_(?=[^\s_])[^_\n]*?(?<=[^\s_])_(?![\w_])"#)

        private static func regex(_ pattern: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern)
        }
    }
}
