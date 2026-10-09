import Foundation

/// What an export wrote.
public struct ExportResult: Hashable, Sendable {
    /// The export folder.
    public var folder: URL
    public var todoCount: Int
    /// Attachment files copied into the folder.
    public var attachmentCount: Int
    /// One line per attachment file that couldn't be copied; it is still listed in `howy.json`.
    public var problems: [String]
}

/// Writes every todo (open and archived) and its committed attachments into an export folder.
///
/// The data is read on the main actor; writing the folder and copying files runs off it.
@MainActor
public struct HowyExporter {
    public let store: TodoStore
    /// Written to `howy.json` for information.
    public let appVersion: String?

    public init(store: TodoStore, appVersion: String? = nil) {
        self.store = store
        self.appVersion = appVersion
    }

    /// Writes the export to `folder`. Anything already at `folder` is replaced (the save panel
    /// asked first). When the folder or `howy.json` can't be written, the half-written folder
    /// is removed and the error thrown.
    public func export(to folder: URL) async throws -> ExportResult {
        let document = HowyExport(
            appVersion: appVersion,
            exportedAt: store.currentDate,
            todos: try store.allTodos().map { HowyExport.Todo(record: $0.record, attachments: store.attachmentList(for: $0.id)) }
        )
        return try await Self.write(document, to: folder, files: store.attachments)
    }

    @concurrent
    nonisolated static func write(_ document: HowyExport, to folder: URL, files: AttachmentStore?) async throws -> ExportResult {
        let fileManager = FileManager.default
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            if fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
                try fileManager.removeItem(at: folder)
            }
            try fileManager.createDirectory(
                at: folder.appending(path: HowyFormat.attachmentsFolderName, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
            var copied = 0
            var problems: [String] = []
            for todo in document.todos {
                for attachment in todo.attachments {
                    let label = "\"\(todo.title)\": attachment \"\(attachment.name)\""
                    guard HowyFormat.isSafeAttachmentName(attachment.name),
                          let source = files?.url(for: attachment, todoID: todo.id)
                    else {
                        problems.append("\(label) not found")
                        continue
                    }
                    let target = HowyFormat.attachmentURL(in: folder, todoID: todo.id, name: attachment.name)
                    do {
                        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fileManager.copyItem(at: source, to: target)
                        copied += 1
                    } catch {
                        problems.append("\(label) could not be read")
                    }
                }
            }
            try HowyFormat.makeEncoder().encode(document)
                .write(to: folder.appending(path: HowyFormat.fileName), options: .atomic)
            return ExportResult(folder: folder, todoCount: document.todos.count, attachmentCount: copied, problems: problems)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }
}
