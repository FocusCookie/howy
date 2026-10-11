import Foundation
import Testing
@testable import HowyCore

@MainActor
@Suite final class DuplicateCleanupTests {
    let clock = FakeClock()
    let writes = TodoStoreTests.WriteCounter()
    let store: TodoStore

    init() throws {
        let clock = clock
        let writes = writes
        store = try TodoStore.inMemory(now: { clock.now }, didWrite: { writes.count += 1 })
    }

    /// Inserts a second row with `id`, as a sync or a double import would, bypassing the store.
    func duplicate(
        _ id: UUID, title: String, quadrant: Quadrant = .urgentImportant, note: String = "",
        completedAt: Date? = nil, due: Date? = nil, updatedAt: Date
    ) throws {
        store.context.insert(Todo(
            id: id, title: title, note: note, quadrant: quadrant, createdAt: clock.now.addingTimeInterval(-7200),
            completedAt: completedAt, due: due, updatedAt: updatedAt
        ))
        try store.context.save()
    }

    @Test func duplicateTodosCollapseToTheNewest() async throws {
        let original = try store.add(title: "Original", quadrant: .urgentImportant)
        let other = try store.add(title: "Other", quadrant: .urgentUnimportant)
        try duplicate(original.id, title: "Newest", quadrant: .notUrgentImportant, updatedAt: clock.now.addingTimeInterval(60))
        try duplicate(original.id, title: "Oldest", updatedAt: clock.now.addingTimeInterval(-3600))
        writes.count = 0

        let result = try await store.removeDuplicates()

        #expect(result == DuplicateCleanup(removedTodos: 2, removedEvents: 0))
        let rows = try store.todos(id: original.id)
        #expect(rows.map(\.title) == ["Newest"])
        #expect(rows.first?.quadrant == .notUrgentImportant)
        #expect(try store.todo(id: other.id)?.title == "Other")
        #expect(try store.allTodos().count == 2)
        #expect(writes.count == 1)
    }

    @Test func aTieKeepsTheArchivedRow() async throws {
        let id = UUID()
        let stamp = clock.now
        try duplicate(id, title: "Open", note: "a much longer note", updatedAt: stamp)
        try duplicate(id, title: "Done", completedAt: stamp, updatedAt: stamp)

        try await store.removeDuplicates()

        #expect(try store.todos(id: id).map(\.title) == ["Done"])
    }

    @Test func aTieKeepsTheRowWithMoreData() async throws {
        let id = UUID()
        let stamp = clock.now
        try duplicate(id, title: "Plain", updatedAt: stamp)
        try duplicate(id, title: "Dated", due: stamp.addingTimeInterval(3600), updatedAt: stamp)
        try duplicate(id, title: "Noted", note: "details", updatedAt: stamp)

        try await store.removeDuplicates()

        #expect(try store.todos(id: id).map(\.title) == ["Dated"])
    }

    @Test func duplicateEventsCollapseToOne() async throws {
        let todo = try store.add(title: "Logged", quadrant: .urgentImportant)
        try store.complete(id: todo.id)
        let created = try #require(try store.events(for: todo.id).first)
        for _ in 0..<2 {
            store.context.insert(TodoEvent(record: created.record))
        }
        try store.context.save()
        #expect(try store.events(for: todo.id).count == 4)
        writes.count = 0

        let result = try await store.removeDuplicates()

        #expect(result == DuplicateCleanup(removedTodos: 0, removedEvents: 2))
        #expect(try store.events(for: todo.id).compactMap(\.kind) == [.created, .completed])
        #expect(try store.allTodos().count == 1)
        #expect(writes.count == 1)
    }

    @Test func cleanupRecordsNoEvents() async throws {
        let todo = try store.add(title: "Original", quadrant: .urgentImportant)
        try duplicate(todo.id, title: "Copy", updatedAt: clock.now.addingTimeInterval(60))
        let before = try store.allEvents().map(\.record)

        try await store.removeDuplicates()

        #expect(try store.allEvents().map(\.record) == before)
    }

    @Test func aCleanStoreIsUntouchedAndNotWritten() async throws {
        let a = try store.add(title: "A", quadrant: .urgentImportant)
        try store.complete(id: a.id)
        try store.add(title: "B", quadrant: .notUrgentUnimportant)
        let todos = try store.allTodos().map(\.record)
        let events = try store.allEvents().map(\.record)
        writes.count = 0

        let result = try await store.removeDuplicates()

        #expect(result.isEmpty)
        #expect(!store.context.hasChanges)
        #expect(try store.allTodos().map(\.record) == todos)
        #expect(try store.allEvents().map(\.record) == events)
        #expect(writes.count == 0)
    }

