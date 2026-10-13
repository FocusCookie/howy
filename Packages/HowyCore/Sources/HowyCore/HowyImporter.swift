import Foundation

/// Counts and problems of an import: the preview before it (`ImportPlan.report`) and the
/// summary after it (`HowyImporter.apply`).
public struct ImportReport: Hashable, Sendable {
    /// Todos that will be imported (preview) or were imported (summary).
    public var importCount = 0
    /// Todos skipped because their id already exists, in Howy or earlier in the file.
    public var duplicateCount = 0
    /// Todos skipped because a required field is missing or wrong.
    public var invalidCount = 0
    /// Attachment files of imported todos that are (or were) copied in.
    public var attachmentCount = 0
    /// Attachments of imported todos left out: file not found, name refused, or copy failed.
    public var missingAttachmentCount = 0
    /// Imported done todos already older than the archive retention; the next purge removes them.
    public var expiredCount = 0
    /// History events that will be imported (preview) or were imported (summary): those whose
    /// id isn't in Howy yet, whether their todo is new or already exists.
    public var importedEventCount = 0
    /// History events skipped because their id already exists, in Howy or earlier in the file.
    public var skippedEventCount = 0
    /// History events skipped because `id`, `todoID`, `kind` or `date` is missing or wrong.
    /// (A wrong optional field only drops that field and adds a problem line.)
    public var invalidEventCount = 0
    /// One line per problem, naming the todo, e.g. `Entry #12: missing title`.
    public var problems: [String] = []

    /// Every todo entry in the file.
    public var totalCount: Int { importCount + duplicateCount + invalidCount }

    /// Every history event in the file.
    public var totalEventCount: Int { importedEventCount + skippedEventCount + invalidEventCount }

    /// Whether the import adds anything: a todo or a history event.
    public var hasChanges: Bool { importCount > 0 || importedEventCount > 0 }
}

/// The result of `HowyImporter.analyze`: what an import of `folder` would do. Nothing has been
/// written yet; pass it to `HowyImporter.apply`.
public struct ImportPlan: Sendable {
    public let folder: URL
    public let report: ImportReport
    /// The todos to import, with the attachments whose files were found.
    let todos: [HowyExport.Todo]
    /// The file's valid events (format v2); `TodoStore.insert` picks the ones to import.
    let events: [TodoEventRecord]
}

/// Imports an export folder (`howy.json` + `attachments/`), merging by id: todos whose id
/// already exists are skipped with their attachments, and existing todos never change.
///
/// History (format v2 `events`) comes in as written, for new and for already existing todos
/// alike; events whose id exists are skipped, so importing a file twice adds nothing. A todo
/// the file has no event for (any version 1 file) gets `created`/`completed` events made up
/// from its timestamps. An event with a wrong optional field keeps its id, kind and date and
/// drops the field (a problem line says so); an event with a wrong `id`, `todoID`, `kind` or
/// `date` is skipped. Events are counted separately (`importedEventCount`,
/// `skippedEventCount`, `invalidEventCount`), never in the todo numbers. A file of format
/// version 2 or later without `events` gets a problem line.
@MainActor
public struct HowyImporter {
    public let store: TodoStore
    /// Done todos older than this are imported anyway but counted in `expiredCount`.
    public let retention: ArchiveRetention

    public init(store: TodoStore, retention: ArchiveRetention = .default) {
        self.store = store
        self.retention = retention
    }

    // MARK: Analyze

    /// Reads and checks the folder and works out what an import would do. Writes nothing. The
    /// per-attachment file checks run off the main actor.
    /// Throws `HowyImportError` when the whole import is refused.
    public func analyze(folder: URL) async throws -> ImportPlan {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let json = folder.appending(path: HowyFormat.fileName)
        guard FileManager.default.fileExists(atPath: json.path(percentEncoded: false)) else { throw HowyImportError.fileNotFound }
        let data: Data
        do {
            data = try Data(contentsOf: json)
        } catch {
            throw HowyImportError.unreadable("the file can't be opened")
        }
        let parsed = try HowyExport.parse(data)

        let existing = try store.allIDs()
        var report = ImportReport()
        var todos: [HowyExport.Todo] = []
        var firstEntry: [UUID: Int] = [:]
        for (index, entry) in parsed.entries.enumerated() {
            let number = index + 1
            let todo: HowyExport.Todo
            switch entry {
            case .failure(let problem):
                report.invalidCount += 1
                report.problems.append("Entry #\(number): \(problem.message)")
                continue
            case .success(let value):
                todo = value
            }
            if let first = firstEntry[todo.id] {
                report.duplicateCount += 1
                report.problems.append("Entry #\(number): same id as entry #\(first)")
                continue
            }
            firstEntry[todo.id] = number
            if existing.contains(todo.id) {
                report.duplicateCount += 1
                continue
            }
            var accepted = todo
            if !todo.attachments.isEmpty {
                let checked = await Self.checkAttachments(of: todo, in: folder)
                accepted.attachments = checked.accepted
                report.missingAttachmentCount += checked.problems.count
                report.problems += checked.problems
            }
            report.importCount += 1
            report.attachmentCount += accepted.attachments.count
            if isExpired(accepted.record) { report.expiredCount += 1 }
            todos.append(accepted)
        }
        var events: [TodoEventRecord] = []
        var knownEvents = try store.allEventIDs()
        if parsed.events == nil, parsed.formatVersion >= 2 {
            report.problems.append("History: no history in this file")
        }
        for (index, entry) in (parsed.events ?? []).enumerated() {
            switch entry {
            case .success(let event):
                report.problems += event.warnings.map { "History entry #\(index + 1): \($0)" }
                events.append(event.record)
                if knownEvents.insert(event.record.id).inserted {
                    report.importedEventCount += 1
                } else {
                    report.skippedEventCount += 1
                }
            case .failure(let problem):
                report.invalidEventCount += 1
                report.problems.append("History entry #\(index + 1): \(problem.message)")
            }
        }
        return ImportPlan(folder: folder, report: report, todos: todos, events: events)
    }

