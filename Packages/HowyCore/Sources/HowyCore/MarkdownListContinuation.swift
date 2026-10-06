import Foundation

/// What Enter does inside a Markdown list: continue it with the next marker, or end it
/// when the current item is empty (like Bear, Notes and most Markdown editors).
public enum MarkdownListContinuation {
    public enum Action: Hashable, Sendable {
        /// Insert this text (a newline plus indentation and marker) instead of a plain newline.
        case insert(String)
        /// The item is empty: delete this many UTF-16 units before the caret (the marker) instead of inserting a newline.
        case removeMarker(length: Int)
    }

    // indent, bullet | number + delimiter, spacing, optional task box, content
    nonisolated(unsafe) private static let item = /^([ \t]*)(?:([-*+])|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?(.*)$/

    /// The action for Enter, given the current line's text from its start up to the caret,
    /// or nil for a plain newline.
    public static func action(forLineBeforeCaret line: String) -> Action? {
        guard let match = line.wholeMatch(of: item) else { return nil }
        let (_, indent, bullet, number, delimiter, spacing, task, content) = match.output
        if content.isEmpty {
            return .removeMarker(length: line.utf16.count)
        }
        let marker: String
        if let bullet {
            marker = String(bullet)
        } else if let number, let delimiter, let value = Int(number) {
            marker = "\(value + 1)\(delimiter)"
        } else {
            return nil
        }
        let box = task == nil ? "" : "[ ] "
        return .insert("\n\(indent)\(marker)\(spacing)\(box)")
    }
}
