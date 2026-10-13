import Foundation

/// The bytes behind `TodoAttachment`s, in a folder (the App Group container in the app).
///
/// Layout:
/// - `<root>/<todo id>/attachments.json`: the todo's attachments, in the order they were added.
/// - `<root>/<todo id>/<attachment id>/<name>`: a committed file.
/// - `<root>/staging/<attachment id>/<name>`: a file added during an unsaved edit or draft.
/// - `<root>/import-<uuid>/<attachment id>/<name>`: a file on its way in from an import.
/// - `<root>/.trash/<todo id>/…`: a todo folder the orphan cleanup took out of service. Not a
///   UUID name, so it is never a todo folder; emptied after `trashRetention`.
///
/// An edit only changes a todo's files on `commit`; until then new files wait in staging, so
/// Esc can throw them away and drafts can carry them. `collectStaging(keeping:)` deletes staged
/// files nothing refers to any more.
public final class AttachmentStore: Sendable {
    public let root: URL
    static let manifestName = "attachments.json"
    static let stagingName = "staging"
    static let trashName = ".trash"
    /// How long a trashed folder stays before `purgeTrash` deletes it: 14 days.
    public static let trashRetention: TimeInterval = 14 * 24 * 3600

    public init(root: URL) {
        self.root = root
    }

    /// `<App Group>/Library/Application Support/Attachments`.
    public static func shared() throws -> AttachmentStore {
        guard let container = HowyAppGroup.containerURL else {
            throw TodoStoreError.appGroupUnavailable(HowyAppGroup.identifier)
        }
        return AttachmentStore(root: container.appending(
            path: "Library/Application Support/\(TodoStore.storeScopedName("Attachments"))", directoryHint: .isDirectory
        ))
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

    // MARK: Importing

    /// A fresh folder for files on their way in from an import: `<root>/import-<uuid>/`, laid
    /// out like staging (`<attachment id>/<name>`). It sits outside staging so
    /// `collectStaging` can't delete files while an import copies them.
    func makeImportArea() throws -> URL {
        let area = root.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: area, withIntermediateDirectories: true)
        return area
    }

    /// Copies `source` into the import area under the attachment's id and name.
    func copyForImport(_ source: URL, as attachment: TodoAttachment, into area: URL) throws {
        let target = area.appending(path: attachment.id.uuidString, directoryHint: .isDirectory).appending(path: attachment.name)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: target)
    }

    /// Makes `attachments` (copied into `area` by `copyForImport`) the attachments of a todo that
    /// has none yet. Throws instead of touching a todo that already has attachments.
    func commitImport(_ attachments: [TodoAttachment], for todoID: UUID, from area: URL) throws {
        guard !attachments.isEmpty else { return }
        guard self.attachments(for: todoID).isEmpty else { throw CocoaError(.fileWriteFileExists) }
        for attachment in attachments {
            let source = area.appending(path: attachment.id.uuidString, directoryHint: .isDirectory).appending(path: attachment.name)
            let target = committedURL(attachment, todoID: todoID)
            try? fileManager.removeItem(at: target.deletingLastPathComponent()) // a leftover from an earlier, failed write
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: target)
        }
        try JSONEncoder().encode(attachments).write(to: todoDirectory(todoID).appending(path: Self.manifestName), options: .atomic)
    }

    /// The todo ids that have a folder here, among folders last changed before `cutoff`.
    /// Staging, import areas and anything else not named by a UUID are left out.
    func todoFolderIDs(changedBefore cutoff: Date) -> Set<UUID> {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return [] }
        var ids = Set<UUID>()
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  let changed = values.contentModificationDate, changed < cutoff
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Deletes all of a todo's files (the todo was deleted or purged).
    public func removeAll(for todoID: UUID) {
        try? fileManager.removeItem(at: todoDirectory(todoID))
    }

    // MARK: Trash

    private var trashDirectory: URL { root.appending(path: Self.trashName, directoryHint: .isDirectory) }

    /// Moves a todo's whole folder into `.trash/<todo id>/` (a numbered variant if that exists
    /// already) and dates the trashed entry `date`, which starts its retention. Returns whether
    /// anything was moved. Nothing is deleted.
    @discardableResult
    func moveToTrash(_ todoID: UUID, at date: Date) -> Bool {
        let source = todoDirectory(todoID)
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { return false }
        do {
            try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            var target = trashDirectory.appending(path: todoID.uuidString, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                target = trashDirectory.appending(path: "\(todoID.uuidString)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            }
            try fileManager.moveItem(at: source, to: target)
            try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: target.path(percentEncoded: false))
            return true
        } catch {
            return false
        }
    }

    /// The todo id a trash entry belongs to: its name is the id, or the id and `-` and a suffix.
    private static func trashedTodoID(_ name: String) -> UUID? {
        UUID(uuidString: String(name.prefix(36)))
    }

    /// Deletes trashed entries dated before `cutoff`, except those of the todos in `keeping`
    /// (they exist). Returns how many.
    @discardableResult
    func purgeTrash(olderThan cutoff: Date, keeping: Set<UUID> = []) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for entry in entries {
            if let id = Self.trashedTodoID(entry.lastPathComponent), keeping.contains(id) { continue }
            guard let changed = try? entry.resourceValues(forKeys: Set(keys)).contentModificationDate, changed < cutoff else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    /// Moves trashed folders back to `<root>/<todo id>/` for the todos in `ids` (the todo is
    /// there again, e.g. it came back through sync after another Mac deleted it). A todo that has
    /// a folder again is left alone, and so is its trash. When several entries exist for an id
    /// (numbered variants), the newest one comes back. Returns how many todos got files back.
    @discardableResult
    func restoreFromTrash(for ids: Set<UUID>) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard !ids.isEmpty,
              let entries = try? fileManager.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: keys) else { return 0 }
        var newest: [UUID: (entry: URL, date: Date)] = [:]
        for entry in entries {
            guard let id = Self.trashedTodoID(entry.lastPathComponent), ids.contains(id) else { continue }
            let date = (try? entry.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if let current = newest[id], current.date >= date { continue }
            newest[id] = (entry, date)
        }
        var restored = 0
        for (id, found) in newest {
            let target = todoDirectory(id)
            guard !fileManager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            if (try? fileManager.moveItem(at: found.entry, to: target)) != nil { restored += 1 }
        }
        return restored
    }

    /// The names of the entries in the trash (tests, diagnostics).
    func trashedNames() -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: trashDirectory.path(percentEncoded: false))) ?? []).sorted()
    }
}