    @Test func anEmptyStoreIsFine() async throws {
        #expect(try await store.removeDuplicates().isEmpty)
        #expect(writes.count == 0)
    }
}

@MainActor
@Suite final class OrphanedAttachmentTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "howy-orphans-\(UUID().uuidString)", directoryHint: .isDirectory)
    let clock = FakeClock()
    let files: AttachmentStore
    let store: TodoStore

    init() throws {
        let clock = clock
        files = AttachmentStore(root: base)
        store = try TodoStore.inMemory(attachments: files, now: { clock.now })
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    var fileManager: FileManager { .default }

    func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    func folder(_ id: UUID) -> URL {
        base.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Commits one attachment for `id` (todo or not) and dates its folder `age` before the clock.
    @discardableResult
    func attach(to id: UUID, age: TimeInterval = 24 * 3600) throws -> TodoAttachment {
        let attachment = try files.stage(data: Data("file".utf8), as: "file.txt")
        try store.setAttachments([attachment], for: id)
        try backdate(folder(id), by: age)
        return attachment
    }

    func backdate(_ url: URL, by age: TimeInterval) throws {
        try fileManager.setAttributes([.modificationDate: clock.now.addingTimeInterval(-age)], ofItemAtPath: url.path(percentEncoded: false))
    }

    var trash: URL { base.appending(path: AttachmentStore.trashName, directoryHint: .isDirectory) }

    func trashed(_ id: UUID) -> URL { trash.appending(path: id.uuidString, directoryHint: .isDirectory) }

    @Test func foldersOfMissingTodosMoveToTheTrash() async throws {
        let open = try store.add(title: "Open", quadrant: .urgentImportant)
        let archived = try store.add(title: "Archived", quadrant: .notUrgentImportant)
        try store.complete(id: archived.id)
        try attach(to: open.id)
        try attach(to: archived.id)
        let gone = UUID()
        try attach(to: gone)
        #expect(files.attachments(for: gone).count == 1)

        let moved = try await store.removeOrphanedAttachments()

        #expect(moved == 1)
        #expect(!exists(folder(gone)))
        #expect(files.attachments(for: gone).isEmpty)
        #expect(exists(trashed(gone).appending(path: AttachmentStore.manifestName)), "the files are kept, not deleted")
        #expect(store.attachmentList(for: open.id).count == 1)
        #expect(store.attachmentList(for: archived.id).count == 1)
        for id in [open.id, archived.id] {
            let attachment = try #require(store.attachmentList(for: id).first)
            #expect(files.url(for: attachment, todoID: id) != nil)
        }
    }

    @Test func aDeletedTodosLeftoverFolderMovesToTheTrash() async throws {
        try store.add(title: "Stays", quadrant: .urgentImportant)
        let todo = try store.add(title: "Synced away", quadrant: .urgentImportant)
        try attach(to: todo.id)
        // Deleted elsewhere (another device): the row goes, the folder stays.
        try store.todos(id: todo.id).forEach(store.context.delete)
        try store.context.save()

        #expect(try await store.removeOrphanedAttachments() == 1)
        #expect(!exists(folder(todo.id)))
        #expect(exists(trashed(todo.id)))
    }

    @Test func recentFoldersAreSparedForTheGracePeriod() async throws {
        try store.add(title: "Stays", quadrant: .urgentImportant)
        let unsaved = UUID() // a new todo's files are committed just before the todo is saved
        try attach(to: unsaved, age: 60)

        #expect(try await store.removeOrphanedAttachments() == 0)
        #expect(exists(folder(unsaved)))

        clock.advance(by: TodoStore.orphanGracePeriod)
        #expect(try await store.removeOrphanedAttachments() == 1)
        #expect(!exists(folder(unsaved)))
        #expect(exists(trashed(unsaved)))
    }

    @Test func anEmptyStoreDeletesAndMovesNothing() async throws {
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { try attach(to: id) }

        #expect(try await store.removeOrphanedAttachments() == 0)

        for id in ids { #expect(exists(folder(id))) }
        #expect(!exists(trash))
    }

    @Test func aMostlyOrphanedSetTriggersTheBrake() async throws {
        let live = try store.add(title: "Live", quadrant: .urgentImportant)
        try attach(to: live.id)
        let orphans = (0..<4).map { _ in UUID() } // 4 of 5 candidates
        for id in orphans { try attach(to: id) }

        #expect(try await store.removeOrphanedAttachments() == 0)

        for id in orphans + [live.id] { #expect(exists(folder(id))) }
        #expect(!exists(trash))
    }

    @Test func aFewOrphansAmongManyLiveFoldersPassTheBrake() async throws {
        var liveIDs: [UUID] = []
        for index in 0..<5 {
            let todo = try store.add(title: "Live \(index)", quadrant: .urgentImportant)
            try attach(to: todo.id)
            liveIDs.append(todo.id)
        }
        let orphans = [UUID(), UUID()] // 2 of 7: not more than half
        for id in orphans { try attach(to: id) }

        #expect(try await store.removeOrphanedAttachments() == 2)

        for id in orphans { #expect(exists(trashed(id))) }
        for id in liveIDs { #expect(store.attachmentList(for: id).count == 1) }
    }

    @Test func smallSetsAreNotBraked() async throws {
        let live = try store.add(title: "Live", quadrant: .urgentImportant)
        try attach(to: live.id)
        let orphans = (0..<2).map { _ in UUID() } // 2 of 3: at most 3 candidates, no brake
        for id in orphans { try attach(to: id) }

        #expect(try await store.removeOrphanedAttachments() == 2)
    }

    @Test func trashedFoldersAreDeletedAfterFourteenDays() async throws {
        let live = try store.add(title: "Live", quadrant: .urgentImportant)
        try attach(to: live.id)
        let gone = UUID()
        try attach(to: gone)
        #expect(try await store.removeOrphanedAttachments() == 1)

        clock.advance(by: 14 * 24 * 3600 - 60)
        try await store.removeOrphanedAttachments()
        #expect(exists(trashed(gone)), "still inside the 14 days")

        clock.advance(by: 120)
        try await store.removeOrphanedAttachments()
        #expect(!exists(trashed(gone)))
        #expect(store.attachmentList(for: live.id).count == 1, "live attachments are never touched")
    }

    @Test func theTrashIsNotEmptiedWhileTheBrakeHolds() async throws {
        let live = try store.add(title: "Live", quadrant: .urgentImportant)
        try attach(to: live.id)
        let gone = UUID()
        try attach(to: gone)
        try await store.removeOrphanedAttachments()
        // The store is wiped; a month later the trash must still be there.
        try store.todos(id: live.id).forEach(store.context.delete)
        try store.context.save()
        clock.advance(by: 30 * 24 * 3600)

        try await store.removeOrphanedAttachments()

        #expect(exists(trashed(gone)))
        #expect(exists(folder(live.id)))
    }

    @Test func aSecondTrashingOfTheSameIDKeepsBothCopies() async throws {
        let live = try store.add(title: "Live", quadrant: .urgentImportant)
        try attach(to: live.id)
        let gone = UUID()
        try attach(to: gone)
        try await store.removeOrphanedAttachments()
        try attach(to: gone)

        try await store.removeOrphanedAttachments()

        #expect(files.trashedNames().count == 2)
    }

    @Test func stagingImportAreasAndStrayFilesAreLeftAlone() async throws {
        try store.add(title: "Stays", quadrant: .urgentImportant)
        let staged = try files.stage(data: Data("draft".utf8), as: "draft.txt")
        let area = try files.makeImportArea()
        let stray = base.appending(path: "notes.txt")
        try Data("x".utf8).write(to: stray)
        let staging = base.appending(path: AttachmentStore.stagingName, directoryHint: .isDirectory)
        for url in [staging, area, stray] { try backdate(url, by: 24 * 3600) }

        #expect(try await store.removeOrphanedAttachments() == 0)
        #expect(files.url(for: staged, todoID: nil) != nil)
        #expect(exists(area))
        #expect(exists(stray))
    }

    @Test func nothingToCleanRemovesNothing() async throws {
        let todo = try store.add(title: "Mine", quadrant: .urgentImportant)
        try attach(to: todo.id)
        #expect(try await store.removeOrphanedAttachments() == 0)
        #expect(store.attachmentList(for: todo.id).count == 1)
    }

    @Test func aStoreWithoutAttachmentsDoesNothing() async throws {
        let plain = try TodoStore.inMemory()
        #expect(try await plain.removeOrphanedAttachments() == 0)
    }
}
