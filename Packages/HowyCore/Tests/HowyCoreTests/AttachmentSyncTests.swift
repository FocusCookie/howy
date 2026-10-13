import Foundation
import SwiftData
import Testing
@testable import HowyCore

/// Attachments live in the store (schema v4), so whatever syncs the store syncs them. "Another
/// Mac" here is a second `TodoStore` on the same container with its own, empty attachment
/// folder: it has the rows (as CloudKit would bring them) but none of the local files.
@MainActor
@Suite final class AttachmentSyncTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "howy-attachment-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    let clock = FakeClock()
    let files: AttachmentStore
    let writes = TodoStoreTests.WriteCounter()
    let store: TodoStore

    init() throws {
        let clock = clock
        let writes = writes
        files = AttachmentStore(root: base.appending(path: "this-mac", directoryHint: .isDirectory))
        store = try TodoStore.inMemory(attachments: files, now: { clock.now }, didWrite: { writes.count += 1 })
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    /// A store on the same container, with its own empty attachment folder.
    func otherMac(_ name: String = "other-mac") -> TodoStore {
        let clock = clock
        return TodoStore(
            modelContainer: store.modelContainer,
            attachments: AttachmentStore(root: base.appending(path: name, directoryHint: .isDirectory)),
            now: { clock.now }
        )
    }

    func contents(_ url: URL?) throws -> String? {
        try url.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// A todo with the given files attached (name → contents), in order.
    @discardableResult
    func todo(with attached: [(String, String)]) throws -> (Todo, [TodoAttachment]) {
        let todo = try store.add(title: "T", quadrant: .urgentImportant)
        let list = try attached.map { try files.stage(data: Data($0.1.utf8), as: $0.0) }
        try store.setAttachments(list, for: todo.id)
        return (todo, list)
    }

    // MARK: Reaching another Mac

    @Test func anotherMacSeesTheAttachmentsAndGetsTheirFilesFromTheStore() throws {
        let (todo, list) = try todo(with: [("a.txt", "A"), ("b.png", "B")])
        let other = otherMac()

        #expect(other.attachmentList(for: todo.id) == list)
        #expect(try other.openSnapshots()[.urgentImportant]?.first?.attachmentCount == 2)
        let url = try #require(other.attachmentURL(for: list[1], todoID: todo.id))
        #expect(url.lastPathComponent == "b.png")
        #expect(try contents(url) == "B")
        #expect(url.path().hasPrefix(base.appending(path: "other-mac").path()), "a local copy on that Mac")
    }

    @Test func removingAnAttachmentRemovesItEverywhere() throws {
        let (todo, list) = try todo(with: [("a.txt", "A"), ("b.txt", "B")])
        let other = otherMac()
        try other.setAttachments([list[1]], for: todo.id)

        #expect(store.attachmentList(for: todo.id) == [list[1]])
        #expect(try store.attachmentRows(for: todo.id).count == 1)
    }

    @Test func aFileWhoseBytesNeverArrivedCantBeOpened() throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        try store.attachmentRows(for: todo.id).forEach { $0.data = nil }
        try store.context.save()

        #expect(otherMac().attachmentList(for: todo.id) == list, "still listed")
        #expect(otherMac().attachmentURL(for: list[0], todoID: todo.id) == nil)
    }

    @Test func anEditOnAnotherMacKeepsAttachmentsItHasNoFileFor() throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let other = otherMac()
        let otherFiles = try #require(other.attachments)
        let added = try otherFiles.stage(data: Data("N".utf8), as: "new.txt")

        try other.setAttachments(list + [added], for: todo.id)

        #expect(store.attachmentList(for: todo.id) == list + [added])
        #expect(try contents(store.attachmentURL(for: added, todoID: todo.id)) == "N")
    }

    @Test func reorderingAndRenamingAreSaved() throws {
        let (todo, list) = try todo(with: [("a.txt", "A"), ("b.txt", "B")])
        var renamed = list[0]
        renamed.name = "first.txt"
        let before = writes.count
        try store.setAttachments([list[1], renamed], for: todo.id)
        #expect(writes.count == before + 1)
        #expect(otherMac().attachmentList(for: todo.id) == [list[1], renamed])
        #expect(try contents(otherMac().attachmentURL(for: renamed, todoID: todo.id)) == "A")

        try store.setAttachments([list[1], renamed], for: todo.id)
        #expect(writes.count == before + 1, "unchanged: nothing written")
    }

    @Test func attachmentChangesRecordNoEventsAndLeaveTheTodoAlone() throws {
        let (todo, _) = try todo(with: [("a.txt", "A")])
        #expect(try store.events(for: todo.id).map(\.kind) == [.created])
        #expect(try store.todo(id: todo.id)?.updatedAt == todo.createdAt)
    }

    // MARK: Deleting and purging

    @Test func deletingATodoDeletesItsAttachmentRows() throws {
        let (todo, _) = try todo(with: [("a.txt", "A")])
        try store.delete(id: todo.id)
        #expect(try store.attachmentRows(for: todo.id).isEmpty)
    }

    @Test func purgingDeletesTheAttachmentRows() throws {
        let (todo, _) = try todo(with: [("a.txt", "A")])
        try store.complete(id: todo.id)
        clock.advance(by: ArchiveRetention.default.interval + 1)
        try store.purgeArchive()
        #expect(try store.attachmentRows(for: todo.id).isEmpty)
    }

    // MARK: Duplicates

    @Test func duplicateAttachmentRowsReadAsOneAndTheCleanupKeepsTheNewest() async throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        // The same attachment, renamed later on another Mac, arrives as a second record.
        store.context.insert(StoredAttachment(
            id: list[0].id, todoID: todo.id, name: "renamed.txt", position: 0,
            data: Data("A".utf8), updatedAt: clock.now.addingTimeInterval(60)
        ))
        try store.context.save()

        #expect(store.attachmentList(for: todo.id).map(\.name) == ["renamed.txt"])
        #expect(try store.openSnapshots()[.urgentImportant]?.first?.attachmentCount == 1)

        let result = try await store.removeDuplicates()
        #expect(result == DuplicateCleanup(removedAttachments: 1))
        #expect(try ModelContext(store.modelContainer).fetch(FetchDescriptor<StoredAttachment>()).map(\.name) == ["renamed.txt"])
    }

    @Test func identicalAttachmentRowsAreAllKept() async throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let row = try #require(try store.attachmentRows(for: todo.id).first)
        store.context.insert(StoredAttachment(
            id: list[0].id, todoID: todo.id, name: row.name, position: row.position, data: Data("A".utf8), updatedAt: row.updatedAt
        ))
        try store.context.save()

        #expect(try await store.removeDuplicates().isEmpty)
        #expect(store.attachmentList(for: todo.id) == list)
    }

    // MARK: Files from builds before schema v4

    /// Writes a todo folder as builds before v4 did: the files plus `attachments.json`.
    @discardableResult
    func writeLegacyFolder(for todoID: UUID, _ attached: [(String, String)]) throws -> [TodoAttachment] {
        let folder = files.root.appending(path: todoID.uuidString, directoryHint: .isDirectory)
        var list: [TodoAttachment] = []
        for (name, text) in attached {
            let attachment = TodoAttachment(name: name)
            let file = folder.appending(path: attachment.id.uuidString, directoryHint: .isDirectory).appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            list.append(attachment)
        }
        try JSONEncoder().encode(list).write(to: folder.appending(path: AttachmentStore.manifestName))
        return list
    }

    func legacyList(_ todoID: UUID) -> URL {
        files.root.appending(path: todoID.uuidString, directoryHint: .isDirectory).appending(path: AttachmentStore.manifestName)
    }

    @Test func filesOfAnOlderBuildMoveIntoTheStoreOnce() async throws {
        let todo = try store.add(title: "Old", quadrant: .urgentImportant)
        let list = try writeLegacyFolder(for: todo.id, [("receipt.png", "PNG"), ("plan.pdf", "PDF")])
        #expect(store.attachmentList(for: todo.id).isEmpty)
        let before = writes.count

        #expect(try await store.adoptLegacyAttachments() == 2)

        #expect(writes.count == before + 1)
        #expect(store.attachmentList(for: todo.id) == list)
        #expect(!exists(legacyList(todo.id)), "the old list goes")
        #expect(try contents(files.url(for: list[0], todoID: todo.id)) == "PNG", "the files stay as the local copies")
        #expect(try contents(otherMac().attachmentURL(for: list[1], todoID: todo.id)) == "PDF")
        #expect(try store.attachmentRows(for: todo.id).allSatisfy { $0.updatedAt == .distantPast })

        #expect(try await store.adoptLegacyAttachments() == 0)
        #expect(writes.count == before + 1)
    }

    @Test func foldersOfTodosTheStoreDoesntHaveWaitForThem() async throws {
        let missing = UUID()
        try writeLegacyFolder(for: missing, [("a.txt", "A")])

        #expect(try await store.adoptLegacyAttachments() == 0)
        #expect(exists(legacyList(missing)), "kept for a later launch")

        store.context.insert(Todo(id: missing, title: "Arrived", quadrant: .urgentImportant, createdAt: clock.now))
        try store.context.save()
        #expect(try await store.adoptLegacyAttachments() == 1)
        #expect(store.attachmentList(for: missing).map(\.name) == ["a.txt"])
    }

    @Test func anAttachmentAlreadyInTheStoreIsNotAdoptedAgain() async throws {
        let todo = try store.add(title: "Old", quadrant: .urgentImportant)
        let list = try writeLegacyFolder(for: todo.id, [("a.txt", "A")])
        // Another Mac adopted the same file first, and its row arrived.
        store.context.insert(StoredAttachment(
            id: list[0].id, todoID: todo.id, name: "a.txt", position: 0, data: Data("A".utf8), updatedAt: .distantPast
        ))
        try store.context.save()

        #expect(try await store.adoptLegacyAttachments() == 0)
        #expect(try store.attachmentRows(for: todo.id).count == 1)
        #expect(!exists(legacyList(todo.id)))
    }

    @Test func twoMacsAdoptingOneFileWriteIdenticalRows() async throws {
        let todo = try store.add(title: "Old", quadrant: .urgentImportant)
        let list = try writeLegacyFolder(for: todo.id, [("a.txt", "A")])
        // The other Mac's folder is the same (a restored backup on both).
        let other = otherMac()
        let otherRoot = try #require(other.attachments).root
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: files.root.appending(path: todo.id.uuidString), to: otherRoot.appending(path: todo.id.uuidString)
        )
        #expect(list.count == 1)

        // Both adopt before either sees the other's row (separate stores, merged afterwards).
        let rowsHere = try await adoptInFreshStore(files: try #require(store.attachments), todoID: todo.id)
        let rowsThere = try await adoptInFreshStore(files: try #require(other.attachments), todoID: todo.id)
        #expect(rowsHere == rowsThere)
    }

    /// Adopts `files` into a new in-memory store that has the todo, and returns the rows' keys.
    private func adoptInFreshStore(files: AttachmentStore, todoID: UUID) async throws -> [StoredAttachment.DuplicateKey] {
        let fresh = try TodoStore.inMemory(attachments: files)
        try fresh.add(id: todoID, title: "Old", quadrant: .urgentImportant)
        try await fresh.adoptLegacyAttachments()
        return try fresh.attachmentRows(for: todoID).map(\.duplicateKey)
    }

    @Test func savingBeforeTheAdoptionKeepsTheOldFiles() throws {
        let todo = try store.add(title: "Old", quadrant: .urgentImportant)
        let list = try writeLegacyFolder(for: todo.id, [("a.txt", "A")])
        let added = try files.stage(data: Data("N".utf8), as: "new.txt")

        try store.setAttachments([added], for: todo.id)

        #expect(exists(legacyList(todo.id)))
        #expect(try contents(files.url(for: list[0], todoID: todo.id)) == "A")
    }

    // MARK: Gone todos

    @Test func rowsOfATodoDeletedByAnOlderBuildGoAfterTheGracePeriod() async throws {
        let (live, _) = try todo(with: [("live.txt", "L")])
        let (gone, _) = try todo(with: [("gone.txt", "G")])
        // An older build deletes the todo without knowing about its attachment rows.
        try store.todos(id: gone.id).forEach(store.context.delete)
        try store.context.save()

        try await store.removeOrphanedAttachments()
        #expect(try store.attachmentRows(for: gone.id).count == 1, "inside the grace period")

        clock.advance(by: TodoStore.orphanGracePeriod + 1)
        try await store.removeOrphanedAttachments()
        #expect(try store.attachmentRows(for: gone.id).isEmpty)
        #expect(store.attachmentList(for: live.id).count == 1)
    }

    @Test func rowsOfATodoWithNoHistoryWaitForIt() async throws {
        try todo(with: [("live.txt", "L")])
        let notYetArrived = UUID()
        let attachment = try files.stage(data: Data("A".utf8), as: "a.txt")
        try store.setAttachments([attachment], for: notYetArrived)

        clock.advance(by: 30 * 24 * 3600)
        try await store.removeOrphanedAttachments()

        #expect(store.attachmentList(for: notYetArrived) == [attachment])
    }

    @Test func aStoreThatLooksWipedKeepsItsAttachmentRows() async throws {
        try todo(with: [("live.txt", "L")])
        var gone: [UUID] = []
        for _ in 0..<4 {
            let (todo, _) = try todo(with: [("x.txt", "X")])
            try store.todos(id: todo.id).forEach(store.context.delete)
            gone.append(todo.id)
        }
        try store.context.save()
        clock.advance(by: TodoStore.orphanGracePeriod + 1)

        try await store.removeOrphanedAttachments()

        for id in gone { #expect(try store.attachmentRows(for: id).count == 1) }
    }

    // MARK: Export and import

    @Test func anExportWritesAttachmentsThisMacHasNoFileFor() async throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let folder = base.appending(path: "Export", directoryHint: .isDirectory)

        let result = try await HowyExporter(store: otherMac()).export(to: folder)

        #expect(result.attachmentCount == 1)
        #expect(result.problems.isEmpty)
        #expect(try contents(HowyFormat.attachmentURL(in: folder, todoID: todo.id, name: list[0].name)) == "A")
    }

    @Test func importedAttachmentsAreInTheStore() async throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let folder = base.appending(path: "Export", directoryHint: .isDirectory)
        _ = try await HowyExporter(store: store).export(to: folder)

        let target = try TodoStore.inMemory(attachments: AttachmentStore(root: base.appending(path: "target", directoryHint: .isDirectory)))
        let importer = HowyImporter(store: target)
        _ = try await importer.apply(try await importer.analyze(folder: folder))

        let elsewhere = TodoStore(modelContainer: target.modelContainer, attachments: AttachmentStore(root: base.appending(path: "target-2")))
        #expect(elsewhere.attachmentList(for: todo.id) == list)
        #expect(try contents(elsewhere.attachmentURL(for: list[0], todoID: todo.id)) == "A")
    }

    // MARK: Schema

    @Test func aVersionThreeStoreOpensUnderVersionFour() throws {
        let directory = base.appending(path: "v3", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Howy.store")
        let id = UUID()
        do {
            let schema = Schema(versionedSchema: HowySchemaV3.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: nil, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            )
            container.mainContext.insert(Todo(id: id, title: "Kept", note: "note", quadrant: .notUrgentImportant, createdAt: clock.now))
            container.mainContext.insert(TodoEvent(todoID: id, kind: .created, date: clock.now, to: .notUrgentImportant))
            try container.mainContext.save()
        }

        let store = try TodoStore.onDisk(url: url, attachments: files)
        #expect(try store.todo(id: id)?.title == "Kept")
        #expect(try store.events(for: id).map(\.kind) == [.created])
        let attachment = try files.stage(data: Data("A".utf8), as: "a.txt")
        try store.setAttachments([attachment], for: id)
        #expect(try TodoStore.onDisk(url: url, attachments: files).attachmentList(for: id) == [attachment])
    }
}
