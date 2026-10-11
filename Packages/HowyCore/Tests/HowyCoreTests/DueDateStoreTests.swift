import Foundation
import SwiftData
import Testing
@testable import HowyCore

/// Due dates in `TodoStore`: writes, lifecycle and the schema v1 → v2 migration.
@MainActor
@Suite struct DueDateStoreTests {
    let clock = FakeClock()
    let store: TodoStore
    let writes = TodoStoreTests.WriteCounter()

    init() throws {
        let clock = clock
        let writes = writes
        store = try TodoStore.inMemory(now: { clock.now }, didWrite: { writes.count += 1 })
    }

    var inADay: Date { clock.now.addingTimeInterval(86_400) }

    @Test func aNewTodoHasNoDueDate() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        #expect(todo.due == nil)
        #expect(store.snapshot(of: todo).due == nil)
    }

    @Test func addCanCarryADueDate() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        #expect(try store.todo(id: todo.id)?.due == inADay)
    }

    @Test func setDueWritesAndReloadsWidgets() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        writes.count = 0
        try store.setDue(id: todo.id, to: inADay)
        #expect(try store.todo(id: todo.id)?.due == inADay)
        #expect(writes.count == 1)
        try store.setDue(id: todo.id, to: inADay)
        #expect(writes.count == 1, "the same date again writes nothing")
    }

    @Test func clearDueRemovesIt() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        writes.count = 0
        try store.clearDue(id: todo.id)
        #expect(try store.todo(id: todo.id)?.due == nil)
        #expect(writes.count == 1)
    }

    @Test func snoozeByAnIntervalCountsFromNow() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: clock.now)
        clock.advance(by: 600)
        try store.snooze(id: todo.id, by: 3600)
        #expect(try store.todo(id: todo.id)?.due == clock.now.addingTimeInterval(3600))
    }

    @Test func snoozeUntilADate() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: clock.now)
        writes.count = 0
        try store.snooze(id: todo.id, until: inADay)
        #expect(try store.todo(id: todo.id)?.due == inADay)
        #expect(writes.count == 1)
    }

    @Test func setDueOnAMissingTodoThrows() {
        let id = UUID()
        #expect(throws: TodoStoreError.notFound(id)) { try store.setDue(id: id, to: inADay) }
    }

    @Test func dueDatesLeaveQuadrantAndOrderAlone() throws {
        let older = try store.add(title: "A", quadrant: .urgentImportant)
        clock.advance(by: 1)
        let newer = try store.add(title: "B", quadrant: .urgentImportant)
        try store.setDue(id: older.id, to: inADay)
        #expect(try store.openTodos(in: .urgentImportant).map(\.id) == [newer.id, older.id])
        #expect(try store.todo(id: older.id)?.quadrant == .urgentImportant)
    }

    @Test func completeArchiveAndRestoreKeepTheDate() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        try store.complete(id: todo.id)
        #expect(try store.todo(id: todo.id)?.due == inADay)
        try store.restore(id: todo.id)
        #expect(try store.todo(id: todo.id)?.due == inADay)
    }

    @Test func updateKeepsTheDateUnlessGivenOne() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        try store.update(id: todo.id, title: "Pay now", note: "", quadrant: .urgentImportant)
        #expect(try store.todo(id: todo.id)?.due == inADay)
        try store.update(id: todo.id, title: "Pay now", note: "", quadrant: .urgentImportant, due: nil)
        #expect(try store.todo(id: todo.id)?.due == nil)
    }

    @Test func anUpdateThatOnlyChangesTheDateWrites() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant)
        writes.count = 0
        try store.update(id: todo.id, title: "Pay", note: "", quadrant: .urgentImportant, due: inADay)
        #expect(writes.count == 1)
        #expect(try store.todo(id: todo.id)?.due == inADay)
    }

    @Test func snapshotsCarryTheDueDate() throws {
        let todo = try store.add(title: "Pay", quadrant: .urgentImportant, due: inADay)
        #expect(try store.openSnapshots()[.urgentImportant]?.first?.due == inADay)
        #expect(store.snapshot(of: todo).dueState(at: clock.now) == .upcoming)
    }

    @Test func openDueSnapshotsAreOpenDatedTodosEarliestFirst() throws {
        let later = try store.add(title: "Later", quadrant: .urgentImportant, due: inADay)
        let sooner = try store.add(title: "Sooner", quadrant: .notUrgentImportant, due: clock.now.addingTimeInterval(60))
        _ = try store.add(title: "Undated", quadrant: .urgentImportant)
        let done = try store.add(title: "Done", quadrant: .urgentImportant, due: inADay)
        try store.complete(id: done.id)
        #expect(try store.openDueSnapshots().map(\.id) == [sooner.id, later.id])
    }

    // MARK: Migration

    @Test func aVersionOneStoreOpensUnderVersionTwoWithItsDataIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "howy-v1-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Howy.store")
        let id = UUID()
        let created = Date(timeIntervalSinceReferenceDate: 790_000_000)
        do {
            let schema = Schema(versionedSchema: HowySchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            container.mainContext.insert(HowySchemaV1.Todo(
                id: id, title: "Old todo", note: "kept", quadrantRaw: Quadrant.urgentUnimportant.rawValue,
                createdAt: created, sortDate: created, completedAt: nil
            ))
            try container.mainContext.save()
        }

        let migrated = try TodoStore.onDisk(url: url, now: { [clock] in clock.now })
        let todo = try #require(try migrated.todo(id: id))
        #expect(todo.title == "Old todo")
        #expect(todo.note == "kept")
        #expect(todo.quadrant == .urgentUnimportant)
        #expect(todo.createdAt == created)
        #expect(todo.completedAt == nil)
        #expect(todo.due == nil)
        try migrated.setDue(id: id, to: inADay)
        let reopened = try TodoStore.onDisk(url: url)
        #expect(try reopened.todo(id: id)?.due == inADay)
    }
}
