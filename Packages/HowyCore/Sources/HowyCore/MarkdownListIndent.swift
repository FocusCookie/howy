import Foundation

/// Nesting Markdown list items: Tab indents the items the selection touches by one tab, Shift-Tab
/// takes one level away (a tab, or up to four spaces). Lines that aren't list items, and fenced
/// code, are left alone. Ranges are UTF-16 (`NSRange`), so they apply directly to an `NSTextView`.
///
/// Both return nil when there's nothing to change, so the key can do its usual job: Tab types a
/// tab, Shift-Tab goes back to the title.
public enum MarkdownListIndent {
    /// Tab: indents every list item the selection touches (a selection ending right at a line
    /// start leaves that line out). Nil when it touches no list item.
    public static func indent(in text: String, selection: NSRange) -> MarkdownTaskToggle.Edit? {
        let changes = items(in: text, selection: selection).map { line in
            Change(location: line.range.location, length: 0, replacement: "\t")
        }
        return makeEdit(text as NSString, changes, selection: selection)
    }

    /// Shift-Tab: takes one level from every indented list item the selection touches. Nil when
    /// none of them is indented.
    public static func outdent(in text: String, selection: NSRange) -> MarkdownTaskToggle.Edit? {
        let changes = items(in: text, selection: selection).compactMap { line -> Change? in
            let level: Int
            if line.text.hasPrefix("\t") {
                level = 1
            } else {
                level = line.text.prefix(4).prefix { $0 == " " }.count
            }
            guard level > 0 else { return nil }
            return Change(location: line.range.location, length: level, replacement: "")
        }
        return makeEdit(text as NSString, changes, selection: selection)
    }

    // indent, marker, then spacing or the line's end ("- " on its own is an empty item)
    nonisolated(unsafe) private static let item = /^[ \t]*(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)/

    /// The list items among the lines the selection touches, outside fenced code.
    private static func items(in text: String, selection: NSRange) -> [MarkdownHighlighter.Line] {
        let ns = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return [] }
        var touched = selection
        // A selection ending right at a line start doesn't take that line.
        if touched.length > 0, NSMaxRange(touched) > 0, ns.character(at: NSMaxRange(touched) - 1) == 0x0A {
            touched.length -= 1
        }
        let block = ns.lineRange(for: touched)
        return MarkdownHighlighter.lines(of: text).filter { line in
            !line.isCode && NSLocationInRange(line.range.location, block)
                && line.text.prefixMatch(of: item) != nil
        }
    }

    /// A replacement at a UTF-16 location of the original text.
    private struct Change {
        let location: Int
        let length: Int
        let replacement: String
    }

    /// Folds the line-start changes into one replacement (one undo step) and moves the selection
    /// with its text: a caret moves past an inserted tab; a range starting at a line start keeps
    /// covering its whole lines; a position inside removed indentation goes to where it was.
    private static func makeEdit(_ ns: NSString, _ changes: [Change], selection: NSRange) -> MarkdownTaskToggle.Edit? {
        guard let first = changes.first?.location, let lastChange = changes.last else { return nil }
        let last = lastChange.location + lastChange.length
        var replacement = ""
        var cursor = first
        for change in changes {
            replacement += ns.substring(with: NSRange(location: cursor, length: change.location - cursor))
            replacement += change.replacement
            cursor = change.location + change.length
        }
        replacement += ns.substring(with: NSRange(location: cursor, length: last - cursor))

        func map(_ position: Int, includingInsertsAt: Bool) -> Int {
            var shift = 0
            for change in changes {
                if change.length > 0 { // removed indentation
                    shift -= min(change.length, max(0, position - change.location))
                } else if change.location < position || (includingInsertsAt && change.location == position) {
                    shift += (change.replacement as NSString).length
                }
            }
            return position + shift
        }
        let start = map(selection.location, includingInsertsAt: selection.length == 0)
        let end = selection.length == 0 ? start : map(NSMaxRange(selection), includingInsertsAt: true)
        return MarkdownTaskToggle.Edit(
            range: NSRange(location: first, length: last - first),
            replacement: replacement,
            selection: NSRange(location: start, length: end - start)
        )
    }
}
