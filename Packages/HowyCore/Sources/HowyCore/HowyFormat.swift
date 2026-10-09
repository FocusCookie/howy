import Foundation

/// Howy's import/export format: a folder with `howy.json` and `attachments/<todo id>/<name>`.
public enum HowyFormat {
    /// The `formatVersion` this build writes, and the newest it reads.
    public static let version = 1
    public static let fileName = "howy.json"
    public static let attachmentsFolderName = "attachments"

    /// Whether an attachment name is a single, plain file name. Anything with `/`, `\` or `..`
    /// (or an empty name) could point outside the attachments folder and is refused.
    public static func isSafeAttachmentName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name != "."
            && !name.contains("/") && !name.contains("\\") && !name.contains("..")
    }

    /// `<folder>/attachments/<todo id>/<name>`.
    static func attachmentURL(in folder: URL, todoID: UUID, name: String) -> URL {
        folder.appending(path: attachmentsFolderName, directoryHint: .isDirectory)
            .appending(path: todoID.uuidString, directoryHint: .isDirectory)
            .appending(path: name)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: Dates

    /// ISO 8601 in UTC, e.g. `2026-10-01T08:00:00Z`. A fractional second is written with up to
    /// nine digits (`…:00.25Z`), enough that reading it back gives the very same `Date`.
    static func string(from date: Date) -> String {
        let interval = date.timeIntervalSinceReferenceDate
        var whole = interval.rounded(.down)
        var nanoseconds = Int(((interval - whole) * 1e9).rounded())
        if nanoseconds >= 1_000_000_000 {
            whole += 1
            nanoseconds -= 1_000_000_000
        }
        let base = Date(timeIntervalSinceReferenceDate: whole).formatted(.iso8601)
        guard nanoseconds > 0 else { return base }
        var fraction = String(format: "%09d", nanoseconds)
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return "\(base.dropLast()).\(fraction)Z"
    }

    /// Reads an ISO 8601 date-time (`Z` or an offset, optional fractional seconds) or a plain
    /// date (`2026-10-01`, midnight UTC). `nil` for anything else.
    static func date(from string: String) -> Date? {
        var text = string.trimmingCharacters(in: .whitespaces)
        var fraction = 0.0
        if let t = text.firstIndex(of: "T"), let dot = text[t...].firstIndex(where: { $0 == "." || $0 == "," }) {
            let digitsStart = text.index(after: dot)
            let digitsEnd = text[digitsStart...].firstIndex(where: { !("0"..."9").contains($0) }) ?? text.endIndex
            guard digitsStart < digitsEnd, let value = Double("0.\(text[digitsStart..<digitsEnd])") else { return nil }
            fraction = value
            text.removeSubrange(dot..<digitsEnd)
        }
        if let whole = try? Date(text, strategy: .iso8601) {
            return Date(timeIntervalSinceReferenceDate: whole.timeIntervalSinceReferenceDate + fraction)
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day())
    }
}

extension Quadrant {
    /// The quadrant's name in `howy.json`.
    public var formatName: String {
        switch self {
        case .urgentImportant: "urgent-important"
        case .notUrgentImportant: "not-urgent-important"
        case .urgentUnimportant: "urgent-unimportant"
        case .notUrgentUnimportant: "not-urgent-unimportant"
        }
    }

    public init?(formatName: String) {
        guard let quadrant = Quadrant.allCases.first(where: { $0.formatName == formatName }) else { return nil }
        self = quadrant
    }
}

/// The contents of `howy.json` (format v1), as plain data.
///
/// Encoding writes the format. Decoding a whole file goes through `HowyExport.parse`, which
/// checks `formatVersion` and reads every todo on its own, so one bad entry doesn't sink the rest.
public struct HowyExport: Encodable, Sendable {
    public var formatVersion: Int
    public var appVersion: String?
    public var exportedAt: Date?
    public var todos: [Todo]

