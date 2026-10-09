import Foundation
import Testing
@testable import HowyCore

/// A controllable clock for deterministic ordering and purge tests.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

@MainActor
@Suite struct TodoStoreTests {
    let clock = FakeClock()
    let store: TodoStore
    let writes = WriteCounter()

    final class WriteCounter { var count = 0 }

    init() throws {
        let clock = clock
        let writes = writes
        store = try TodoStore.inMemory(now: { clock.now }, didWrite: { writes.count += 1 })
    }

    // MARK: add

    @Test func addCreatesOpenTodoWithClockTimestamps() throws {
        let todo = try store.add(title: "Pay taxes", note: "**now**", quadrant: .urgentImportant)
        #expect(todo.title == "Pay taxes")
        #expect(todo.note == "**now**")
        #expect(todo.quadrant == .urgentImportant)
        #expect(todo.createdAt == clock.now)
        #expect(todo.sortDate == clock.now)
        #expect(todo.completedAt == nil)
        #expect(todo.isOpen)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [todo.id])
        #expect(try store.todo(id: todo.id)?.id == todo.id)
    }

    @Test func addTrimsTitle() throws {
        let todo = try store.add(title: "  Call mum \n", note: "", quadrant: .notUrgentImportant)
        #expect(todo.title == "Call mum")
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func addRejectsEmptyTitle(title: String) throws {
        #expect(throws: TodoStoreError.emptyTitle) {
            try store.add(title: title, note: "x", quadrant: .urgentImportant)
        }
        #expect(try store.openTodos(in: .urgentImportant).isEmpty)
        #expect(writes.count == 0)
    }

    @Test func openTodosAreNewestFirstAndFilteredByQuadrant() throws {
        let a = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let b = try store.add(title: "B", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let other = try store.add(title: "Other", note: "", quadrant: .notUrgentUnimportant)
        clock.advance(by: 10)
        let c = try store.add(title: "C", note: "", quadrant: .urgentImportant)

        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [c.id, b.id, a.id])
        #expect(try store.openTodos(in: .notUrgentUnimportant).map(\.id) == [other.id])
        #expect(try store.openTodos(in: .urgentUnimportant).isEmpty)
    }

    // MARK: update

