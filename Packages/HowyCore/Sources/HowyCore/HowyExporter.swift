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

/// Writes every todo (open and archived), its committed attachments and the whole event log
/// (format v2) into an export folder.
///
/// The data is read on a background context (`StoreMaintenance`); writing the folder and
/// copying files runs off the main actor too.
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
        let document = try await StoreMaintenance.exportDocument(
            store.modelContainer, appVersion: appVersion, exportedAt: store.currentDate, attachments: store.attachments
        )
        return try await Self.write(document, to: folder, files: store.attachments)
    }

    /// The sibling folder an atomic write builds in: `<name>.partial`.
    nonisolated static func partialURL(for folder: URL) -> URL {
        folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".partial", directoryHint: .isDirectory)
    }

    /// Writes `document` and the attachment files into `folder`.
    ///
    /// Plain (the default): anything already at `folder` is removed first, and a failure removes
    /// the half-written folder. Export… uses this, because the user's save panel only grants
    /// access to `folder` itself.
    ///
    /// `atomic` (the daily backup): builds the whole folder in `<folder>.partial`, and only once
    /// `howy.json` is written moves it to `folder`, replacing what is there (`replaceItemAt`
    /// removes the old one only after the new one is in place). A failure removes only the
    /// `.partial` folder, so an existing complete folder is never lost to a failed run.
    @concurrent
    nonisolated static func write(
        _ document: HowyExport, to folder: URL, files: AttachmentStore?, atomic: Bool = false
    ) async throws -> ExportResult {
        let fileManager = FileManager.default
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let work = atomic ? partialURL(for: folder) : folder
        do {
            if fileManager.fileExists(atPath: work.path(percentEncoded: false)) {
                try fileManager.removeItem(at: work)
            }
            try fileManager.createDirectory(
                at: work.appending(path: HowyFormat.attachmentsFolderName, directoryHint: .isDirectory),
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
                    let target = HowyFormat.attachmentURL(in: work, todoID: todo.id, name: attachment.name)
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
                .write(to: work.appending(path: HowyFormat.fileName), options: .atomic)
            if atomic {
                if fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
                    _ = try fileManager.replaceItemAt(folder, withItemAt: work)
                } else {
                    try fileManager.moveItem(at: work, to: folder)
                }
            }
            return ExportResult(folder: folder, todoCount: document.todos.count, attachmentCount: copied, problems: problems)
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }
}
