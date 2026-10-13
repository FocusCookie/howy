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

    @Test func anotherMacSeesTheAttachmentsAndGetsTheirFilesFromTheStore() async throws {
        let (todo, list) = try todo(with: [("a.txt", "A"), ("b.png", "B")])
        let other = otherMac()

        #expect(other.attachmentList(for: todo.id) == list)
        #expect(try other.openSnapshots()[.urgentImportant]?.first?.attachmentCount == 2)
        #expect(other.attachmentURL(for: list[1], todoID: todo.id) == nil, "looking never writes a file")
        #expect(try await other.materializeAttachments(for: todo.id) == 2)
        #expect(try await other.materializeAttachments(for: todo.id) == 0, "once")
        let url = try #require(other.attachmentURL(for: list[1], todoID: todo.id))
        #expect(url.lastPathComponent == "b.png")
        #expect(try contents(url) == "B")
        #expect(url.path().hasPrefix(base.appending(path: "other-mac").path()), "a local copy on that Mac")
    }

    @Test func removingAnAttachmentRemovesItEverywhere() throws {
        let (todo, list) = try todo(with: [("a.txt", "A"), ("b.txt", "B")])
        let other = otherMac()
        try other.setAttachments([list[1]], for: todo.id, startedWith: list)

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

    @Test func anEditOnAnotherMacKeepsAttachmentsItHasNoFileFor() async throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let other = otherMac()
        let otherFiles = try #require(other.attachments)
        let added = try otherFiles.stage(data: Data("N".utf8), as: "new.txt")

        try other.setAttachments(list + [added], for: todo.id, startedWith: list)

        #expect(store.attachmentList(for: todo.id) == list + [added])
        try await store.materializeAttachments(for: todo.id)
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

        try store.setAttachments([list[1], renamed], for: todo.id)
        #expect(writes.count == before + 1, "unchanged: nothing written")
    }

    @Test func attachmentChangesRecordNoEventsAndLeaveTheTodoAlone() throws {
        let (todo, _) = try todo(with: [("a.txt", "A")])
        #expect(try store.events(for: todo.id).map(\.kind) == [.created])
        #expect(try store.todo(id: todo.id)?.updatedAt == todo.createdAt)
    }

    // MARK: Deleting and purging

    @Test func deletingATodoLeavesItsAttachmentRowsToTheOrphanCleanup() async throws {
        try todo(with: [("live.txt", "L")])
        let (gone, _) = try todo(with: [("a.txt", "A")])
        try store.delete(id: gone.id)
        #expect(try store.attachmentRows(for: gone.id).count == 1)
        #expect(!exists(files.root.appending(path: gone.id.uuidString)), "the local files go at once")

        try await store.removeOrphanedAttachments()
        #expect(try store.attachmentRows(for: gone.id).count == 1, "inside the grace period")

        clock.advance(by: TodoStore.orphanGracePeriod + 1)
        try await store.removeOrphanedAttachments()
        #expect(try store.attachmentRows(for: gone.id).isEmpty)
    }

    @Test func aDeleteThatRacesAnEditLeavesTheTodoItsAttachments() async throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let macB = otherMac("mac-b")
        // Mac A deletes the todo; Mac B, which hasn't seen that, edits it. Both reach the store.
        try store.delete(id: todo.id)
        clock.advance(by: 60)
        let row = Todo(
            id: todo.id, title: "Edited on B", note: "", quadrant: .urgentImportant, createdAt: todo.createdAt, updatedAt: clock.now
        )
        macB.context.insert(row)
        try macB.context.save()

        #expect(try await store.removeDeletedTodos().isEmpty, "the later edit keeps the todo")
        clock.advance(by: TodoStore.orphanGracePeriod + 1)
        try await store.removeOrphanedAttachments()

        #expect(try store.todo(id: todo.id)?.title == "Edited on B")
        #expect(store.attachmentList(for: todo.id) == list)
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
        #expect(store.attachmentList(for: todo.id) == list, "shown before it is stored")
        #expect(try store.attachmentRows(for: todo.id).isEmpty)
        let before = writes.count

        #expect(await store.adoptLegacyAttachments() == 2)

        #expect(writes.count == before + 1)
        #expect(store.attachmentList(for: todo.id) == list)
        #expect(!exists(legacyList(todo.id)), "the old list goes")
        #expect(try contents(files.url(for: list[0], todoID: todo.id)) == "PNG", "the files stay as the local copies")
        let other = otherMac()
        try await other.materializeAttachments(for: todo.id)
        #expect(try contents(other.attachmentURL(for: list[1], todoID: todo.id)) == "PDF")
        #expect(try store.attachmentRows(for: todo.id).allSatisfy { $0.updatedAt == .distantPast })

        #expect(await store.adoptLegacyAttachments() == 0)
        #expect(writes.count == before + 1)
    }

    @Test func foldersOfTodosTheStoreDoesntHaveWaitForThem() async throws {
        let missing = UUID()
        try writeLegacyFolder(for: missing, [("a.txt", "A")])

        #expect(await store.adoptLegacyAttachments() == 0)
        #expect(exists(legacyList(missing)), "kept for a later launch")

        store.context.insert(Todo(id: missing, title: "Arrived", quadrant: .urgentImportant, createdAt: clock.now))
        try store.context.save()
        #expect(await store.adoptLegacyAttachments() == 1)
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

        #expect(await store.adoptLegacyAttachments() == 0)
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
        await fresh.adoptLegacyAttachments()
        return try fresh.attachmentRows(for: todoID).map(\.duplicateKey)
    }

    @Test func savingBeforeTheAdoptionStoresWhatTheListKeepsAndDropsWhatItDoesnt() async throws {
        let todo = try store.add(title: "Old", quadrant: .urgentImportant)
        let list = try writeLegacyFolder(for: todo.id, [("a.txt", "A"), ("b.txt", "B")])
        let added = try files.stage(data: Data("N".utf8), as: "new.txt")
        #expect(store.attachmentList(for: todo.id) == list)

        // The user removed b.txt and added new.txt.
        try store.setAttachments([list[0], added], for: todo.id, startedWith: list)

        #expect(store.attachmentList(for: todo.id) == [list[0], added])
        #expect(!exists(legacyList(todo.id)))
        #expect(try contents(files.url(for: list[0], todoID: todo.id)) == "A")
        #expect(files.url(for: list[1], todoID: todo.id) == nil, "the removed file is gone")
        #expect(await store.adoptLegacyAttachments() == 0, "and not adopted afterwards")
        #expect(store.attachmentList(for: todo.id) == [list[0], added])
    }

    @Test func removingEveryOldAttachmentBeforeTheAdoptionSticks() async throws {
        let todo = try store.add(title: "Old", quadrant: .urgentImportant)
        let list = try writeLegacyFolder(for: todo.id, [("a.txt", "A")])

        try store.setAttachments([], for: todo.id, startedWith: list)

        #expect(await store.adoptLegacyAttachments() == 0)
        #expect(store.attachmentList(for: todo.id).isEmpty)
    }

    @Test func oldAttachmentsShowBeforeTheAdoptionRuns() async throws {
        let todo = try store.add(title: "Old", quadrant: .urgentImportant)
        let list = try writeLegacyFolder(for: todo.id, [("a.txt", "A"), ("b.txt", "B")])
        // A third one is named in the list, but its file is gone.
        var all = list
        all.append(TodoAttachment(name: "lost.txt"))
        try JSONEncoder().encode(all).write(to: legacyList(todo.id))

        #expect(store.attachmentList(for: todo.id) == list)
        #expect(try store.openSnapshots()[.urgentImportant]?.first?.attachmentCount == 2)
        #expect(try contents(store.attachmentURL(for: list[1], todoID: todo.id)) == "B")

        await store.adoptLegacyAttachments()
        #expect(store.attachmentList(for: todo.id) == list, "the same after the adoption")
        #expect(try store.openSnapshots()[.urgentImportant]?.first?.attachmentCount == 2)
    }

    @Test func anUnreadableFileHoldsBackOnlyItsOwnTodo() async throws {
        let bad = try store.add(title: "Bad", quadrant: .urgentImportant)
        let good = try store.add(title: "Good", quadrant: .urgentImportant)
        let badList = try writeLegacyFolder(for: bad.id, [("ok.txt", "OK"), ("locked.txt", "X")])
        let goodList = try writeLegacyFolder(for: good.id, [("g.txt", "G")])
        let locked = try #require(files.url(for: badList[1], todoID: bad.id))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path(percentEncoded: false)) }

        #expect(await store.adoptLegacyAttachments() == 2, "the readable file of the bad todo and the good todo's")

        #expect(!exists(legacyList(good.id)))
        #expect(store.attachmentList(for: good.id) == goodList)
        #expect(exists(legacyList(bad.id)), "kept for a retry")
        #expect(try store.attachmentRows(for: bad.id).map(\.name) == ["ok.txt"])
        #expect(store.attachmentList(for: bad.id) == [badList[0], badList[1]], "the unreadable one still shows")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path(percentEncoded: false))
        #expect(await store.adoptLegacyAttachments() == 1)
        #expect(!exists(legacyList(bad.id)))
        #expect(try store.attachmentRows(for: bad.id).sorted { $0.position < $1.position }.map(\.position) == [0, 1])
    }

    @Test func adoptedAttachmentsGoAfterTheRowsATodoAlreadyHas() async throws {
        let todo = try store.add(title: "Mixed", quadrant: .urgentImportant)
        let existing = try files.stage(data: Data("E".utf8), as: "existing.txt")
        try store.setAttachments([existing], for: todo.id)
        let old = try writeLegacyFolder(for: todo.id, [("old-1.txt", "1"), ("old-2.txt", "2")])
        // The existing todo's setAttachments removed no list (there was none then); this one arrived later.

        #expect(await store.adoptLegacyAttachments() == 2)

        #expect(store.attachmentList(for: todo.id) == [existing] + old)
        #expect(try store.attachmentRows(for: todo.id).map(\.position).sorted() == [0, 1, 2])
    }

    @Test func adoptionRunsAgainWhenATodoArrivesLater() async throws {
        let later = UUID()
        let list = try writeLegacyFolder(for: later, [("a.txt", "A")])
        #expect(await store.adoptLegacyAttachments() == 0)
        try store.add(id: later, title: "Arrived", quadrant: .urgentImportant)
        #expect(MaintenancePlan.steps(cleanups: true).contains(.adoptAttachments))
        #expect(await store.adoptLegacyAttachments() == 1)
        #expect(store.attachmentList(for: later) == list)
    }

    // MARK: Gone todos

    /// What an older build leaves behind: the todo row is gone and a `deleted` event is there,
    /// the attachment rows aren't touched.
    func deleteLikeAnOlderBuild(_ id: UUID) throws {
        try store.todos(id: id).forEach(store.context.delete)
        store.context.insert(TodoEvent(todoID: id, kind: .deleted, date: clock.now, from: .urgentImportant))
        try store.context.save()
    }

    @Test func rowsOfATodoDeletedByAnOlderBuildGoAfterTheGracePeriod() async throws {
        let (live, _) = try todo(with: [("live.txt", "L")])
        let (gone, _) = try todo(with: [("gone.txt", "G")])
        try deleteLikeAnOlderBuild(gone.id)

        try await store.removeOrphanedAttachments()
        #expect(try store.attachmentRows(for: gone.id).count == 1, "inside the grace period")

        clock.advance(by: TodoStore.orphanGracePeriod + 1)
        try await store.removeOrphanedAttachments()
        #expect(try store.attachmentRows(for: gone.id).isEmpty)
        #expect(store.attachmentList(for: live.id).count == 1)
    }

    @Test func fewTodosWithAttachmentsStillGetCleanedUp() async throws {
        // With 3 or fewer todos that have attachments the "looks wiped" brake doesn't apply:
        // two of two can go, as long as a todo is left in the store.
        let (live, _) = try todo(with: [("live.txt", "L")])
        let (goneA, _) = try todo(with: [("a.txt", "A")])
        let (goneB, _) = try todo(with: [("b.txt", "B")])
        try store.delete(id: goneA.id)
        try store.delete(id: goneB.id)
        clock.advance(by: TodoStore.orphanGracePeriod + 1)

        try await store.removeOrphanedAttachments()

        #expect(try store.attachmentRows(for: goneA.id).isEmpty)
        #expect(try store.attachmentRows(for: goneB.id).isEmpty)
        #expect(store.attachmentList(for: live.id).count == 1)
    }

    @Test func aTodoWithEventsButNoDeletedEventKeepsItsAttachments() async throws {
        // Its row failed to import while its events and attachments arrived.
        try todo(with: [("live.txt", "L")])
        let (stuck, list) = try todo(with: [("a.txt", "A")])
        try store.todos(id: stuck.id).forEach(store.context.delete)
        try store.context.save()
        #expect(try store.events(for: stuck.id).map(\.kind) == [.created])

        clock.advance(by: 90 * 24 * 3600)
        try await store.removeOrphanedAttachments()

        #expect(store.attachmentList(for: stuck.id) == list)
    }

    @Test func rowsOfATodoThatWasNeverCreatedGoAfterThirtyDays() async throws {
        // `QuickEntryModel` saves the attachments, then the todo; a crash in between.
        try todo(with: [("live.txt", "L")])
        let neverCreated = UUID()
        let attachment = try files.stage(data: Data("A".utf8), as: "a.txt")
        try store.setAttachments([attachment], for: neverCreated)

        clock.advance(by: 29 * 24 * 3600)
        try await store.removeOrphanedAttachments()
        #expect(store.attachmentList(for: neverCreated) == [attachment], "may still be arriving")

        clock.advance(by: 2 * 24 * 3600)
        try await store.removeOrphanedAttachments()
        #expect(try store.attachmentRows(for: neverCreated).isEmpty)
    }

    @Test func adoptedRowsNeverCountAsOldEnoughToGiveUpOn() async throws {
        try todo(with: [("live.txt", "L")])
        let notYetArrived = UUID()
        // Adopted on another Mac, whose row reached this one before the todo.
        store.context.insert(StoredAttachment(
            id: UUID(), todoID: notYetArrived, name: "a.txt", position: 0, data: Data("A".utf8), updatedAt: .distantPast
        ))
        try store.context.save()

        clock.advance(by: 90 * 24 * 3600)
        try await store.removeOrphanedAttachments()

        #expect(try store.attachmentRows(for: notYetArrived).count == 1)
    }

    @Test func aStoreThatLooksWipedKeepsItsAttachmentRows() async throws {
        try todo(with: [("live.txt", "L")])
        var gone: [UUID] = []
        for _ in 0..<4 {
            let (todo, _) = try todo(with: [("x.txt", "X")])
            try deleteLikeAnOlderBuild(todo.id)
            gone.append(todo.id)
        }
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
        try await elsewhere.materializeAttachments(for: todo.id)
        #expect(try contents(elsewhere.attachmentURL(for: list[0], todoID: todo.id)) == "A")
    }

    // MARK: Stale lists

    @Test func savingAnOutOfDateListKeepsWhatAnotherMacAddedMeanwhile() throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        // Mac B opened the edit (it saw `list`); Mac A adds report.pdf, which syncs to B.
        let macB = otherMac("mac-b")
        let macA = otherMac("mac-a")
        let report = try #require(macA.attachments).stage(data: Data("PDF".utf8), as: "report.pdf")
        try macA.setAttachments(list + [report], for: todo.id, startedWith: list)
        #expect(macB.attachmentList(for: todo.id) == list + [report])

        // B saves what it started with plus a new file.
        let added = try #require(macB.attachments).stage(data: Data("N".utf8), as: "new.txt")
        try macB.setAttachments(list + [added], for: todo.id, startedWith: list)

        #expect(store.attachmentList(for: todo.id) == list + [added, report], "the row from the other Mac survives, last")
        #expect(try store.attachmentRows(for: todo.id).map(\.position).sorted() == [0, 1, 2])
    }

    @Test func aRemovalFromTheStartingListStillDeletes() throws {
        let (todo, list) = try todo(with: [("a.txt", "A"), ("b.txt", "B")])
        let macA = otherMac("mac-a")
        let added = try #require(macA.attachments).stage(data: Data("C".utf8), as: "c.txt")
        try macA.setAttachments(list + [added], for: todo.id, startedWith: list)

        try store.setAttachments([list[0]], for: todo.id, startedWith: list)

        #expect(store.attachmentList(for: todo.id) == [list[0], added])
    }

    @Test func theFlowRemembersTheListTheEditStartedWith() throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let row = try #require(try store.todo(id: todo.id))
        let flow = QuickEntryFlow(
            mode: .edit(QuickEntryDraft(todo: row, attachments: list)),
            lastUsed: MemoryLastQuadrantStore(), drafts: MemoryDraftStore()
        )
        let added = try files.stage(data: Data("N".utf8), as: "new.txt")
        flow.attach(added)
        flow.removeAttachment(id: list[0].id)

        #expect(flow.attachments == [added])
        #expect(flow.originalAttachments == list)
    }

    @Test func aStashedDraftKeepsTheListItStartedWithAcrossARestart() throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let row = try #require(try store.todo(id: todo.id))
        let drafts = MemoryDraftStore()
        let first = QuickEntryFlow(
            mode: .edit(QuickEntryDraft(todo: row, attachments: list)), lastUsed: MemoryLastQuadrantStore(), drafts: drafts
        )
        first.title = "Changed"
        first.abandon()

        // Another Mac adds a file; the draft is restored from a list that now has it.
        let macA = otherMac("mac-a")
        let report = try #require(macA.attachments).stage(data: Data("PDF".utf8), as: "report.pdf")
        try macA.setAttachments(list + [report], for: todo.id, startedWith: list)
        let restored = QuickEntryFlow(
            mode: .edit(QuickEntryDraft(todo: row, attachments: store.attachmentList(for: todo.id))),
            lastUsed: MemoryLastQuadrantStore(), drafts: drafts
        )

        #expect(restored.isRestoredDraft)
        #expect(restored.attachments == list)
        #expect(restored.originalAttachments == list)
        try store.setAttachments(restored.attachments, for: todo.id, startedWith: restored.originalAttachments)
        #expect(store.attachmentList(for: todo.id) == list + [report])
    }

    @Test func aDraftStashedBeforeTheStartListExistedStillSavesSafely() throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let row = try #require(try store.todo(id: todo.id))
        let drafts = MemoryDraftStore()
        drafts.setEditDraft(StashedDraft(quadrant: .urgentImportant, title: "Old", note: "", field: .title, attachments: list), for: todo.id)
        let macA = otherMac("mac-a")
        let report = try #require(macA.attachments).stage(data: Data("PDF".utf8), as: "report.pdf")
        try macA.setAttachments(list + [report], for: todo.id, startedWith: list)

        let restored = QuickEntryFlow(
            mode: .edit(QuickEntryDraft(todo: row, attachments: store.attachmentList(for: todo.id))),
            lastUsed: MemoryLastQuadrantStore(), drafts: drafts
        )
        try store.setAttachments(restored.attachments, for: todo.id, startedWith: restored.originalAttachments)

        #expect(store.attachmentList(for: todo.id) == list + [report])
    }

    // MARK: Duplicate rows without bytes

    @Test func aTwinWithBytesIsUsedWhenTheSurvivorHasNone() async throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let bytesless = StoredAttachment(
            id: list[0].id, todoID: todo.id, name: "a.txt", position: 0, data: Data("A".utf8),
            updatedAt: clock.now.addingTimeInterval(60)
        )
        bytesless.data = nil
        store.context.insert(bytesless)
        try store.context.save()
        let rows = try store.attachmentRows(for: todo.id)
        #expect(DuplicateRules.survivor(of: rows)?.data == nil, "the survivor has no bytes")

        let other = otherMac()
        try await other.materializeAttachments(for: todo.id)
        #expect(try contents(other.attachmentURL(for: list[0], todoID: todo.id)) == "A")
        #expect(rows.bytes == Data("A".utf8))
    }

    // MARK: Size limit

    @Test func aFileOverTheLimitIsRefusedWithAClearMessage() throws {
        let small = AttachmentStore(root: base.appending(path: "limited", directoryHint: .isDirectory), maxFileSize: 10)
        let source = base.appending(path: "big.bin")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(count: 11).write(to: source)

        #expect(throws: AttachmentError.self) { try small.stage(copying: source, as: "big.bin") }
        #expect(throws: AttachmentError.self) { try small.stage(data: Data(count: 11), as: "pasted.png") }
        #expect(throws: AttachmentError.self) { try small.validateSize(ofFileAt: source) }
        #expect(!exists(small.root.appending(path: "staging")), "nothing was copied")
        let message = AttachmentError.tooLarge(name: "big.bin", size: 11, limit: 10).errorDescription
        #expect(message?.contains("big.bin") == true)
        #expect(message?.contains("Attach a smaller file") == true)

        _ = try small.stage(data: Data(count: 10), as: "fits.bin")
    }

    @Test func theDefaultLimitIsOneHundredMegabytes() {
        #expect(AttachmentStore.defaultMaxFileSize == 100 * 1024 * 1024)
        #expect(files.maxFileSize == AttachmentStore.defaultMaxFileSize)
    }

    // MARK: Export reads the store

    @Test func anExportMakesNoLocalCopiesAndNeverRecreatesADeletedTodosFolder() async throws {
        let (todo, list) = try todo(with: [("a.txt", "A")])
        let other = otherMac()
        let otherRoot = try #require(other.attachments).root
        let folder = base.appending(path: "Export", directoryHint: .isDirectory)

        _ = try await HowyExporter(store: other).export(to: folder)

        #expect(try contents(HowyFormat.attachmentURL(in: folder, todoID: todo.id, name: list[0].name)) == "A")
        #expect(!exists(otherRoot.appending(path: todo.id.uuidString)), "no cache copy was written")
    }

    @Test func anExportListsAndCopiesAttachmentsNotAdoptedYet() async throws {
        let todo = try store.add(title: "Old", quadrant: .urgentImportant)
        let list = try writeLegacyFolder(for: todo.id, [("a.txt", "A")])
        let folder = base.appending(path: "Export", directoryHint: .isDirectory)

        let result = try await HowyExporter(store: store).export(to: folder)

        #expect(result.attachmentCount == 1)
        #expect(try contents(HowyFormat.attachmentURL(in: folder, todoID: todo.id, name: list[0].name)) == "A")
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
