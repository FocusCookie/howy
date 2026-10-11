import Foundation
import SwiftData
import Testing
@testable import HowyCore

/// A deleted todo that comes back (a twin or a late write from another Mac, arriving after the
/// delete) is removed again, by a rule every device applies alike: a row whose `updatedAt` is at
/// or before the newest `deleted` event of its id goes.
@MainActor
@Suite final class DeletedTodoTests {
    let clock = FakeClock()
    let writes = TodoStoreTests.WriteCounter()
    let store: TodoStore

    init() throws {
        let clock = clock
        let writes = writes
        store = try TodoStore.inMemory(now: { clock.now }, didWrite: { writes.count += 1 })
    }

    /// Inserts a row as another Mac's record would arrive.
    func arrive(_ todo: Todo) throws {
        store.context.insert(SyncSafeDuplicateTests.copy(of: todo))
        try store.context.save()
    }

    @Test func aTwinArrivingAfterTheDeleteIsRemoved() async throws {
        let todo = try store.add(title: "Gone", quadrant: .urgentImportant)
        let copy = SyncSafeDuplicateTests.copy(of: todo)
        clock.advance(by: 10)
        try store.delete(id: todo.id)
        try arrive(copy)
        #expect(try store.todo(id: todo.id) != nil, "back, until the cleanup")
        let before = writes.count

        let removed = try await store.removeDeletedTodos()

        #expect(removed == [todo.id])
        #expect(try store.todos(id: todo.id).isEmpty)
        #expect(writes.count == before + 1)
        #expect(try store.events(for: todo.id).last?.kind == .deleted, "the history stays")
    }

    @Test func aWriteAtTheSameMillisecondAsTheDeleteIsRemoved() async throws {
        let todo = try store.add(title: "Same moment", quadrant: .urgentImportant)
        try store.delete(id: todo.id)
        try arrive(todo)
        #expect(try await store.removeDeletedTodos() == [todo.id])
    }

    @Test func anEditMadeAfterTheDeleteKeepsTheTodo() async throws {
        let todo = try store.add(title: "Edited elsewhere", quadrant: .urgentImportant)
        let elsewhere = SyncSafeDuplicateTests.copy(of: todo)
        clock.advance(by: 10)
        try store.delete(id: todo.id)
        elsewhere.title = "Edited later"
        elsewhere.updatedAt = clock.now.addingTimeInterval(5).wholeMilliseconds
        try arrive(elsewhere)

        #expect(try await store.removeDeletedTodos().isEmpty)
        #expect(try store.todo(id: todo.id)?.title == "Edited later")
    }

    @Test func reImportingABackupWithADeletedTodoKeepsIt() async throws {
        let todo = try store.add(title: "In the backup", quadrant: .urgentImportant)
        let record = todo.record
        clock.advance(by: 60)
        try store.delete(id: todo.id)
        clock.advance(by: 60)

        let inserted = try store.insert([record])

        #expect(inserted == [todo.id], "the import stamps updatedAt with the clock's now")
        #expect(try await store.removeDeletedTodos().isEmpty)
        #expect(try store.todo(id: todo.id)?.title == "In the backup")
    }

    @Test func todosWithoutADeleteAreLeftAlone() async throws {
        try store.add(title: "Kept", quadrant: .urgentImportant)
        let before = writes.count
        #expect(try await store.removeDeletedTodos().isEmpty)
        #expect(try store.allTodos().count == 1)
        #expect(writes.count == before, "nothing written")
    }

    @Test func theNewestDeleteCounts() async throws {
        // Deleted, imported again (newer than the first delete), deleted again: the late twin of
        // the imported row is older than the second delete.
        let todo = try store.add(title: "Twice", quadrant: .urgentImportant)
        clock.advance(by: 10)
        try store.delete(id: todo.id)
        clock.advance(by: 10)
        try store.insert([todo.record])
        let imported = try #require(try store.todo(id: todo.id))
        let twin = SyncSafeDuplicateTests.copy(of: imported)
        clock.advance(by: 10)
        try store.delete(id: todo.id)
        try arrive(twin)

        #expect(try await store.removeDeletedTodos() == [todo.id])
    }
}
