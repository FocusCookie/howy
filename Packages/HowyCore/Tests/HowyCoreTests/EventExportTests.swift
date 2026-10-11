import Foundation
import Testing
@testable import HowyCore

/// Export and import of the event log (format v2), and reading version 1 files.
@MainActor
@Suite final class EventExportTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "howy-events-\(UUID().uuidString)", directoryHint: .isDirectory)
    let clock = FakeClock()

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    var exportFolder: URL { base.appending(path: "Export", directoryHint: .isDirectory) }

    func makeStore() throws -> (TodoStore, TodoStoreTests.WriteCounter) {
        let clock = clock
        let writes = TodoStoreTests.WriteCounter()
        let store = try TodoStore.inMemory(now: { clock.now }, didWrite: { writes.count += 1 })
        return (store, writes)
    }

    /// A store whose history has every kind: moves, due changes, a snooze, a tick, a restore,
    /// and a deleted todo.
    func storeWithHistory() throws -> TodoStore {
        let (store, _) = try makeStore()
        let a = try store.add(title: "Taxes", quadrant: .urgentImportant)
        clock.advance(by: 10)
        try store.move(id: a.id, to: .notUrgentImportant)
        try store.setDue(id: a.id, to: clock.now.addingTimeInterval(3600))
        clock.advance(by: 10)
        try store.snooze(id: a.id, by: 600)
        try store.complete(id: a.id)
        clock.advance(by: 10)
        try store.restore(id: a.id)
        let b = try store.add(title: "Dentist", quadrant: .urgentUnimportant, due: clock.now.addingTimeInterval(60))
        clock.advance(by: 10)
        try store.complete(id: b.id)
        let c = try store.add(title: "Gone", quadrant: .notUrgentUnimportant)
        clock.advance(by: 10)
        try store.delete(id: c.id)
        return store
    }

    func importFolder(json: String) throws -> URL {
        let folder = base.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: HowyFormat.fileName))
        return folder
    }

    func importAll(_ folder: URL, into store: TodoStore) async throws -> ImportReport {
        let importer = HowyImporter(store: store)
        return try await importer.apply(try importer.analyze(folder: folder))
    }

    func sorted(_ events: [TodoEvent]) -> [TodoEventRecord] {
        events.map(\.record).sorted { ($0.date, $0.seq, $0.id.uuidString) < ($1.date, $1.seq, $1.id.uuidString) }
    }

    // MARK: Export

    @Test func exportWritesTheHistory() async throws {
        let store = try storeWithHistory()
        _ = try await HowyExporter(store: store).export(to: exportFolder)
        let json = String(decoding: try Data(contentsOf: exportFolder.appending(path: HowyFormat.fileName)), as: UTF8.self)
        #expect(json.contains(#""formatVersion" : 2"#))
        #expect(json.contains(#""events" : ["#))
        #expect(json.contains(#""kind" : "moved""#))
        #expect(json.contains(#""fromQuadrant" : "urgent-important""#))
        #expect(json.contains(#""toQuadrant" : "not-urgent-important""#))
        #expect(json.contains(#""kind" : "dueSnoozed""#))
        #expect(json.contains(#""kind" : "deleted""#))
        #expect(!json.contains("Gone"), "events never carry titles")
    }

    // MARK: Round trip

    @Test func roundTripKeepsEveryEventAsIs() async throws {
        let source = try storeWithHistory()
        _ = try await HowyExporter(store: source).export(to: exportFolder)
        let (target, writes) = try makeStore()
        clock.advance(by: 3600)

        let summary = try await importAll(exportFolder, into: target)

        #expect(summary == ImportReport(importCount: 2))
        #expect(writes.count == 1)
        #expect(try target.allTodos().map(\.record) == source.allTodos().map(\.record))
        #expect(sorted(try target.allEvents()) == sorted(try source.allEvents()), "nothing made up, the deleted todo's history included")
    }

    @Test func importingTheSameFileTwiceAddsNothing() async throws {
        _ = try await HowyExporter(store: try storeWithHistory()).export(to: exportFolder)
        let (target, writes) = try makeStore()
        _ = try await importAll(exportFolder, into: target)
        let todos = try target.allTodos().map(\.record)
        let events = sorted(try target.allEvents())

        let again = try await importAll(exportFolder, into: target)

        #expect(again == ImportReport(duplicateCount: 2))
        #expect(writes.count == 1, "the second import wrote nothing")
        #expect(try target.allTodos().map(\.record) == todos)
        #expect(sorted(try target.allEvents()) == events)
    }

    @Test func eventsOfTodosThatAlreadyExistAreSkipped() async throws {
        let (target, _) = try makeStore()
        let mine = try target.add(title: "Mine", quadrant: .urgentImportant)
        let mineEvents = sorted(try target.events(for: mine.id))
        let theirs = UUID()
        let json = """
        { "formatVersion": 2,
          "todos": [
            { "id": "\(mine.id)", "title": "Theirs", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" },
            { "id": "\(theirs)", "title": "New", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" }
          ],
          "events": [
            { "id": "\(UUID())", "todoID": "\(mine.id)", "kind": "created", "date": "2026-10-01T08:00:00Z", "seq": 0, "toQuadrant": "urgent-important" },
            { "id": "\(UUID())", "todoID": "\(mine.id)", "kind": "completed", "date": "2026-10-02T08:00:00Z", "seq": 1 },
            { "id": "\(UUID())", "todoID": "\(theirs)", "kind": "created", "date": "2026-10-01T08:00:00Z", "seq": 0, "toQuadrant": "urgent-important" }
          ] }
        """

        let summary = try await importAll(try importFolder(json: json), into: target)

        #expect(summary == ImportReport(importCount: 1, duplicateCount: 1))
        #expect(sorted(try target.events(for: mine.id)) == mineEvents)
        #expect(try target.events(for: theirs).compactMap(\.kind) == [.created])
    }

    @Test func eventsWhoseIDExistsAreSkipped() async throws {
        let (target, _) = try makeStore()
        let mine = try target.add(title: "Mine", quadrant: .urgentImportant)
        let existing = try #require(try target.events(for: mine.id).first)
        let newTodo = UUID()
        let json = """
        { "formatVersion": 2,
          "todos": [{ "id": "\(newTodo)", "title": "New", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" }],
          "events": [
            { "id": "\(existing.id)", "todoID": "\(newTodo)", "kind": "created", "date": "2026-10-01T08:00:00Z" },
            { "id": "\(existing.id)", "todoID": "\(newTodo)", "kind": "completed", "date": "2026-10-01T09:00:00Z" }
          ] }
        """

        _ = try await importAll(try importFolder(json: json), into: target)

        #expect(try target.allEvents().filter { $0.id == existing.id }.count == 1)
        #expect(try target.events(for: newTodo).isEmpty, "the file's history for it was taken as given")
    }

    // MARK: Version 1 files

    @Test func aVersion1FileGetsMadeUpEvents() async throws {
        let (target, _) = try makeStore()
        let open = UUID()
        let done = UUID()
        let json = """
        { "formatVersion": 1, "todos": [
          { "id": "\(open)", "title": "Open", "quadrant": "urgent-unimportant", "createdAt": "2026-10-01T08:00:00Z", "due": "2026-10-05T08:00:00Z" },
          { "id": "\(done)", "title": "Done", "quadrant": "urgent-important", "createdAt": "2026-09-01T08:00:00Z", "completedAt": "2026-09-02T08:00:00Z" }
        ] }
        """

        let summary = try await importAll(try importFolder(json: json), into: target)

        #expect(summary == ImportReport(importCount: 2))
        let created = try #require(try target.events(for: open).first)
        #expect(created.kind == .created)
        #expect(created.toQuadrant == .urgentUnimportant)
        #expect(created.date == HowyFormat.date(from: "2026-10-01T08:00:00Z"))
        #expect(created.due == HowyFormat.date(from: "2026-10-05T08:00:00Z"))
        let history = try target.events(for: done)
        #expect(history.compactMap(\.kind) == [.created, .completed])
        #expect(history.last?.date == HowyFormat.date(from: "2026-09-02T08:00:00Z"))
    }

    @Test func aTodoWithoutEventsInAVersion2FileGetsMadeUpEvents() async throws {
        let (target, _) = try makeStore()
        let logged = UUID()
        let unlogged = UUID()
        let json = """
        { "formatVersion": 2,
          "todos": [
            { "id": "\(logged)", "title": "Logged", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" },
            { "id": "\(unlogged)", "title": "Unlogged", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" }
          ],
          "events": [{ "id": "\(UUID())", "todoID": "\(logged)", "kind": "moved", "date": "2026-10-03T08:00:00Z", "seq": 4,
                       "fromQuadrant": "urgent-unimportant", "toQuadrant": "urgent-important" }] }
        """

        _ = try await importAll(try importFolder(json: json), into: target)

        let moved = try target.events(for: logged)
        #expect(moved.compactMap(\.kind) == [.moved], "taken as given, nothing made up")
        #expect(moved.first?.seq == 4)
        #expect(moved.first?.fromQuadrant == .urgentUnimportant)
        #expect(try target.events(for: unlogged).compactMap(\.kind) == [.created])
    }

    // MARK: Invalid and unknown events

    @Test func invalidEventsAreSkippedAndReportedUnknownKindsKept() async throws {
        let (target, _) = try makeStore()
        let todo = UUID()
        let future = UUID()
        let json = """
        { "formatVersion": 2,
          "todos": [{ "id": "\(todo)", "title": "T", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" }],
          "events": [
            { "id": "\(UUID())", "todoID": "\(todo)", "kind": "created", "date": "2026-10-01T08:00:00Z" },
            { "todoID": "\(todo)", "kind": "completed", "date": "2026-10-01T08:00:00Z" },
            { "id": "\(UUID())", "todoID": "\(todo)", "kind": "moved", "date": "soon" },
            { "id": "\(UUID())", "todoID": "\(todo)", "kind": "moved", "date": "2026-10-01T09:00:00Z", "toQuadrant": "later" },
            { "id": "\(future)", "todoID": "\(todo)", "kind": "pinned", "date": "2026-10-01T10:00:00Z", "seq": 2 }
          ] }
        """
        let importer = HowyImporter(store: target)
        let plan = try importer.analyze(folder: try importFolder(json: json))
        #expect(plan.report.importCount == 1)
        #expect(plan.report.invalidCount == 0)
        #expect(plan.report.problems == [
            "History entry #2: missing id",
            #"History entry #3: invalid date "soon""#,
            #"History entry #4: unknown toQuadrant "later""#,
        ])

        _ = try await importer.apply(plan)

        let history = try target.events(for: todo)
        #expect(history.map(\.kindRaw) == ["created", "pinned"])
        #expect(history.last?.id == future)
        #expect(history.last?.kind == nil)
    }
}
