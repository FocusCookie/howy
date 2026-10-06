import Foundation

/// What a closed-but-unsaved modal leaves behind, so the next open can carry on (like Spotlight
/// keeping its last query).
public struct StashedDraft: Codable, Hashable, Sendable {
    /// Where the user was: the picker, the title or the note.
    public enum Field: String, Codable, Hashable, Sendable {
        case quadrant, title, note
    }

    public var quadrant: Quadrant
    public var title: String
    public var note: String
    public var field: Field

    public init(quadrant: Quadrant, title: String, note: String, field: Field) {
        self.quadrant = quadrant
        self.title = title
        self.note = note
        self.field = field
    }
}

/// Keeps unsaved drafts: one for Quick Add, and one per edited todo.
/// Setting `nil` clears the slot.
@MainActor
public protocol DraftStore: AnyObject {
    func createDraft() -> StashedDraft?
    func setCreateDraft(_ draft: StashedDraft?)
    func editDraft(for id: UUID) -> StashedDraft?
    func setEditDraft(_ draft: StashedDraft?, for id: UUID)
}

/// The stash contents shared by the in-memory and `UserDefaults` stores.
/// Edit drafts are capped (oldest dropped) so abandoned edits can't pile up.
struct DraftStash: Codable, Hashable, Sendable {
    struct EditEntry: Codable, Hashable, Sendable {
        var id: UUID
        var draft: StashedDraft
    }

    static let maxEditDrafts = 20

    var create: StashedDraft?
    /// Oldest first.
    var edits: [EditEntry] = []

    func edit(for id: UUID) -> StashedDraft? {
        edits.last { $0.id == id }?.draft
    }

    mutating func setEdit(_ draft: StashedDraft?, for id: UUID) {
        edits.removeAll { $0.id == id }
        if let draft { edits.append(EditEntry(id: id, draft: draft)) }
        if edits.count > Self.maxEditDrafts { edits.removeFirst(edits.count - Self.maxEditDrafts) }
    }
}

/// A `DraftStore` that lives only as long as the object (tests, previews).
@MainActor
public final class MemoryDraftStore: DraftStore {
    public static let maxEditDrafts = DraftStash.maxEditDrafts
    private var stash = DraftStash()

    public init() {}

    public func createDraft() -> StashedDraft? { stash.create }
    public func setCreateDraft(_ draft: StashedDraft?) { stash.create = draft }
    public func editDraft(for id: UUID) -> StashedDraft? { stash.edit(for: id) }
    public func setEditDraft(_ draft: StashedDraft?, for id: UUID) { stash.setEdit(draft, for: id) }
}

/// A `DraftStore` in `UserDefaults` (JSON), so drafts survive an app restart.
@MainActor
public final class UserDefaultsDraftStore: DraftStore {
    public static let defaultKey = "draftStash"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsDraftStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func createDraft() -> StashedDraft? { load().create }

    public func setCreateDraft(_ draft: StashedDraft?) {
        var stash = load()
        stash.create = draft
        save(stash)
    }

    public func editDraft(for id: UUID) -> StashedDraft? { load().edit(for: id) }

    public func setEditDraft(_ draft: StashedDraft?, for id: UUID) {
        var stash = load()
        stash.setEdit(draft, for: id)
        save(stash)
    }

    private func load() -> DraftStash {
        guard let data = defaults.data(forKey: key),
              let stash = try? JSONDecoder().decode(DraftStash.self, from: data)
        else { return DraftStash() }
        return stash
    }

    private func save(_ stash: DraftStash) {
        if stash.create == nil, stash.edits.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(stash) {
            defaults.set(data, forKey: key)
        }
    }
}
