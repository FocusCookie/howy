import Foundation

/// A reference from the note to one of the todo's attachments, shown as a chip with an icon and
/// its title: `![title](name)` (an image, `kind == .image`) or `[title](name)` (a file). `name` is
/// the attachment's name, percent-decoded. Ranges are UTF-16 (`NSRange`).
public struct AttachmentChip: Hashable, Sendable {
    /// The icon the chip shows: a photo for `![…](…)`, a paperclip for `[…](…)`.
    public enum Kind: Hashable, Sendable { case file, image }

    /// The whole reference, `!` and brackets included.
    public let range: NSRange
    /// The text in the brackets (may be empty for an image).
    public let title: String
    /// The attachment it points to (`TodoAttachment.name`).
    public let name: String
    /// Written as an image reference `![…](…)`.
    public let isImage: Bool

    public init(range: NSRange, title: String, name: String, isImage: Bool) {
        self.range = range
        self.title = title
        self.name = name
        self.isImage = isImage
    }

    public var kind: Kind { isImage ? .image : .file }

    /// The title inside the brackets.
    public var titleRange: NSRange {
        NSRange(location: range.location + (isImage ? 2 : 1), length: (title as NSString).length)
    }
}

/// A chip in the note editor: a Markdown link (`NoteLink`, not a bare URL) or an attachment
/// reference (`AttachmentChip`). Both look alike apart from the icon and behave like one character.
public enum NoteChip: Hashable, Sendable {
    case link(NoteLink)
    case attachment(AttachmentChip)

    public var range: NSRange {
        switch self {
        case .link(let link): link.range
        case .attachment(let chip): chip.range
        }
    }

    public var title: String {
        switch self {
        case .link(let link): link.title
        case .attachment(let chip): chip.title
        }
    }

    public var titleRange: NSRange {
        switch self {
        case .link(let link): link.titleRange
        case .attachment(let chip): chip.titleRange
        }
    }

    public var link: NoteLink? {
        if case .link(let link) = self { link } else { nil }
    }

    public var attachment: AttachmentChip? {
        if case .attachment(let chip) = self { chip } else { nil }
    }
}

/// Every chip in a note, links and attachment references together, as one character each: the
/// caret never stops inside a chip (`snap`), the first ⌫ (or ⌦) next to one selects it and the
/// next deletes it (`deleteBackward` / `deleteForward`; for an attachment chip only the reference
/// goes, the attachment stays), and an edit that would cut into one takes all of it (`widen`).
///
/// A reference is an attachment chip when its target is the name of one of the todo's attachments
/// (`attachmentNames`), else `[…](…)` stays a link chip and `![…](…)` no chip at all. Chips inside
/// code are none. With no names these are exactly the link chips (`NoteLinks`).
public enum NoteChips {
    /// Every chip outside code, in text order.
    public static func chips(in text: String, attachmentNames: Set<String>) -> [NoteChip] {
        MarkdownHighlighter.references(in: text).compactMap { reference in
            guard !reference.isBare else { return nil }
            let name = reference.url.removingPercentEncoding ?? reference.url
            if attachmentNames.contains(name) {
                return .attachment(AttachmentChip(range: reference.range, title: reference.title, name: name, isImage: reference.isImage))
            }
            return reference.isImage ? nil : .link(reference)
        }
    }

    /// The attachment chips alone, in text order (e.g. to highlight those of one attachment).
    public static func attachments(in text: String, attachmentNames: Set<String>) -> [AttachmentChip] {
        chips(in: text, attachmentNames: attachmentNames).compactMap(\.attachment)
    }

    /// The chip the caret touches (either edge counts) or the selection lies in. A caret between
    /// two chips belongs to the one before it, the one it just passed.
    public static func chip(at selection: NSRange, in chips: [NoteChip]) -> NoteChip? {
        item(at: selection, in: chips, range: \.range)
    }