    public init(formatVersion: Int = HowyFormat.version, appVersion: String? = nil, exportedAt: Date? = nil, todos: [Todo]) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.todos = todos
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, appVersion, exportedAt, todos
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encodeIfPresent(exportedAt.map(HowyFormat.string(from:)), forKey: .exportedAt)
        try container.encode(todos, forKey: .todos)
    }

    /// One todo in `howy.json`.
    public struct Todo: Codable, Hashable, Sendable {
        public var record: TodoRecord
        public var attachments: [TodoAttachment]

        public init(record: TodoRecord, attachments: [TodoAttachment] = []) {
            self.record = record
            self.attachments = attachments
        }

        public var id: UUID { record.id }
        public var title: String { record.title }

        enum CodingKeys: String, CodingKey {
            case id, title, note, quadrant, createdAt, sortDate, completedAt, attachments
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(record.id, forKey: .id)
            try container.encode(record.title, forKey: .title)
            try container.encode(record.note, forKey: .note)
            try container.encode(record.quadrant.formatName, forKey: .quadrant)
            try container.encode(HowyFormat.string(from: record.createdAt), forKey: .createdAt)
            try container.encode(HowyFormat.string(from: record.sortDate), forKey: .sortDate)
            try container.encode(record.completedAt.map(HowyFormat.string(from:)), forKey: .completedAt) // null when open
            try container.encode(attachments, forKey: .attachments)
        }

        /// Reads one entry; throws an `EntryProblem` saying what's missing or wrong.
        public init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                throw EntryProblem("not a todo object")
            }
            let c = Fields(container: container)
            guard let idText = try c.string(.id) else { throw EntryProblem("missing id") }
            guard let id = UUID(uuidString: idText) else { throw EntryProblem("invalid id \"\(idText)\"") }
            guard let rawTitle = try c.string(.title) else { throw EntryProblem("missing title") }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw EntryProblem("empty title") }
            guard let quadrantName = try c.string(.quadrant) else { throw EntryProblem("missing quadrant") }
            guard let quadrant = Quadrant(formatName: quadrantName) else {
                throw EntryProblem("unknown quadrant \"\(quadrantName)\"")
            }
            guard let createdAt = try c.date(.createdAt) else { throw EntryProblem("missing createdAt") }
            record = TodoRecord(
                id: id, title: title, note: try c.string(.note) ?? "", quadrant: quadrant,
                createdAt: createdAt, sortDate: try c.date(.sortDate), completedAt: try c.date(.completedAt)
            )
            attachments = try c.attachments()
        }

        /// Typed reads that tell "missing" (`nil`) from "wrong" (an `EntryProblem`).
        private struct Fields {
            let container: KeyedDecodingContainer<CodingKeys>

            func isAbsent(_ key: CodingKeys) -> Bool {
                !container.contains(key) || ((try? container.decodeNil(forKey: key)) ?? false)
            }

            func string(_ key: CodingKeys) throws -> String? {
                guard !isAbsent(key) else { return nil }
                guard let value = try? container.decode(String.self, forKey: key) else {
                    throw EntryProblem("invalid \(key.stringValue)")
                }
                return value
            }

            func date(_ key: CodingKeys) throws -> Date? {
                guard let text = try string(key) else { return nil }
                guard let date = HowyFormat.date(from: text) else {
                    throw EntryProblem("invalid \(key.stringValue) \"\(text)\"")
                }
                return date
            }

            func attachments() throws -> [TodoAttachment] {
                guard !isAbsent(.attachments) else { return [] }
                struct Raw: Decodable {
                    var id: String?
                    var name: String?
                }
                guard let raws = try? container.decode([Raw].self, forKey: .attachments) else {
                    throw EntryProblem("invalid attachments")
                }
                return try raws.enumerated().map { index, raw in
                    let label = "attachment #\(index + 1)"
                    guard let idText = raw.id else { throw EntryProblem("\(label): missing id") }
                    guard let id = UUID(uuidString: idText) else { throw EntryProblem("\(label): invalid id \"\(idText)\"") }
                    guard let name = raw.name else { throw EntryProblem("\(label): missing name") }
                    return TodoAttachment(id: id, name: name)
                }
            }
        }
    }

    /// Why one todo entry can't be read, e.g. `missing title`.
    public struct EntryProblem: Error, Hashable, Sendable {
        public let message: String
        init(_ message: String) { self.message = message }
    }

    /// `howy.json` read leniently: the header must be right, each todo stands on its own.
    struct Parsed {
        var appVersion: String?
        var exportedAt: Date?
        /// One per entry in `todos`, in file order.
        var entries: [Result<Todo, EntryProblem>]
    }

    /// Reads `howy.json`. Throws when the file as a whole can't be imported (not JSON, no
    /// `todos` list, missing, unknown or newer `formatVersion`).
    static func parse(_ data: Data) throws(HowyImportError) -> Parsed {
        let file: LenientFile
        do {
            file = try JSONDecoder().decode(LenientFile.self, from: data)
        } catch {
            throw .unreadable("it isn't valid JSON")
        }
        switch file.formatVersion {
        case .missing: throw .missingFormatVersion
        case .other(let text): throw .unknownFormatVersion(text)
        case .number(let version) where version > HowyFormat.version: throw .newerFormatVersion(version)
        case .number(let version) where version < 1: throw .unknownFormatVersion(String(version))
        case .number: break
        }
        guard let todos = file.todos else { throw .unreadable("it has no todos list") }
        return Parsed(
            appVersion: file.appVersion,
            exportedAt: file.exportedAt.flatMap(HowyFormat.date(from:)),
            entries: todos.map(\.result)
        )
    }

    private struct LenientFile: Decodable {
        enum Version {
            case missing
            case number(Int)
            case other(String)
        }

        var formatVersion: Version
        var appVersion: String?
        var exportedAt: String?
        /// `nil` when the key is missing or isn't a list.
        var todos: [Entry]?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if !container.contains(.formatVersion) || ((try? container.decodeNil(forKey: .formatVersion)) ?? false) {
                formatVersion = .missing
            } else if let number = try? container.decode(Int.self, forKey: .formatVersion) {
                formatVersion = .number(number)
            } else if let text = try? container.decode(String.self, forKey: .formatVersion) {
                formatVersion = .other("\"\(text)\"")
            } else {
                formatVersion = .other("not a number")
            }
            appVersion = try? container.decodeIfPresent(String.self, forKey: .appVersion)
            exportedAt = try? container.decodeIfPresent(String.self, forKey: .exportedAt)
            todos = try? container.decodeIfPresent([Entry].self, forKey: .todos)
        }
    }

    /// One `todos` entry; reading it never fails, a bad entry becomes a `.failure`.
    private struct Entry: Decodable {
        var result: Result<Todo, EntryProblem>

        init(from decoder: any Decoder) {
            do {
                result = .success(try Todo(from: decoder))
            } catch let problem as EntryProblem {
                result = .failure(problem)
            } catch {
                result = .failure(EntryProblem("not a todo object"))
            }
        }
    }
}

/// Why a whole import was refused. Nothing is written in any of these cases.
public enum HowyImportError: Error, Equatable, Sendable, LocalizedError {
    /// The folder has no `howy.json`.
    case fileNotFound
    /// `howy.json` exists but can't be read or parsed; the text says why.
    case unreadable(String)
    case missingFormatVersion
    /// `formatVersion` isn't a version Howy knows (not a number, or below 1).
    case unknownFormatVersion(String)
    /// The file was written by a newer Howy.
    case newerFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            "The folder has no \(HowyFormat.fileName)."
        case .unreadable(let reason):
            "\(HowyFormat.fileName) can't be read: \(reason)."
        case .missingFormatVersion:
            "\(HowyFormat.fileName) has no formatVersion."
        case .unknownFormatVersion(let value):
            "\(HowyFormat.fileName) has an unknown formatVersion (\(value))."
        case .newerFormatVersion(let version):
            "\(HowyFormat.fileName) uses format version \(version), but this Howy reads up to version \(HowyFormat.version). Update Howy and try again."
        }
    }
}