    @Test func updateChangesTitleAndNoteWithoutReordering() throws {
        let a = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let b = try store.add(title: "B", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)

        try store.update(id: a.id, title: " A2 ", note: "- item", quadrant: .urgentImportant)

        let updated = try #require(try store.todo(id: a.id))
        #expect(updated.title == "A2")
        #expect(updated.note == "- item")
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [b.id, a.id])
    }

    @Test func moveToAnotherQuadrantPutsTodoOnTopThere() throws {
        let moved = try store.add(title: "Moved", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let existing = try store.add(title: "Existing", note: "", quadrant: .notUrgentImportant)
        clock.advance(by: 10)

        try store.update(id: moved.id, title: "Moved", note: "", quadrant: .notUrgentImportant)

        #expect(try store.openTodos(in: .urgentImportant).isEmpty)
        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id) == [moved.id, existing.id])
        let todo = try #require(try store.todo(id: moved.id))
        #expect(todo.sortDate == clock.now)
        #expect(todo.createdAt < clock.now)
    }

    // MARK: move (Browse)

    @Test func moveLandsOnTopOfTheNewQuadrantAndReturnsTheOldSortDate() throws {
        let moved = try store.add(title: "Moved", note: "n", quadrant: .urgentImportant)
        let oldSortDate = moved.sortDate
        clock.advance(by: 10)
        let existing = try store.add(title: "Existing", note: "", quadrant: .notUrgentImportant)
        clock.advance(by: 10)
        let writesBefore = writes.count

        let returned = try store.move(id: moved.id, to: .notUrgentImportant)

        #expect(returned == oldSortDate)
        #expect(try store.openTodos(in: .urgentImportant).isEmpty)
        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id) == [moved.id, existing.id])
        let todo = try #require(try store.todo(id: moved.id))
        #expect(todo.sortDate == clock.now)
        #expect(todo.title == "Moved")
        #expect(todo.note == "n")
        #expect(writes.count == writesBefore + 1)
    }

    @Test func moveToTheSameQuadrantDoesNotWrite() throws {
        let todo = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let writesBefore = writes.count
        #expect(try store.move(id: todo.id, to: .urgentImportant) == todo.sortDate)
        #expect(try store.todo(id: todo.id)?.sortDate == todo.sortDate)
        #expect(writes.count == writesBefore)
    }

    @Test func moveBackRestoresTheOldQuadrantAndPosition() throws {
        let top = try store.add(title: "Top", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let middle = try store.add(title: "Middle", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let newest = try store.add(title: "Newest", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let oldSortDate = try store.move(id: middle.id, to: .urgentUnimportant)
        clock.advance(by: 10)

        try store.moveBack(id: middle.id, to: .urgentImportant, sortDate: oldSortDate)

        #expect(try store.openTodos(in: .urgentUnimportant).isEmpty)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [newest.id, middle.id, top.id])
        #expect(try store.todo(id: middle.id)?.sortDate == oldSortDate)
    }

    // MARK: move at a position (Overview drag and drop)

    /// Three todos in `quadrant`, newest first: [c, b, a].
    func three(in quadrant: Quadrant, _ prefix: String) throws -> [Todo] {
        var made: [Todo] = []
        for name in ["a", "b", "c"] {
            made.append(try store.add(title: prefix + name, note: "", quadrant: quadrant))
            clock.advance(by: 10)
        }
        return made.reversed()
    }

    @Test func moveAtIndexLandsAtThatPositionAndReturnsTheOldSortDate() throws {
        let source = try three(in: .urgentImportant, "s")
        let target = try three(in: .notUrgentImportant, "t")
        let moved = source[1]
        let oldSortDate = moved.sortDate
        let writesBefore = writes.count

        let returned = try store.move(id: moved.id, to: .notUrgentImportant, at: 2)

        #expect(returned == oldSortDate)
        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id) == [target[0].id, target[1].id, moved.id, target[2].id])
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [source[0].id, source[2].id])
        #expect(try store.todo(id: moved.id)?.quadrant == .notUrgentImportant)
        #expect(writes.count == writesBefore + 1)
    }

    @Test func moveAtIndexZeroIsOnTopAndPastTheEndIsLast() throws {
        let source = try three(in: .urgentImportant, "s")
        let target = try three(in: .notUrgentImportant, "t")

        try store.move(id: source[2].id, to: .notUrgentImportant, at: 0)
        try store.move(id: source[0].id, to: .notUrgentImportant, at: 99)

        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id)
            == [source[2].id, target[0].id, target[1].id, target[2].id, source[0].id])
    }

    @Test func moveAtIndexIntoAnEmptyQuadrant() throws {
        let source = try three(in: .urgentImportant, "s")
        try store.move(id: source[1].id, to: .notUrgentUnimportant, at: 3)
        #expect(try store.openTodos(in: .notUrgentUnimportant).map(\.id) == [source[1].id])
    }

    @Test func newTodosStillLandOnTopAfterADrop() throws {
        let source = try three(in: .urgentImportant, "s")
        let target = try three(in: .notUrgentImportant, "t")
        try store.move(id: source[0].id, to: .notUrgentImportant, at: 0)
        clock.advance(by: 10)
        let fresh = try store.add(title: "fresh", note: "", quadrant: .notUrgentImportant)
        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id)
            == [fresh.id, source[0].id, target[0].id, target[1].id, target[2].id])
    }

    @Test func moveBackTakesBackAMoveAtIndex() throws {
        let source = try three(in: .urgentImportant, "s")
        let target = try three(in: .notUrgentImportant, "t")
        let oldSortDate = try store.move(id: source[1].id, to: .notUrgentImportant, at: 1)
        clock.advance(by: 10)

        try store.moveBack(id: source[1].id, to: .urgentImportant, sortDate: oldSortDate)

        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == source.map(\.id))
        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id) == target.map(\.id))
    }

    @Test func moveAtIndexWithinItsOwnQuadrantReorders() throws {
        let source = try three(in: .urgentImportant, "s")
        try store.move(id: source[0].id, to: .urgentImportant, at: 2)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [source[1].id, source[2].id, source[0].id])
        let writesBefore = writes.count
        try store.move(id: source[1].id, to: .urgentImportant, at: 0)
        #expect(writes.count == writesBefore, "already there: no write")
    }

    @Test func moveAtIndexWhenTheClockIsBehindTheTopTodoStillKeepsTheOrder() throws {
        let source = try three(in: .urgentImportant, "s")
        let target = try three(in: .notUrgentImportant, "t")
        clock.advance(by: -3600) // now() is older than every sortDate there
        try store.move(id: source[0].id, to: .notUrgentImportant, at: 0)
        try store.move(id: source[1].id, to: .notUrgentImportant, at: 2)
        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id)
            == [source[0].id, target[0].id, source[1].id, target[1].id, target[2].id])
    }

    @Test func moveAtIndexLeavesArchivedTodosInTheTargetAlone() throws {
        let source = try three(in: .urgentImportant, "s")
        let target = try three(in: .notUrgentImportant, "t")
        try store.complete(id: target[1].id)
        let archived = try #require(try store.todo(id: target[1].id))
        let archivedSortDate = archived.sortDate
        let completedAt = archived.completedAt
        try store.move(id: source[0].id, to: .notUrgentImportant, at: 1)
        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id) == [target[0].id, source[0].id, target[2].id])
        let after = try #require(try store.todo(id: target[1].id))
        #expect(after.sortDate == archivedSortDate)
        #expect(after.completedAt == completedAt)
        #expect(after.quadrant == .notUrgentImportant)
    }

    @Test func moveAtANegativeIndexIsTheTop() throws {
        let source = try three(in: .urgentImportant, "s")
        let target = try three(in: .notUrgentImportant, "t")
        try store.move(id: source[2].id, to: .notUrgentImportant, at: -5)
        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id).first == source[2].id)
        #expect(try store.openTodos(in: .notUrgentImportant).count == target.count + 1)
    }

    @Test func reorderPutsBackAnOrderThatMoveAtIndexRewrote() throws {
        let source = try three(in: .urgentImportant, "s")
        let before = source.map(\.id)
        try store.move(id: source[0].id, to: .urgentImportant, at: 2)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) != before)
        try store.reorder(before, in: .urgentImportant)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == before)
    }

    @Test func moveAtIndexOnUnknownIDThrowsNotFound() {
        let id = UUID()
        #expect(throws: TodoStoreError.notFound(id)) { try store.move(id: id, to: .urgentImportant, at: 0) }
    }

    @Test func moveOnUnknownIDThrowsNotFound() {
        let id = UUID()
        #expect(throws: TodoStoreError.notFound(id)) { try store.move(id: id, to: .urgentImportant) }
        #expect(throws: TodoStoreError.notFound(id)) { try store.moveBack(id: id, to: .urgentImportant, sortDate: .now) }
    }

    @Test func updateRejectsEmptyTitleAndKeepsOldValues() throws {
        let todo = try store.add(title: "Keep", note: "n", quadrant: .urgentImportant)
        let writesBefore = writes.count
        #expect(throws: TodoStoreError.emptyTitle) {
            try store.update(id: todo.id, title: "  ", note: "changed", quadrant: .urgentUnimportant)
        }
        let unchanged = try #require(try store.todo(id: todo.id))
        #expect(unchanged.title == "Keep")
        #expect(unchanged.note == "n")
        #expect(unchanged.quadrant == .urgentImportant)
        #expect(writes.count == writesBefore)
    }

    @Test func operationsOnUnknownIDThrowNotFound() {
        let id = UUID()
        #expect(throws: TodoStoreError.notFound(id)) { try store.update(id: id, title: "x", note: "", quadrant: .urgentImportant) }
        #expect(throws: TodoStoreError.notFound(id)) { try store.complete(id: id) }
        #expect(throws: TodoStoreError.notFound(id)) { try store.restore(id: id) }
        #expect(throws: TodoStoreError.notFound(id)) { try store.delete(id: id) }
    }

    // MARK: complete / archive / restore

    @Test func completeHidesFromOpenAndShowsInArchive() throws {
        let todo = try store.add(title: "Done soon", note: "", quadrant: .urgentUnimportant)
        clock.advance(by: 60)
        try store.complete(id: todo.id)

        #expect(try store.openTodos(in: .urgentUnimportant).isEmpty)
        let archived = try store.archivedTodos()
        #expect(archived.map(\.id) == [todo.id])
        #expect(archived.first?.completedAt == clock.now)
        #expect(archived.first?.isOpen == false)
    }

    @Test func archiveIsNewestCompletedFirstAcrossQuadrants() throws {
        let a = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        let b = try store.add(title: "B", note: "", quadrant: .notUrgentUnimportant)
        let c = try store.add(title: "C", note: "", quadrant: .urgentUnimportant)
        _ = try store.add(title: "Open", note: "", quadrant: .urgentImportant)
        try store.complete(id: b.id)
        clock.advance(by: 10)
        try store.complete(id: a.id)
        clock.advance(by: 10)
        try store.complete(id: c.id)

        #expect(try store.archivedTodos().map(\.id) == [c.id, a.id, b.id])
    }

    @Test func restoreReturnsToOriginalQuadrant() throws {
        let todo = try store.add(title: "Oops", note: "", quadrant: .notUrgentImportant)
        try store.complete(id: todo.id)
        clock.advance(by: 3600)
        try store.restore(id: todo.id)

        #expect(try store.archivedTodos().isEmpty)
        #expect(try store.openTodos(in: .notUrgentImportant).map(\.id) == [todo.id])
        #expect(try store.todo(id: todo.id)?.completedAt == nil)
    }

    @Test func restoreBumpsSortDateSoTheTodoReappearsOnTop() throws {
        let old = try store.add(title: "Old", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let newer = try store.add(title: "Newer", note: "", quadrant: .urgentImportant)
        try store.complete(id: old.id)
        clock.advance(by: 10)
        try store.restore(id: old.id)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [old.id, newer.id])
        #expect(try store.todo(id: old.id)?.sortDate == clock.now)
    }

    @Test func restoreNotOnTopKeepsTheOldPosition() throws {
        let old = try store.add(title: "Old", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let newer = try store.add(title: "Newer", note: "", quadrant: .urgentImportant)
        let sortDate = try #require(try store.todo(id: old.id)?.sortDate)
        try store.complete(id: old.id)
        clock.advance(by: 10)
        try store.restore(id: old.id, onTop: false)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [newer.id, old.id])
        #expect(try store.todo(id: old.id)?.sortDate == sortDate)
        #expect(try store.todo(id: old.id)?.completedAt == nil)
    }

    @Test func completeOnArchivedTodoKeepsCompletedAtAndDoesNotWrite() throws {
        let todo = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        try store.complete(id: todo.id)
        let completedAt = try #require(try store.todo(id: todo.id)?.completedAt)
        let before = writes.count
        clock.advance(by: 100)
        try store.complete(id: todo.id)
        #expect(try store.todo(id: todo.id)?.completedAt == completedAt)
        #expect(writes.count == before, "no-op writes don't burn widget reload budget")
    }

    @Test func restoreOnOpenTodoDoesNotWrite() throws {
        let todo = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        let before = writes.count
        try store.restore(id: todo.id)
        #expect(writes.count == before)
    }

    @Test func unchangedUpdateDoesNotWrite() throws {
        let todo = try store.add(title: "A", note: "n", quadrant: .urgentImportant)
        let before = writes.count
        try store.update(id: todo.id, title: " A ", note: "n", quadrant: .urgentImportant)
        #expect(writes.count == before, "saving an untouched edit doesn't reload widgets")
        try store.update(id: todo.id, title: "A", note: "n2", quadrant: .urgentImportant)
        #expect(writes.count == before + 1)
    }

    @Test func purgeThatRemovesSomethingFiresDidWrite() throws {
        let todo = try store.add(title: "Old", note: "", quadrant: .urgentImportant)
        try store.complete(id: todo.id)
        clock.advance(by: 8 * 24 * 60 * 60)
        let before = writes.count
        #expect(try store.purgeArchive() == 1)
        #expect(writes.count == before + 1)
    }

    @Test func deleteRemovesOpenAndArchivedTodos() throws {
        let open = try store.add(title: "Open", note: "", quadrant: .urgentImportant)
        let archived = try store.add(title: "Archived", note: "", quadrant: .urgentImportant)
        try store.complete(id: archived.id)

        try store.delete(id: open.id)
        try store.delete(id: archived.id)

        #expect(try store.openTodos(in: .urgentImportant).isEmpty)
        #expect(try store.archivedTodos().isEmpty)
        #expect(try store.todo(id: open.id) == nil)
    }

    // MARK: purge

    @Test func purgeRemovesExactlyItemsCompletedMoreThanSevenDaysAgo() throws {
        let day: TimeInterval = 24 * 60 * 60
        let tooOld = try store.add(title: "Too old", note: "", quadrant: .urgentImportant)
        try store.complete(id: tooOld.id)          // completed at T
        clock.advance(by: 1)
        let boundary = try store.add(title: "Boundary", note: "", quadrant: .urgentImportant)
        try store.complete(id: boundary.id)        // completed at T+1
        clock.advance(by: 2 * day)
        let recent = try store.add(title: "Recent", note: "", quadrant: .urgentImportant)
        try store.complete(id: recent.id)
        let open = try store.add(title: "Open old", note: "", quadrant: .urgentImportant)

        // now = T + 1 + 7 days: "Boundary" is exactly 7 days old (kept), "Too old" is 7 days + 1s (removed)
        let now = clock.now.addingTimeInterval(-2 * day + 7 * day)
        let removed = try store.purgeArchive(now: now)

        #expect(removed == 1)
        #expect(try store.archivedTodos().map(\.id) == [recent.id, boundary.id])
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [open.id])
    }

    @Test func purgeDefaultsToInjectedClock() throws {
        let todo = try store.add(title: "Old", note: "", quadrant: .urgentImportant)
        try store.complete(id: todo.id)
        clock.advance(by: 7 * 24 * 60 * 60 + 1)
        #expect(try store.purgeArchive() == 1)
        #expect(try store.archivedTodos().isEmpty)
    }

    @Test func purgeUsesTheGivenRetention() throws {
        let day: TimeInterval = 24 * 60 * 60
        let old = try store.add(title: "Old", note: "", quadrant: .urgentImportant)
        try store.complete(id: old.id)             // completed at T
        clock.advance(by: 2 * day)
        let recent = try store.add(title: "Recent", note: "", quadrant: .urgentImportant)
        try store.complete(id: recent.id)          // completed at T + 2 days
        clock.advance(by: day + 1)                 // now = T + 3 days + 1s

        #expect(try store.purgeArchive(retention: ArchiveRetention(days: 30)) == 0)
        #expect(try store.purgeArchive(retention: ArchiveRetention(days: 3)) == 1)
        #expect(try store.archivedTodos().map(\.id) == [recent.id])
        #expect(try store.purgeArchive(retention: ArchiveRetention(days: 1)) == 1)
        #expect(try store.archivedTodos().isEmpty)
    }

    // MARK: didWrite hook

    @Test func didWriteFiresAfterEveryWrite() throws {
        let todo = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        #expect(writes.count == 1)
        try store.update(id: todo.id, title: "B", note: "", quadrant: .urgentImportant)
        #expect(writes.count == 2)
        try store.complete(id: todo.id)
        #expect(writes.count == 3)
        try store.restore(id: todo.id)
        #expect(writes.count == 4)
        try store.delete(id: todo.id)
        #expect(writes.count == 5)
        _ = try store.openTodos(in: .urgentImportant)
        _ = try store.archivedTodos()
        #expect(try store.purgeArchive() == 0)
        #expect(writes.count == 5, "reads and no-op purges don't count as writes")
    }

    // MARK: snapshots

    @Test func openSnapshotsGroupsEveryQuadrantNewestFirst() throws {
        let a = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        clock.advance(by: 1)
        let b = try store.add(title: "B", note: "", quadrant: .urgentImportant)
        let done = try store.add(title: "Done", note: "", quadrant: .urgentUnimportant)
        try store.complete(id: done.id)

        let snapshots = try store.openSnapshots()
        #expect(Set(snapshots.keys) == Set(Quadrant.allCases))
        #expect(snapshots[.urgentImportant] == [
            TodoSnapshot(id: b.id, title: "B", quadrant: .urgentImportant),
            TodoSnapshot(id: a.id, title: "A", quadrant: .urgentImportant),
        ])
        #expect(snapshots[.urgentUnimportant] == [])
    }

    // MARK: on-disk store

    @Test func freshContainerOnSameFileSeesOtherWritersChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "howy-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Howy.store")

        let writer = try TodoStore.onDisk(url: url)
        let todo = try writer.add(title: "From app", note: "", quadrant: .urgentImportant)

        let reader = try TodoStore.onDisk(url: url)
        #expect(try reader.openTodos(in: .urgentImportant).map(\.id) == [todo.id])

        try writer.complete(id: todo.id)
        let freshReader = try TodoStore.onDisk(url: url)
        #expect(try freshReader.openTodos(in: .urgentImportant).isEmpty)
        #expect(try freshReader.archivedTodos().map(\.id) == [todo.id])
    }

    // MARK: reorder

    @Test func reorderPersistsAndNewTodosStillLandOnTop() throws {
        let a = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let b = try store.add(title: "B", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let c = try store.add(title: "C", note: "", quadrant: .urgentImportant)
        let before = writes.count

        try store.reorder([a.id, c.id, b.id], in: .urgentImportant)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [a.id, c.id, b.id])
        #expect(writes.count == before + 1)

        clock.advance(by: 10)
        let d = try store.add(title: "D", note: "", quadrant: .urgentImportant)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [d.id, a.id, c.id, b.id])
    }

    @Test func reorderKeepsUnlistedTodosAfterAndSkipsNoOps() throws {
        let a = try store.add(title: "A", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let b = try store.add(title: "B", note: "", quadrant: .urgentImportant)
        clock.advance(by: 10)
        let c = try store.add(title: "C", note: "", quadrant: .urgentImportant)
        let before = writes.count
        try store.reorder([c.id, b.id, a.id], in: .urgentImportant)
        #expect(writes.count == before)

        try store.reorder([a.id, UUID()], in: .urgentImportant)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [a.id, c.id, b.id])
    }
}
