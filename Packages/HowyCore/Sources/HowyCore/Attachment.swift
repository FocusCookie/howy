import Foundation

/// A file attached to a todo. The bytes live in `AttachmentStore`; this is what drafts, edits and
/// the manifest carry. `name` is unique within its todo and is what the note references.
public struct TodoAttachment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    /// Previewed as a picture (thumbnail, `![…]` reference) rather than as a file icon.
    public var isImage: Bool { AttachmentNaming.isImage(name) }
}

/// File names for new attachments.
public enum AttachmentNaming {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp"]

    public static func isImage(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A pasted image has no name of its own: `attachment-N.<ext>`, N one above the highest
    /// `attachment-N` already in `existing` (1 when there is none).
    public static func pastedName(extension ext: String, existing: [String]) -> String {
        let numbers = existing.compactMap { name -> Int? in
            let base = (name as NSString).deletingPathExtension
            guard base.hasPrefix("attachment-") else { return nil }
            return Int(base.dropFirst("attachment-".count))
        }
        return "attachment-\((numbers.max() ?? 0) + 1).\(ext)"
    }

    /// `name`, or `name 2`, `name 3`, … (before the extension) when it is already taken.
    /// Path separators are replaced so the name is a single file name.
    public static func unique(_ name: String, existing: [String]) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.hasPrefix(".") { cleaned = "file" + cleaned }
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(cleaned.lowercased()) else { return cleaned }
        let base = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }
}

/// A Markdown reference to an attachment found in a note. `range` is UTF-16 (`NSRange`).
public struct AttachmentReferenceMatch: Hashable, Sendable {
    public let range: NSRange
    /// The attachment name the reference points to (percent-decoded).
    public let name: String
}

/// Markdown references from a note to its attachments: `![attachment-1](attachment-1.png)` for
/// images, `[report.pdf](report.pdf)` for other files. The target is the attachment's name,
/// percent-encoded so it has no whitespace or parentheses (the note stays plain Markdown).
public enum AttachmentReference {
    public static func markdown(for attachment: TodoAttachment) -> String {
        let target = encode(attachment.name)
        let label = { (text: String) in text.filter { $0 != "[" && $0 != "]" && $0 != "\n" } }
        if attachment.isImage {
            return "![\(label((attachment.name as NSString).deletingPathExtension))](\(target))"
        }
        return "[\(label(attachment.name))](\(target))"
    }

    /// Every link or image reference in `note` whose target names one of `names`
    /// (all links when `names` is nil), in order.
    public static func matches(in note: String, names: Set<String>? = nil) -> [AttachmentReferenceMatch] {
        let ns = note as NSString
        return pattern.matches(in: note, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let target = ns.substring(with: m.range(at: 1))
            let name = target.removingPercentEncoding ?? target
            if let names, !names.contains(name) { return nil }
            return AttachmentReferenceMatch(range: m.range, name: name)
        }
    }

    /// The attachment name referenced at a caret position (UTF-16 offset), ends included.
    public static func name(at offset: Int, in note: String, names: Set<String>) -> String? {
        matches(in: note, names: names).first { offset >= $0.range.location && offset <= NSMaxRange($0.range) }?.name
    }

    /// `note` without its references to `name`. A line left blank by that loses its line break too.
    public static func removing(name: String, from note: String) -> String {
        let result = NSMutableString(string: note)
        for match in matches(in: note, names: [name]).reversed() {
            let line = result.lineRange(for: match.range)
            let lineText = result.substring(with: line)
            let rest = (lineText as NSString).replacingCharacters(
                in: NSRange(location: match.range.location - line.location, length: match.range.length), with: ""
            )
            if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Drop the whole line; at the very end also the line break before it.
                var drop = line
                if NSMaxRange(line) == result.length, !lineText.hasSuffix("\n"), line.location > 0 {
                    drop = NSRange(location: line.location - 1, length: line.length + 1)
                }
                result.replaceCharacters(in: drop, with: "")
            } else {
                result.replaceCharacters(in: match.range, with: "")
            }
        }
        return result as String
    }

    static func encode(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()[]<> ")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(pattern: #"!?\[[^\]\n]*\]\(([^)\s]+)\)"#)
}

/// How an attachment opens on click / Space / ↩ (Settings). ⌥ opens it the other way.
public enum AttachmentOpenMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// The system Quick Look panel above Howy's panel.
    case quickLook
    /// The file's default app (Preview for images and PDFs).
    case defaultApp

    public static let defaultsKey = "attachmentOpenMode"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quickLook: "Quick Look"
        case .defaultApp: "Default App"
        }
    }

    /// The other mode (⌥-click, ⌥↩).
    public var other: AttachmentOpenMode { self == .quickLook ? .defaultApp : .quickLook }

    public static func load(from defaults: UserDefaults = .standard) -> AttachmentOpenMode {
        defaults.string(forKey: defaultsKey).flatMap(AttachmentOpenMode.init(rawValue:)) ?? .quickLook
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
