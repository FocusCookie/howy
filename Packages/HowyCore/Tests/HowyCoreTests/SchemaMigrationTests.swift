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

        try expectBackfill(store, open: open, openQuadrant: .urgentUnimportant, done: done, doneQuadrant: .notUrgentImportant)
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

        try expectBackfill(store, open: open, openQuadrant: .urgentImportant, done: done, doneQuadrant: .notUrgentUnimportant)
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

    private func expectBackfill(
        _ store: TodoStore, open: UUID, openQuadrant: Quadrant, done: UUID, doneQuadrant: Quadrant
    ) throws {
        let openEvents = try store.events(for: open)
        #expect(openEvents.map(\.kind) == [.created])
        #expect(openEvents.first?.date == created)
        #expect(openEvents.first?.toQuadrant == openQuadrant)

        let doneEvents = try store.events(for: done)
        #expect(doneEvents.map(\.kind) == [.created, .completed])
        #expect(doneEvents.map(\.date) == [created, completed])
        #expect(doneEvents.first?.toQuadrant == doneQuadrant)
        #expect(try store.allEvents().count == 3)
    }
}
