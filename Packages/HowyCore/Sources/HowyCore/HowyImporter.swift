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
    /// One line per problem, naming the todo, e.g. `Entry #12: missing title`.
    public var problems: [String] = []

    /// Every todo entry in the file.
    public var totalCount: Int { importCount + duplicateCount + invalidCount }
}

/// The result of `HowyImporter.analyze`: what an import of `folder` would do. Nothing has been
/// written yet; pass it to `HowyImporter.apply`.
public struct ImportPlan: Sendable {
    public let folder: URL
    public let report: ImportReport
    /// The todos to import, with the attachments whose files were found.
    let todos: [HowyExport.Todo]
}

/// Imports an export folder (`howy.json` + `attachments/`), merging by id: todos whose id
/// already exists are skipped with their attachments, and existing data never changes.
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

    /// Reads and checks the folder and works out what an import would do. Writes nothing.
    /// Throws `HowyImportError` when the whole import is refused.
    public func analyze(folder: URL) throws -> ImportPlan {
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
            accepted.attachments = checkedAttachments(of: todo, in: folder, report: &report)
            report.importCount += 1
            report.attachmentCount += accepted.attachments.count
            if isExpired(accepted.record) { report.expiredCount += 1 }
            todos.append(accepted)
        }
        return ImportPlan(folder: folder, report: report, todos: todos)
    }

    /// The todo's attachments that can be imported; the others are counted and reported.
    private func checkedAttachments(of todo: HowyExport.Todo, in folder: URL, report: inout ImportReport) -> [TodoAttachment] {
        var names = Set<String>()
        var ids = Set<UUID>()
        var accepted: [TodoAttachment] = []
        for attachment in todo.attachments {
            let label = "\"\(todo.title)\": attachment"
            let problem: String?
            if !HowyFormat.isSafeAttachmentName(attachment.name) {
                problem = "\(label) name \"\(attachment.name)\" is not allowed"
            } else if !names.insert(attachment.name.lowercased()).inserted {
                problem = "\(label) \"\(attachment.name)\" is listed twice"
            } else if !ids.insert(attachment.id).inserted {
                problem = "\(label) \"\(attachment.name)\" has the id of another attachment"
            } else if !Self.isFile(HowyFormat.attachmentURL(in: folder, todoID: todo.id, name: attachment.name)) {
                problem = "\(label) \"\(attachment.name)\" not found in folder"
            } else {
                problem = nil
            }
            if let problem {
                report.missingAttachmentCount += 1
                report.problems.append(problem)
            } else {
                accepted.append(attachment)
            }
        }
        return accepted
    }

    private static func isFile(_ url: URL) -> Bool {
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
            report.importCount = try store.insert(records).count
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
