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
/// editing): blocks per line (headings, quotes, list markers, fenced code), then inline styles
/// (code, bold, italic, strikethrough, links, bare URLs) outside code.
///
/// Spans may overlap (e.g. italic inside bold inside a heading); apply them in order.
public enum MarkdownHighlighter {
    public static func spans(in text: String) -> [MarkdownStyleSpan] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var spans: [MarkdownStyleSpan] = []
        var fenceStart: Int?

        var lineStart = 0
        while lineStart < ns.length {
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let line = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let lineText = ns.substring(with: line)

            if let fence = match(Pattern.fence, in: lineText) {
                let fenceText = NSRange(location: line.location + fence.range.location, length: fence.range.length)
                if let start = fenceStart {
                    spans.append(.init(.codeBlock, NSRange(location: start, length: NSMaxRange(line) - start)))
                    spans.append(.init(.syntax, fenceText))
                    fenceStart = nil
                } else {
                    fenceStart = line.location
                    spans.append(.init(.syntax, fenceText))
                }
            } else if fenceStart == nil {
                spans += lineSpans(lineText, at: line.location)
            }
            lineStart = lineEnd
        }
        if let start = fenceStart { // unclosed fence runs to the end
            spans.append(.init(.codeBlock, NSRange(location: start, length: ns.length - start)))
        }
        return spans
    }

    // MARK: Lines

    private static func lineSpans(_ line: String, at offset: Int) -> [MarkdownStyleSpan] {
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
        }

        let content = NSRange(location: contentStart, length: ns.length - contentStart)
        spans += inlineSpans(ns.substring(with: content)).map {
            MarkdownStyleSpan($0.style, NSRange(location: $0.range.location + content.location + offset, length: $0.range.length))
        }
        return spans
    }

    // MARK: Inline

    private static func inlineSpans(_ text: String) -> [MarkdownStyleSpan] {
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

        for m in Pattern.link.matches(in: work as String, range: NSRange(location: 0, length: work.length)) {
            let label = m.range(at: 1)
            spans.append(.init(.link, label))
            spans.append(.init(.syntax, NSRange(location: m.range.location, length: 1)))
            spans.append(.init(.syntax, NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label))))
            blank(NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)))
            blank(NSRange(location: m.range.location, length: 1))
        }
        for m in Pattern.bareURL.matches(in: work as String, range: NSRange(location: 0, length: work.length)) {
            spans.append(.init(.link, m.range))
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
        static let inlineCode = regex(#"`[^`\n]+`"#)
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