    static func item<Item>(at selection: NSRange, in items: [Item], range: (Item) -> NSRange) -> Item? {
        let hits = items.filter { selection.location >= range($0).location && NSMaxRange(selection) <= NSMaxRange(range($0)) }
        return hits.first { NSMaxRange(range($0)) == selection.location && selection.length == 0 }
            ?? hits.first { selection.location > range($0).location && NSMaxRange(selection) < NSMaxRange(range($0)) }
            ?? hits.first
    }

    // MARK: One character

    /// The selection the editor should take instead of `proposed` (coming from `old`), so that
    /// neither end stops inside a chip: an end moving forward goes to the chip's end, one moving
    /// back to its start (so arrows step over a chip and a selection grows or shrinks by whole chips).
    public static func snap(_ proposed: NSRange, from old: NSRange, in text: String, attachmentNames: Set<String>) -> NSRange {
        let ranges = chips(in: text, attachmentNames: attachmentNames).map(\.range)
        guard !ranges.isEmpty else { return proposed }
        func snapped(_ position: Int, forward: Bool) -> Int {
            guard let chip = ranges.first(where: { position > $0.location && position < NSMaxRange($0) }) else {
                return position
            }
            return forward ? NSMaxRange(chip) : chip.location
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
    public static func deleteBackward(in text: String, selection: NSRange, attachmentNames: Set<String>) -> NSRange? {
        guard selection.length == 0 else { return nil }
        return chips(in: text, attachmentNames: attachmentNames).first { NSMaxRange($0.range) == selection.location }?.range
    }

    /// ⌦ with the caret right before a chip selects the chip (the next ⌦ deletes it). Nil otherwise.
    public static func deleteForward(in text: String, selection: NSRange, attachmentNames: Set<String>) -> NSRange? {
        guard selection.length == 0 else { return nil }
        return chips(in: text, attachmentNames: attachmentNames).first { $0.range.location == selection.location }?.range
    }

    /// The range an edit of `range` should replace so that no chip is left cut in half: a chip it
    /// overlaps only partly is taken whole (a caret inside one widens to the whole chip).
    public static func widen(_ range: NSRange, in text: String, attachmentNames: Set<String>) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        for chip in chips(in: text, attachmentNames: attachmentNames) {
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
}

/// Edits that put attachment references into the note, change their title or take them out, each
/// a `NoteLinks.Edit` (one undo step, the caret after the chip). The Markdown format is the one
/// `AttachmentReference` reads: `![title](name)` for images, `[title](name)` for other files.
///
/// A reference goes in inline: at the caret (or over the selection), with a space before it when
/// it would follow a non-space character. Several go in on one line, separated by spaces, each with
/// its default title. A one-line selection can become the title (`insert(_:titledBySelection:…)`).
/// A title is never empty: a blank one falls back to the default, the name without its extension.
public enum NoteAttachments {
    /// The name without its extension ("report.pdf" → "report"); the whole name when that is empty.
    public static func defaultTitle(for name: String) -> String {
        let base = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? name : base
    }

    /// The reference for `attachment` with `title` (cleaned up; blank or nil: the default title).
    public static func markdown(for attachment: TodoAttachment, title: String?) -> String {
        markdown(name: attachment.name, title: title, isImage: attachment.isImage)
    }

    /// Inserts one reference over `range` (a caret or the selection), the caret after it.
    public static func insert(_ attachment: TodoAttachment, title: String?, replacing range: NSRange, in text: String) -> NoteLinks.Edit {
        insert([markdown(for: attachment, title: title)], replacing: range, in: text)
    }

    /// Inserts references with their default titles over `range`, on one line, separated by spaces.
    public static func insert(_ attachments: [TodoAttachment], replacing range: NSRange, in text: String) -> NoteLinks.Edit {
        insert(attachments.map { markdown(for: $0, title: nil) }, replacing: range, in: text)
    }

    /// A file pasted (or inserted with **I**) over selected text on one line: that text becomes
    /// the title and the reference replaces it. Nil when there's no selection, it spans lines or
    /// is blank, or it overlaps a chip.
    public static func insert(
        _ attachment: TodoAttachment, titledBySelection selection: NSRange, in text: String, attachmentNames: Set<String>
    ) -> NoteLinks.Edit? {
        guard let title = selectionTitle(selection, in: text, attachmentNames: attachmentNames) else { return nil }
        let reference = markdown(for: attachment, title: title)
        return NoteLinks.Edit(range: selection, replacement: reference,
                              selection: NSRange(location: selection.location + (reference as NSString).length, length: 0))
    }

    /// The selected text when it can be a title: on one line, not blank, not overlapping a chip.
    static func selectionTitle(_ selection: NSRange, in text: String, attachmentNames: Set<String>) -> String? {
        guard selection.length > 0, NSMaxRange(selection) <= (text as NSString).length else { return nil }
        let selected = (text as NSString).substring(with: selection)
        guard !selected.contains(where: \.isNewline),
              !selected.trimmingCharacters(in: .whitespaces).isEmpty,
              !NoteChips.chips(in: text, attachmentNames: attachmentNames)
                  .contains(where: { NSIntersectionRange($0.range, selection).length > 0 }) else { return nil }
        return selected
    }

    /// The same reference with a new title (blank: the default); the name and the kind stay.
    public static func retitle(_ chip: AttachmentChip, title: String) -> NoteLinks.Edit {
        let reference = markdown(name: chip.name, title: title, isImage: chip.isImage)
        return NoteLinks.Edit(range: chip.range, replacement: reference,
                              selection: NSRange(location: chip.range.location + (reference as NSString).length, length: 0))
    }

    /// Takes the reference out (the attachment stays), with one space beside it so no double space
    /// or leading space is left; the caret where it was.
    public static func remove(_ chip: AttachmentChip, in text: String) -> NoteLinks.Edit {
        let ns = text as NSString
        var range = chip.range
        let before = range.location > 0 ? ns.character(at: range.location - 1) : nil
        let after = NSMaxRange(range) < ns.length ? ns.character(at: NSMaxRange(range)) : nil
        if before == space, after.map(isWhitespace) ?? true {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        } else if after == space, before.map({ $0 == newline }) ?? true {
            range.length += 1
        }
        return NoteLinks.Edit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0))
    }

    /// No other chip in the note points to `chip`'s attachment.
    public static func isLastReference(_ chip: AttachmentChip, in text: String, attachmentNames: Set<String>) -> Bool {
        !NoteChips.attachments(in: text, attachmentNames: attachmentNames).contains { $0.name == chip.name && $0.range != chip.range }
    }

    // MARK: Helpers

    private static let space: unichar = 0x20
    private static let newline: unichar = 0x0A

    private static func isWhitespace(_ character: unichar) -> Bool {
        Unicode.Scalar(character).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
    }

    static func markdown(name: String, title: String?, isImage: Bool) -> String {
        func clean(_ text: String) -> String {
            text.components(separatedBy: .newlines).joined(separator: " ")
                .replacingOccurrences(of: "[", with: "(")
                .replacingOccurrences(of: "]", with: ")")
                .trimmingCharacters(in: .whitespaces)
        }
        var label = clean(title ?? "")
        if label.isEmpty { label = clean(defaultTitle(for: name)) }
        if label.isEmpty { label = "file" }
        let target = AttachmentReference.encode(name)
        return isImage ? "![\(label)](\(target))" : "[\(label)](\(target))"
    }

    /// `references` over `range`, separated by spaces, with a space before them after a non-space.
    private static func insert(_ references: [String], replacing range: NSRange, in text: String) -> NoteLinks.Edit {
        let ns = text as NSString
        var insertion = references.joined(separator: " ")
        if range.location > 0, range.location <= ns.length, !isWhitespace(ns.character(at: range.location - 1)) {
            insertion = " " + insertion
        }
        return NoteLinks.Edit(range: range, replacement: insertion,
                              selection: NSRange(location: range.location + (insertion as NSString).length, length: 0))
    }
}
