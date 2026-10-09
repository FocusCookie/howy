import Foundation

/// Turning lines into Markdown checklist items and ticking them: ⇧⌘L on the lines the selection
/// touches, or a click on one box. Ranges are UTF-16 (`NSRange`), so they apply directly to an
/// `NSTextView`.
///
/// ⇧⌘L never removes a box. Per line: text → `- [ ] text`, `- text` → `- [ ] text` (any marker,
/// `1. text` → `1. [ ] text`), `- [ ]` → `- [x]`, `- [x]`/`- [X]` → `- [ ]`. Over several lines:
/// all ticked → untick all; no box anywhere → every line gets an unticked box; otherwise every
/// line ends up ticked. Blank lines and fenced code are skipped; a caret on a blank line starts
/// a new `- [ ] ` item there.
public enum MarkdownTaskToggle {
    /// One contiguous replacement (a single undo step) and the selection to set afterwards.
    public struct Edit: Equatable, Sendable {
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

    /// ⇧⌘L: toggles the checklist state of every line the selection touches (a selection ending
    /// right at a line start leaves that line out). Nil when there's nothing to change.
    public static func toggle(in text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= ns.length else { return nil }
        let block = ns.lineRange(for: selection)
        let touched = MarkdownHighlighter.lines(of: text).filter { line in
            NSLocationInRange(line.range.location, block)
        }
        // lines(of:) has no entry for the empty line after a final line break (or an empty text).
        let lines: [MarkdownHighlighter.Line] = touched.isEmpty
            ? [.init(range: NSRange(location: block.location, length: 0), text: "", fence: nil, isCode: false)]
            : touched

        var items: [(line: MarkdownHighlighter.Line, item: Item)] = []
        for line in lines where !line.isCode {
            if let item = Item(line.text) { items.append((line, item)) }
        }

        var changes: [Change] = []
        if items.isEmpty {
            // A caret (or whitespace selection) on one blank line starts a new item there.
            guard lines.count == 1, let line = lines.first, !line.isCode else { return nil }
            changes = [Change(location: NSMaxRange(line.range), length: 0, replacement: "- [ ] ")]
            let edit = makeEdit(ns, changes, selection: selection)
            let caret = NSMaxRange(line.range) + 6
            return Edit(range: edit.range, replacement: edit.replacement, selection: NSRange(location: caret, length: 0))
        }

        let allTicked = items.allSatisfy { $0.item.box == true }
        let noBoxes = items.allSatisfy { $0.item.box == nil }
        let target: Target = allTicked || noBoxes ? .unchecked : .checked
        for (line, item) in items {
            if let change = item.change(to: target, lineStart: line.range.location) {
                changes.append(change)
            }
        }
        guard !changes.isEmpty else { return nil }
        return makeEdit(ns, changes, selection: selection)
    }

    /// A click on a box: flips only that box ("[ ]" ↔ "[x]"). `boxRange` must be one of
    /// `MarkdownHighlighter.taskBoxes(in:)`, otherwise nil. The text length doesn't change, so
    /// the caller can keep its own selection; `selection` is a caret just after the box.
    public static func toggleBox(in text: String, at boxRange: NSRange) -> Edit? {
        guard let box = MarkdownHighlighter.taskBoxes(in: text).first(where: { $0.range == boxRange }) else { return nil }
        return Edit(
            range: box.range,
            replacement: box.isChecked ? "[ ]" : "[x]",
            selection: NSRange(location: NSMaxRange(box.range), length: 0)
        )
    }

    // MARK: Lines

    private enum Target { case unchecked, checked }

    /// A replacement at a UTF-16 location of the original text.
    private struct Change {
        let location: Int
        let length: Int
        let replacement: String
    }

    /// A non-blank line: where a list marker (if any) ends, and its box state.
    private struct Item {
        /// End of the indentation, where a new marker goes.
        let indentEnd: Int
        /// End of the marker and its spacing, or nil for plain text.
        let markerEnd: Int?
        /// Location of the character inside the box ("[ ]" → " ").
        let checkLocation: Int?
        /// nil: no box; false: unticked; true: ticked.
        let box: Bool?

        // indent, marker + spacing, optional box (followed by spacing or the line's end)
        nonisolated(unsafe) private static let pattern = /^([ \t]*)(?:(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[([ xX])\](?=[ \t]|$))?)?/

        init?(_ line: String) {
            guard !line.allSatisfy({ $0 == " " || $0 == "\t" }),
                  let match = line.prefixMatch(of: Self.pattern) else { return nil }
            let (whole, indent, check) = match.output
            indentEnd = indent.utf16.count
            let wholeEnd = whole.utf16.count
            markerEnd = wholeEnd > indentEnd ? wholeEnd : nil
            if let check {
                // The check character sits one before the closing bracket at the match's end.
                checkLocation = wholeEnd - 2
                box = check != " "
            } else {
                checkLocation = nil
                box = nil
            }
        }

        func change(to target: Target, lineStart: Int) -> Change? {
            let mark = target == .checked ? "x" : " "
            if let checkLocation, let box {
                guard box != (target == .checked) else { return nil }
                return Change(location: lineStart + checkLocation, length: 1, replacement: mark)
            }
            if let markerEnd {
                return Change(location: lineStart + markerEnd, length: 0, replacement: "[\(mark)] ")
            }
            return Change(location: lineStart + indentEnd, length: 0, replacement: "- [\(mark)] ")
        }
    }

    // MARK: Edit

    /// Folds sorted, non-overlapping changes into one replacement and maps the selection: a caret
    /// moves past text inserted at it (it stays on the same text); a range keeps covering its lines.
    private static func makeEdit(_ ns: NSString, _ changes: [Change], selection: NSRange) -> Edit {
        let first = changes[0].location
        let last = changes.map { $0.location + $0.length }.max() ?? first
        let range = NSRange(location: first, length: last - first)

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
            for change in changes where change.location < position || (includingInsertsAt && change.location == position) {
                shift += (change.replacement as NSString).length - change.length
            }
            return position + shift
        }
        let start = map(selection.location, includingInsertsAt: selection.length == 0)
        let end = selection.length == 0 ? start : map(NSMaxRange(selection), includingInsertsAt: true)
        return Edit(range: range, replacement: replacement, selection: NSRange(location: start, length: end - start))
    }
}
