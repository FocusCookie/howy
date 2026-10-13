import Foundation

/// The local files behind `TodoAttachment`s, in a folder (the App Group container in the app).
///
/// Since schema v4 the attachments themselves (the list and the bytes) live in the store as
/// `StoredAttachment`s, which CloudKit syncs. The todo folders here are a local copy of those
/// bytes, so Quick Look and other apps get a file URL; `TodoStore` writes a missing one again
/// from the store when it is needed. Staging and import areas are where new files wait.
///
/// Layout:
/// - `<root>/<todo id>/<attachment id>/<name>`: a committed file (the local copy).
/// - `<root>/<todo id>/attachments.json`: only in folders an older build wrote, the list as it
///   kept it; `TodoStore.adoptLegacyAttachments` moves those attachments into the store and
///   then removes the list.
/// - `<root>/staging/<attachment id>/<name>`: a file added during an unsaved edit or draft.
/// - `<root>/import-<uuid>/<attachment id>/<name>`: a file on its way in from an import.
/// - `<root>/.trash/<todo id>/…`: a todo folder the orphan cleanup took out of service. Not a
///   UUID name, so it is never a todo folder; emptied after `trashRetention`.
///
/// An edit only changes a todo's files on save (`TodoStore.setAttachments`); until then new
/// files wait in staging, so Esc can throw them away and drafts can carry them.
/// `collectStaging(keeping:)` deletes staged files nothing refers to any more.
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

    /// Where an attachment's file is: committed for `todoID` if it is there, else staged.
    /// `nil` when neither file exists (`TodoStore.attachmentURL` then writes it from the store).
    public func url(for attachment: TodoAttachment, todoID: UUID?) -> URL? {
        if let todoID, let committed = committedFile(attachment, todoID: todoID) { return committed }
        let staged = stagedURL(attachment)
        return fileManager.fileExists(atPath: staged.path(percentEncoded: false)) ? staged : nil
    }

    /// The committed file of an attachment, if it is on disk.
    func committedFile(_ attachment: TodoAttachment, todoID: UUID) -> URL? {
        let committed = committedURL(attachment, todoID: todoID)
        return fileManager.fileExists(atPath: committed.path(percentEncoded: false)) ? committed : nil
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

    /// Moves an attachment's staged file into the todo's folder. Returns the committed file:
    /// the one already there, the one just moved in, or `nil` when there is neither.
    func commitStaged(_ attachment: TodoAttachment, for todoID: UUID) throws -> URL? {
        if let committed = committedFile(attachment, todoID: todoID) { return committed }
        let staged = stagedURL(attachment)
        guard fileManager.fileExists(atPath: staged.path(percentEncoded: false)) else { return nil }
        let committed = committedURL(attachment, todoID: todoID)
        try fileManager.createDirectory(at: committed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staged, to: committed)
        try? fileManager.removeItem(at: staged.deletingLastPathComponent())
        return committed
    }

    /// Writes an attachment's bytes (from the store) as its committed file, replacing whatever
    /// its folder held (a copy under an older name). Returns the file.
    func writeCommitted(_ data: Data, for attachment: TodoAttachment, todoID: UUID) throws -> URL {
        let target = committedURL(attachment, todoID: todoID)
        let folder = target.deletingLastPathComponent()
        try? fileManager.removeItem(at: folder)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// Deletes the todo folder's attachment copies whose id isn't in `keeping`, and the folder
    /// when nothing is left in it. A folder that still has a legacy list (`attachments.json`,
    /// not adopted into the store yet) is left alone: its files are the only copy.
    func prune(_ todoID: UUID, keeping: Set<UUID>) {
        let directory = todoDirectory(todoID)
        guard !fileManager.fileExists(atPath: directory.appending(path: Self.manifestName).path(percentEncoded: false)),
              let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent), !keeping.contains(id) else { continue }
            try? fileManager.removeItem(at: entry)
        }
        if (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))?.isEmpty == true {
            try? fileManager.removeItem(at: directory)
        }
    }

    // MARK: Older builds

    /// The todo ids whose folder still has the list an older build kept (`attachments.json`).
    func legacyTodoIDs() -> Set<UUID> {
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var ids = Set<UUID>()
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  fileManager.fileExists(atPath: entry.appending(path: Self.manifestName).path(percentEncoded: false))
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// The list an older build kept for a todo, in order; `nil` when there is none or it can't
    /// be read.
    func legacyAttachments(for todoID: UUID) -> [TodoAttachment]? {
        guard let data = try? Data(contentsOf: todoDirectory(todoID).appending(path: Self.manifestName)) else { return nil }
        return try? JSONDecoder().decode([TodoAttachment].self, from: data)
    }

    /// Removes a todo's legacy list, once the store has its attachments. The files stay as the
    /// local copies.
    func removeLegacyList(for todoID: UUID) {
        try? fileManager.removeItem(at: todoDirectory(todoID).appending(path: Self.manifestName))
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

    /// Moves `attachments` (copied into `area` by `copyForImport`) into a new todo's folder;
    /// `TodoStore.insert` then stores them.
    func commitImport(_ attachments: [TodoAttachment], for todoID: UUID, from area: URL) throws {
        for attachment in attachments {
            let source = area.appending(path: attachment.id.uuidString, directoryHint: .isDirectory).appending(path: attachment.name)
            let target = committedURL(attachment, todoID: todoID)
            try? fileManager.removeItem(at: target.deletingLastPathComponent()) // a leftover from an earlier, failed write
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: target)
        }
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

    /// Deletes all of a todo's local files (the todo was deleted or purged).
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
