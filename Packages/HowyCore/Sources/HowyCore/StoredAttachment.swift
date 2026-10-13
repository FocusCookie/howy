import Foundation
import SwiftData

/// An attached file as stored and synced (schema v4): the bytes and where it belongs.
///
/// This is what makes attachments reach other Macs: it lives in the SwiftData store next to the
/// todos, so CloudKit mirrors it with them (the bytes, kept outside the SQLite file through
/// `.externalStorage`, go up as a CloudKit asset). The files under `AttachmentStore`'s todo
/// folders are only a local copy of these bytes, for Quick Look, opening and dragging; a file
/// missing there is written again from here when it is needed (`TodoStore.attachmentURL`).
///
/// Like `TodoEvent`, it has no relationship to `Todo` and refers to it by `todoID` only, so rows
/// that share a todo id (duplicates) don't matter to it. Every attribute has a default and none
/// is unique, as CloudKit requires.
@Model
public final class StoredAttachment {
    public var id: UUID = UUID()
    public var todoID: UUID = UUID()
    /// The file name; unique within the todo, and what the note references.
    public var name: String = ""
    /// The place in the todo's list, from 0. Reads sort by it, then by name.
    public var position: Int = 0
    /// `data`'s size, so comparing duplicates never loads the bytes.
    public var byteCount: Int = 0
    /// When a `TodoStore` write last changed the name or the position (`.distantPast` for an
    /// attachment adopted from the files of an older build, so two Macs adopting one file write
    /// identical rows). Picks the survivor when duplicates of one id meet.
    public var updatedAt: Date = Date.distantPast
    /// The file's bytes, in a file next to the store (external storage) and a CloudKit asset.
    /// Never changes for an id.
    @Attribute(.externalStorage) public var data: Data?

    public init(id: UUID, todoID: UUID, name: String, position: Int, data: Data, updatedAt: Date) {
        self.id = id
        self.todoID = todoID
        self.name = name
        self.position = position
        self.byteCount = data.count
        // Whole milliseconds, as CloudKit keeps them (`Date.wholeMilliseconds`).
        self.updatedAt = updatedAt.wholeMilliseconds
        self.data = data
    }

    /// The value the flows and drafts carry.
    public var attachment: TodoAttachment {
        TodoAttachment(id: id, name: name)
    }
}

extension StoredAttachment: DuplicateResolvable {
    /// Every stored value but `id` and the bytes (which never change for an id; `byteCount`
    /// stands in for them).
    struct DuplicateKey: Hashable {
        var updatedAt: Int64
        var byteCount: Int
        var position: Int
        var name: String
        var todoID: String
    }

    var duplicateKey: DuplicateKey {
        DuplicateKey(
            updatedAt: DuplicateRules.milliseconds(updatedAt),
            byteCount: byteCount,
            position: position,
            name: name,
            todoID: todoID.uuidString
        )
    }

    /// Which of two rows with one id survives: the newer `updatedAt` (the last rename or move
    /// wins), then the larger `byteCount`, the lower `position`, the greater `name` and the
    /// lower `todoID` (as a string). A total order over every compared value.
    static func prefers(_ a: DuplicateKey, over b: DuplicateKey) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.byteCount != b.byteCount { return a.byteCount > b.byteCount }
        if a.position != b.position { return a.position < b.position }
        if a.name != b.name { return a.name > b.name }
        return a.todoID < b.todoID
    }
}

extension Array where Element == StoredAttachment {
    /// One row per attachment id (the survivor), in list order: by `position`, then `name`.
    var orderedSurvivors: [StoredAttachment] {
        DuplicateRules.collapsed(self).sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    }
}
