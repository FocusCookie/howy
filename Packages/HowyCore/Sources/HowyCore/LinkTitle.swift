import Foundation

/// Looks up a web page's title, for the title field of a pasted link.
public protocol LinkTitleLookup: Sendable {
    /// The page's title, or nil when it can't be had (offline, not HTML, no title, too slow).
    func title(for url: URL) async -> String?
}

/// Reading a page title out of HTML.
public enum LinkTitle {
    /// The page's `<title>`, else its `og:title`; entities decoded and whitespace collapsed.
    /// Nil when there is neither or it is blank.
    public static func title(inHTML html: String) -> String? {
        clean(firstMatch(Pattern.title, in: html)) ?? clean(metaTitle(in: html))
    }

    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let title = decodeEntities(raw)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return title.isEmpty ? nil : title
    }

    private static func metaTitle(in html: String) -> String? {
        let ns = html as NSString
        for tag in Pattern.metaTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(with: tag.range)
            guard firstMatch(Pattern.ogTitleProperty, in: text) != nil else { continue }
            if let content = firstMatch(Pattern.content, in: text) { return content }
        }
        return nil
    }

    private static func firstMatch(_ pattern: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        // The first group that took part (alternatives each have their own), else the whole match.
        let group = (1..<match.numberOfRanges).map { match.range(at: $0) }.first { $0.location != NSNotFound }
        return ns.substring(with: group ?? match.range)
    }

    /// `&amp;` and friends, `&#39;` and `&#x27;`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in Pattern.entity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = ns.substring(with: match.range(at: 1))
            result += decode(entity: name) ?? ns.substring(with: match.range)
            last = NSMaxRange(match.range)
        }
        return result + ns.substring(from: last)
    }

    private static func decode(entity name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[name.lowercased()]
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "bull": "•",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™",
    ]

    private enum Pattern {
        // Force-tried: these literals are fixed and covered by tests.
        static let title = regex(#"<title[^>]*>([\s\S]*?)</title\s*>"#)
        static let metaTag = regex(#"<meta\b[^>]*>"#)
        static let ogTitleProperty = regex(#"(?:property|name)\s*=\s*["']og:title["']"#)
        static let content = regex(#"content\s*=\s*"([^"]*)"|content\s*=\s*'([^']*)'"#)
        static let entity = regex(#"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#)

        private static func regex(_ pattern: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }
}

/// Fetches the start of the page over the network and reads its title (`LinkTitle`). Gives up
/// after `timeout` seconds or `byteLimit` bytes, and on anything that isn't HTML.
public struct WebPageTitleLookup: LinkTitleLookup {
    private let timeout: TimeInterval
    private let byteLimit: Int

    public init(timeout: TimeInterval = 5, byteLimit: Int = 512 * 1024) {
        self.timeout = timeout
        self.byteLimit = byteLimit
    }

    public func title(for url: URL) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            if let type = response.mimeType, !type.contains("html") { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= byteLimit { break }
                // Stop once the title has been read (checked every 4 KB).
                if data.count % 4096 == 0, data.range(of: Data("</title>".utf8)) != nil
                    || data.range(of: Data("</TITLE>".utf8)) != nil { break }
            }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return LinkTitle.title(inHTML: html)
        } catch {
            return nil
        }
    }
}