    /// The attachments of `todo` that can be imported, and a line for each that can't.
    @concurrent
    nonisolated private static func checkAttachments(
        of todo: HowyExport.Todo, in folder: URL
    ) async -> (accepted: [TodoAttachment], problems: [String]) {
        var names = Set<String>()
        var ids = Set<UUID>()
        var accepted: [TodoAttachment] = []
        var problems: [String] = []
        for attachment in todo.attachments {
            let label = "\"\(todo.title)\": attachment"
            if !HowyFormat.isSafeAttachmentName(attachment.name) {
                problems.append("\(label) name \"\(attachment.name)\" is not allowed")
            } else if !names.insert(attachment.name.lowercased()).inserted {
                problems.append("\(label) \"\(attachment.name)\" is listed twice")
            } else if !ids.insert(attachment.id).inserted {
                problems.append("\(label) \"\(attachment.name)\" has the id of another attachment")
            } else if !isFile(HowyFormat.attachmentURL(in: folder, todoID: todo.id, name: attachment.name)) {
                problems.append("\(label) \"\(attachment.name)\" not found in folder")
            } else {
                accepted.append(attachment)
            }
        }
        return (accepted, problems)
    }

    nonisolated private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func isExpired(_ record: TodoRecord) -> Bool {
        guard let completedAt = record.completedAt else { return false }
        return completedAt < store.currentDate.addingTimeInterval(-retention.interval)
    }

    // MARK: Apply

    /// Imports the plan: copies the attachment files (off the main actor), then inserts every
    /// todo in one write, so widgets reload once. Todos that appeared since `analyze` are
    /// skipped as duplicates. Returns the summary.
    public func apply(_ plan: ImportPlan) async throws -> ImportReport {
        var report = plan.report
        report.importCount = 0
        report.attachmentCount = 0
        report.expiredCount = 0
        report.importedEventCount = 0

        let existing = try store.allIDs()
        let fresh = plan.todos.filter { !existing.contains($0.id) }
        report.duplicateCount += plan.todos.count - fresh.count

        var copy = AttachmentCopy(area: nil, copied: [:], problems: [])
        if let files = store.attachments, fresh.contains(where: { !$0.attachments.isEmpty }) {
            copy = try await Self.copyAttachments(of: fresh, from: plan.folder, into: files)
        } else if store.attachments == nil {
            copy.problems = fresh.flatMap { todo in
                todo.attachments.map { "\"\(todo.title)\": attachment \"\($0.name)\" could not be copied" }
            }
        }
        defer { if let area = copy.area { try? FileManager.default.removeItem(at: area) } }
        report.problems += copy.problems
        report.missingAttachmentCount += copy.problems.count

        // Back on the main actor: anything added during the copy is still a duplicate.
        let stillFresh = try store.allIDs()
        var records: [TodoRecord] = []
        var withFiles: [UUID] = []
        var committed: [UUID: [TodoAttachment]] = [:]
        for todo in fresh {
            guard !stillFresh.contains(todo.id) else {
                report.duplicateCount += 1
                continue
            }
            let attachments = copy.copied[todo.id] ?? []
            if let files = store.attachments, let area = copy.area, !attachments.isEmpty {
                do {
                    try files.commitImport(attachments, for: todo.id, from: area)
                    withFiles.append(todo.id)
                    committed[todo.id] = attachments
                    report.attachmentCount += attachments.count
                } catch {
                    files.removeAll(for: todo.id)
                    report.missingAttachmentCount += attachments.count
                    report.problems += attachments.map { "\"\(todo.title)\": attachment \"\($0.name)\" could not be copied" }
                }
            }
            records.append(todo.record)
            if isExpired(todo.record) { report.expiredCount += 1 }
        }
        do {
            let result = try store.insertReporting(records, events: plan.events, attachments: committed)
            report.importCount = result.todoIDs.count
            report.importedEventCount = result.eventCount
            report.skippedEventCount = plan.events.count - result.eventCount
        } catch {
            withFiles.forEach { store.attachments?.removeAll(for: $0) }
            throw error
        }
        return report
    }

    private struct AttachmentCopy: Sendable {
        var area: URL?
        /// Per todo, the attachments whose file made it into `area`.
        var copied: [UUID: [TodoAttachment]]
        var problems: [String]
    }

    @concurrent
    nonisolated private static func copyAttachments(
        of todos: [HowyExport.Todo], from folder: URL, into files: AttachmentStore
    ) async throws -> AttachmentCopy {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let area = try files.makeImportArea()
        var result = AttachmentCopy(area: area, copied: [:], problems: [])
        for todo in todos {
            for attachment in todo.attachments {
                do {
                    try files.copyForImport(
                        HowyFormat.attachmentURL(in: folder, todoID: todo.id, name: attachment.name),
                        as: attachment, into: area
                    )
                    result.copied[todo.id, default: []].append(attachment)
                } catch {
                    result.problems.append("\"\(todo.title)\": attachment \"\(attachment.name)\" could not be copied")
                }
            }
        }
        return result
    }
}
