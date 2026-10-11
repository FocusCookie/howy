import Foundation
import SwiftData
import Testing
@testable import HowyCore

/// Older on-disk stores open under the current schema (v3) with their data intact, and the
/// migration backfills the event log once.
@MainActor
@Suite struct SchemaMigrationTests {
    let created = Date(timeIntervalSinceReferenceDate: 790_000_000)
    var sorted: Date { created.addingTimeInterval(60) }
    var completed: Date { created.addingTimeInterval(3_600) }
    var due: Date { created.addingTimeInterval(86_400) }

    /// A fresh store URL in its own temporary directory; the directory is removed by `cleanup`.
    func makeStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "howy-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Howy.store")
    }

    func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func aVersionOneStoreOpensUnderVersionThreeWithItsDataAndBackfilledEvents() throws {
        let url = try makeStoreURL()
        defer { cleanup(url) }
        let open = UUID()
        let done = UUID()
        do {
            let schema = Schema(versionedSchema: HowySchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            container.mainContext.insert(HowySchemaV1.Todo(
                id: open, title: "Open", note: "kept", quadrantRaw: Quadrant.urgentUnimportant.rawValue,
                createdAt: created, sortDate: sorted, completedAt: nil
            ))
            container.mainContext.insert(HowySchemaV1.Todo(
                id: done, title: "Done", note: "", quadrantRaw: Quadrant.notUrgentImportant.rawValue,
                createdAt: created, sortDate: created, completedAt: completed
            ))
            try container.mainContext.save()
        }

        do {
            let store = try TodoStore.onDisk(url: url)
            let openTodo = try #require(try store.todo(id: open))
            #expect(openTodo.title == "Open")
            #expect(openTodo.note == "kept")
            #expect(openTodo.quadrant == .urgentUnimportant)
            #expect(openTodo.createdAt == created)
            #expect(openTodo.sortDate == sorted)
            #expect(openTodo.completedAt == nil)
            #expect(openTodo.due == nil)
            #expect(openTodo.updatedAt == sorted)
            #expect(try store.todo(id: done)?.completedAt == completed)
            #expect(try store.todo(id: done)?.updatedAt == completed)

            try expectBackfill(store, open: open, openQuadrant: .urgentUnimportant, openDue: nil, done: done, doneQuadrant: .notUrgentImportant)
        }
    }

    @Test func aVersionTwoStoreOpensUnderVersionThreeWithItsDataAndBackfilledEvents() throws {
        let url = try makeStoreURL()
        defer { cleanup(url) }
        let open = UUID()
        let done = UUID()
        do {
            let schema = Schema(versionedSchema: HowySchemaV2.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: nil, configurations: ModelConfiguration(schema: schema, url: url)
            )
            container.mainContext.insert(HowySchemaV2.Todo(
                id: open, title: "Open", note: "kept", quadrant: .urgentImportant,
                createdAt: created, sortDate: sorted, completedAt: nil, due: due
            ))
            container.mainContext.insert(HowySchemaV2.Todo(
                id: done, title: "Done", note: "", quadrant: .notUrgentUnimportant,
                createdAt: created, sortDate: created, completedAt: completed, due: nil
            ))
            try container.mainContext.save()
        }

        do {
            let store = try TodoStore.onDisk(url: url)
            let openTodo = try #require(try store.todo(id: open))
            #expect(openTodo.title == "Open")
            #expect(openTodo.note == "kept")
            #expect(openTodo.quadrant == .urgentImportant)
            #expect(openTodo.createdAt == created)
            #expect(openTodo.sortDate == sorted)
            #expect(openTodo.due == due)
            #expect(openTodo.updatedAt == sorted)
            let doneTodo = try #require(try store.todo(id: done))
            #expect(doneTodo.completedAt == completed)
            #expect(doneTodo.due == nil)
            #expect(doneTodo.updatedAt == completed)

            try expectBackfill(store, open: open, openQuadrant: .urgentImportant, openDue: due, done: done, doneQuadrant: .notUrgentUnimportant)
        }
    }

    @Test func reopeningAMigratedStoreDoesNotBackfillAgain() throws {
        let url = try makeStoreURL()
        defer { cleanup(url) }
        let id = UUID()
        do {
            let schema = Schema(versionedSchema: HowySchemaV2.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: nil, configurations: ModelConfiguration(schema: schema, url: url)
            )
            container.mainContext.insert(HowySchemaV2.Todo(
                id: id, title: "Done", note: "", quadrant: .urgentImportant,
                createdAt: created, sortDate: created, completedAt: completed, due: nil
            ))
            try container.mainContext.save()
        }

        do {
            let first = try TodoStore.onDisk(url: url)
            #expect(try first.allEvents().count == 2)
        }
        let second = try TodoStore.onDisk(url: url)
        #expect(try second.allEvents().count == 2)
        #expect(try second.allTodos().count == 1)
    }

    @Test func aMigratedStoreKeepsWorking() throws {
        let url = try makeStoreURL()
        defer { cleanup(url) }
        let id = UUID()
        do {
            let schema = Schema(versionedSchema: HowySchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            container.mainContext.insert(HowySchemaV1.Todo(
                id: id, title: "Old", note: "", quadrantRaw: Quadrant.urgentImportant.rawValue,
                createdAt: created, sortDate: created, completedAt: nil
            ))
            try container.mainContext.save()
        }

        let clock = FakeClock()
        do {
            let store = try TodoStore.onDisk(url: url, now: { clock.now })
            try store.setDue(id: id, to: due)
            clock.advance(by: 60)
            try store.complete(id: id)
        }
        let reopened = try TodoStore.onDisk(url: url)
        #expect(try reopened.todo(id: id)?.due == due)
        #expect(try reopened.todo(id: id)?.updatedAt == clock.now)
        #expect(try reopened.events(for: id).map(\.kind) == [.created, .dueSet, .completed])
    }

    /// Writes a v1 store with `count` todos; every other one is archived. Returns their ids.
    func writeV1Store(at url: URL, count: Int) throws -> [UUID] {
        let schema = Schema(versionedSchema: HowySchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let ids = (0..<count).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            container.mainContext.insert(HowySchemaV1.Todo(
                id: id, title: "Todo \(index)", note: "", quadrantRaw: Quadrant.urgentImportant.rawValue,
                createdAt: created, sortDate: created, completedAt: index.isMultiple(of: 2) ? nil : completed
            ))
        }
        try container.mainContext.save()
        return ids
    }

    /// Writes a v2 store with `count` todos; every other one is archived. Returns their ids.
    func writeV2Store(at url: URL, count: Int) throws -> [UUID] {
        let schema = Schema(versionedSchema: HowySchemaV2.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: nil, configurations: ModelConfiguration(schema: schema, url: url)
        )
        let ids = (0..<count).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            container.mainContext.insert(HowySchemaV2.Todo(
                id: id, title: "Todo \(index)", note: "", quadrant: .urgentImportant,
                createdAt: created, sortDate: created, completedAt: index.isMultiple(of: 2) ? nil : completed, due: due
            ))
        }
        try container.mainContext.save()
        return ids
    }

    func createdCounts(_ store: TodoStore, ids: [UUID]) throws -> [Int] {
        try ids.map { id in try store.events(for: id).filter { $0.kind == .created }.count }
    }

    @Test func reopeningAVersionOneStoreKeepsTheEventCountWithOneCreatedPerTodo() throws {
        let url = try makeStoreURL()
        defer { cleanup(url) }
        let ids = try writeV1Store(at: url, count: 4) // 2 open, 2 archived: 4 created + 2 completed
        for _ in 0..<3 {
            let store = try TodoStore.onDisk(url: url)
            #expect(try store.allEvents().count == 6)
            #expect(try createdCounts(store, ids: ids) == [1, 1, 1, 1])
        }
    }

    @Test func aVersionTwoStoreWithSeveralTodosKeepsItsCountsAcrossNewWrites() throws {
        let url = try makeStoreURL()
        defer { cleanup(url) }
        let ids = try writeV2Store(at: url, count: 3) // 2 open, 1 archived: 3 created + 1 completed
        let clock = FakeClock()
        do {
            let store = try TodoStore.onDisk(url: url, now: { clock.now })
            #expect(try store.allEvents().count == 4)
            try store.add(title: "New", quadrant: .urgentImportant)
            try store.complete(id: ids[0])
            #expect(try store.allEvents().count == 6)
        }
        let reopened = try TodoStore.onDisk(url: url, now: { clock.now })
        #expect(try reopened.allEvents().count == 6)
        #expect(try reopened.allTodos().count == 4)
        #expect(try createdCounts(reopened, ids: ids) == [1, 1, 1])
    }

    @Test func anEmptyVersionTwoStoreGetsNoSpuriousBackfillEvents() throws {
        let url = try makeStoreURL()
        defer { cleanup(url) }
        _ = try writeV2Store(at: url, count: 0)
        let id: UUID
        do {
            let store = try TodoStore.onDisk(url: url)
            #expect(try store.allEvents().isEmpty)
            id = try store.add(title: "First", quadrant: .urgentImportant).id
        }
        let reopened = try TodoStore.onDisk(url: url)
        #expect(try reopened.allEvents().map(\.kind) == [.created])
        #expect(try reopened.events(for: id).count == 1)
    }

    @Test func aStoreWithTodosButNoEventsBackfillsWhenOpenedAndOnlyOnce() throws {
        let url = try makeStoreURL()
        defer { cleanup(url) }
        let open = UUID()
        let done = UUID()
        do {
            // A v3 store whose migration backfill never ran: todos written without events.
            let store = try TodoStore.onDisk(url: url)
            store.context.insert(Todo(
                id: open, title: "Open", quadrant: .urgentImportant, createdAt: created, sortDate: sorted, due: due
            ))
            store.context.insert(Todo(
                id: done, title: "Done", quadrant: .notUrgentImportant, createdAt: created, completedAt: completed
            ))
            try store.context.save()
            #expect(try store.allEvents().isEmpty)
        }
        for _ in 0..<2 {
            let store = try TodoStore.onDisk(url: url)
            #expect(try store.allEvents().count == 3)
            try expectBackfill(store, open: open, openQuadrant: .urgentImportant, openDue: due, done: done, doneQuadrant: .notUrgentImportant)
        }
    }

    @Test func backfilledEventsHaveDeterministicIds() throws {
        let todo = UUID()
        let created = TodoEvent.backfillID(todoID: todo, kind: .created)
        #expect(created == TodoEvent.backfillID(todoID: todo, kind: .created))
        #expect(created != TodoEvent.backfillID(todoID: todo, kind: .completed))
        #expect(created != TodoEvent.backfillID(todoID: UUID(), kind: .created))
        #expect(created.uuidString.dropFirst(14).first == "5") // a version 5 (name-based) UUID

        let url = try makeStoreURL()
        defer { cleanup(url) }
        let id = try writeV2Store(at: url, count: 2)[1]
        let store = try TodoStore.onDisk(url: url)
        let events = try store.events(for: id)
        #expect(events.map(\.id) == [
            TodoEvent.backfillID(todoID: id, kind: .created), TodoEvent.backfillID(todoID: id, kind: .completed),
        ])
    }

    private func expectBackfill(
        _ store: TodoStore, open: UUID, openQuadrant: Quadrant, openDue: Date?, done: UUID, doneQuadrant: Quadrant
    ) throws {
        let openEvents = try store.events(for: open)
        #expect(openEvents.map(\.kind) == [.created])
        #expect(openEvents.first?.date == created)
        #expect(openEvents.first?.toQuadrant == openQuadrant)
        #expect(openEvents.first?.due == openDue) // the due date at migration time
        #expect(openEvents.first?.seq == 0)

        let doneEvents = try store.events(for: done)
        #expect(doneEvents.map(\.kind) == [.created, .completed])
        #expect(doneEvents.map(\.date) == [created, completed])
        #expect(doneEvents.first?.toQuadrant == doneQuadrant)
        #expect(doneEvents.first?.due == nil)
        #expect(doneEvents.map(\.seq) == [0, 1])
        #expect(try store.allEvents().count == 3)
    }
}
