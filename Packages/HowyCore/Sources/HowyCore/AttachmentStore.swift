import Foundation

/// The bytes behind `TodoAttachment`s, in a folder (the App Group container in the app).
///
/// Layout:
/// - `<root>/<todo id>/attachments.json`: the todo's attachments, in the order they were added.
/// - `<root>/<todo id>/<attachment id>/<name>`: a committed file.
/// - `<root>/staging/<attachment id>/<name>`: a file added during an unsaved edit or draft.
///
/// An edit only changes a todo's files on `commit`; until then new files wait in staging, so
/// Esc can throw them away and drafts can carry them. `collectStaging(keeping:)` deletes staged
/// files nothing refers to any more.
public final class AttachmentStore: Sendable {
    public let root: URL
    static let manifestName = "attachments.json"
    static let stagingName = "staging"

    public init(root: URL) {
        self.root = root
    }

    /// `<App Group>/Library/Application Support/Attachments`.
    public static func shared() throws -> AttachmentStore {
        guard let container = HowyAppGroup.containerURL else {
            throw TodoStoreError.appGroupUnavailable(HowyAppGroup.identifier)
        }
        return AttachmentStore(root: container.appending(path: "Library/Application Support/Attachments", directoryHint: .isDirectory))
    }

    private var fileManager: FileManager { .default }
    private var stagingDirectory: URL { root.appending(path: Self.stagingName, directoryHint: .isDirectory) }

    private func todoDirectory(_ todoID: UUID) -> URL {
        root.appending(path: todoID.uuidString, directoryHint: .isDirectory)
    }

    private func committedURL(_ attachment: TodoAttachment, todoID: UUID) -> URL {
        todoDirectory(todoID).appending(path: attachment.id.uuidString, directoryHint: .isDirectory).appending(path: attachment.name)
    }

    private func stagedURL(_ attachment: TodoAttachment) -> URL {
        stagingDirectory.appending(path: attachment.id.uuidString, directoryHint: .isDirectory).appending(path: attachment.name)
    }

    // MARK: Reading

    /// A todo's committed attachments, in order (empty when it has none).
    public func attachments(for todoID: UUID) -> [TodoAttachment] {
        guard let data = try? Data(contentsOf: todoDirectory(todoID).appending(path: Self.manifestName)),
              let list = try? JSONDecoder().decode([TodoAttachment].self, from: data)
        else { return [] }
        return list
    }

    /// Where an attachment's file is: committed for `todoID` if it is there, else staged.
    /// `nil` when the file is gone.
    public func url(for attachment: TodoAttachment, todoID: UUID?) -> URL? {
        if let todoID {
            let committed = committedURL(attachment, todoID: todoID)
            if fileManager.fileExists(atPath: committed.path(percentEncoded: false)) { return committed }
        }
        let staged = stagedURL(attachment)
        return fileManager.fileExists(atPath: staged.path(percentEncoded: false)) ? staged : nil
    }

    // MARK: Staging

    /// Copies a file into staging under `name`.
    public func stage(copying source: URL, as name: String) throws -> TodoAttachment {
        let attachment = TodoAttachment(name: name)
        let target = stagedURL(attachment)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try fileManager.copyItem(at: source, to: target)
        return attachment
    }

    /// Writes data (e.g. a pasted image) into staging under `name`.
    public func stage(data: Data, as name: String) throws -> TodoAttachment {
        let attachment = TodoAttachment(name: name)
        let target = stagedURL(attachment)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return attachment
    }

    /// Deletes every staged file whose attachment id is not in `keeping`.
    public func collectStaging(keeping: Set<UUID>) {
        guard let entries = try? fileManager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where UUID(uuidString: entry.lastPathComponent).map({ !keeping.contains($0) }) ?? true {
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: Committing

    /// Makes `attachments` the todo's attachments: staged files move in, committed ones not in
    /// the list are deleted, the manifest is rewritten. Attachments whose file is missing are
    /// dropped. Returns whether anything changed.
    @discardableResult
    public func commit(_ attachments: [TodoAttachment], for todoID: UUID) throws -> Bool {
        let old = self.attachments(for: todoID)
        var kept: [TodoAttachment] = []
        for attachment in attachments {
            let committed = committedURL(attachment, todoID: todoID)
            if fileManager.fileExists(atPath: committed.path(percentEncoded: false)) {
                kept.append(attachment)
                continue
            }
            let staged = stagedURL(attachment)
            guard fileManager.fileExists(atPath: staged.path(percentEncoded: false)) else { continue }
            try fileManager.createDirectory(at: committed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staged, to: committed)
            try? fileManager.removeItem(at: staged.deletingLastPathComponent())
            kept.append(attachment)
        }
        let keptIDs = Set(kept.map(\.id))
        for attachment in old where !keptIDs.contains(attachment.id) {
            try? fileManager.removeItem(at: committedURL(attachment, todoID: todoID).deletingLastPathComponent())
        }
        let directory = todoDirectory(todoID)
        if kept.isEmpty {
            if fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
                try fileManager.removeItem(at: directory)
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(kept).write(to: directory.appending(path: Self.manifestName), options: .atomic)
        }
        return kept != old
    }

    /// Deletes all of a todo's files (the todo was deleted or purged).
    public func removeAll(for todoID: UUID) {
        try? fileManager.removeItem(at: todoDirectory(todoID))
    }
}
