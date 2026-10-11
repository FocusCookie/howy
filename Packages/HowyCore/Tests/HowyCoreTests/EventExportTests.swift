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

        #expect(summary == ImportReport(importCount: 2, importedEventCount: try source.allEvents().count))
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

        #expect(again == ImportReport(duplicateCount: 2, skippedEventCount: events.count))
        #expect(writes.count == 1, "the second import wrote nothing")
        #expect(try target.allTodos().map(\.record) == todos)
        #expect(sorted(try target.allEvents()) == events)
    }

    @Test func eventsOfTodosThatAlreadyExistAreImportedByID() async throws {
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
            { "id": "\(mineEvents[0].id)", "todoID": "\(mine.id)", "kind": "created", "date": "2026-10-01T08:00:00Z", "seq": 0, "toQuadrant": "urgent-important" },
            { "id": "\(UUID())", "todoID": "\(mine.id)", "kind": "moved", "date": "2026-10-01T09:00:00Z", "seq": 1, "fromQuadrant": "urgent-important", "toQuadrant": "urgent-unimportant" },
            { "id": "\(UUID())", "todoID": "\(mine.id)", "kind": "completed", "date": "2026-10-02T08:00:00Z", "seq": 2 },
            { "id": "\(UUID())", "todoID": "\(theirs)", "kind": "created", "date": "2026-10-01T08:00:00Z", "seq": 0, "toQuadrant": "urgent-important" }
          ] }
        """
        let folder = try importFolder(json: json)

        let summary = try await importAll(folder, into: target)

        #expect(summary == ImportReport(importCount: 1, duplicateCount: 1, importedEventCount: 3, skippedEventCount: 1))
        let history = try target.events(for: mine.id)
        #expect(history.compactMap(\.kind) == [.created, .moved, .completed], "the file's new events join the todo's history")
        #expect(history.first?.id == mineEvents[0].id)
        #expect(try target.todo(id: mine.id)?.title == "Mine", "the todo itself never changes")
        #expect(try target.events(for: theirs).compactMap(\.kind) == [.created])

        let again = try await importAll(folder, into: target)
        #expect(again == ImportReport(duplicateCount: 2, skippedEventCount: 4), "idempotent by event id")
        #expect(try target.allEvents().count == 4)
    }

    @Test func aVersion2FileWithoutEventsGetsAProblemLine() throws {
        let (target, _) = try makeStore()
        let todo = UUID()
        let two = """
        { "formatVersion": 2, "todos": [{ "id": "\(todo)", "title": "T", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" }] }
        """
        let one = two.replacingOccurrences(of: "\"formatVersion\": 2", with: "\"formatVersion\": 1")

        let plan = try HowyImporter(store: target).analyze(folder: try importFolder(json: two))
        #expect(plan.report.problems == ["History: no history in this file"])
        let old = try HowyImporter(store: target).analyze(folder: try importFolder(json: one))
        #expect(old.report.problems.isEmpty, "version 1 files never had history")
    }

    @Test func aBadOptionalFieldKeepsTheEventAndDropsTheField() async throws {
        let (target, _) = try makeStore()
        let todo = UUID()
        let ids = (0..<6).map { _ in UUID() }
        let json = """
        { "formatVersion": 2,
          "todos": [{ "id": "\(todo)", "title": "T", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" }],
          "events": [
            { "id": "\(ids[0])", "todoID": "\(todo)", "kind": "moved", "date": "2026-10-01T09:00:00Z", "fromQuadrant": "x", "toQuadrant": "urgent-unimportant" },
            { "id": "\(ids[1])", "todoID": "\(todo)", "kind": "moved", "date": "2026-10-01T09:01:00Z", "fromQuadrant": "urgent-unimportant", "toQuadrant": 5 },
            { "id": "\(ids[2])", "todoID": "\(todo)", "kind": "dueChanged", "date": "2026-10-01T09:02:00Z", "previousDue": "soon", "due": "2026-10-09T08:00:00Z" },
            { "id": "\(ids[3])", "todoID": "\(todo)", "kind": "dueChanged", "date": "2026-10-01T09:03:00Z", "previousDue": "2026-10-09T08:00:00Z", "due": "later" },
            { "id": "\(ids[4])", "todoID": "\(todo)", "kind": "completed", "date": "2026-10-01T09:04:00Z", "seq": "two" },
            { "id": "\(ids[5])", "todoID": "\(todo)", "kind": "completed", "date": "yesterday" }
          ] }
        """
        let importer = HowyImporter(store: target)
        let plan = try importer.analyze(folder: try importFolder(json: json))

        #expect(plan.report.importedEventCount == 5)
        #expect(plan.report.invalidEventCount == 1)
        #expect(plan.report.problems == [
            #"History entry #1: unknown fromQuadrant "x" (ignored)"#,
            "History entry #2: invalid toQuadrant (ignored)",
            #"History entry #3: invalid previousDue "soon" (ignored)"#,
            #"History entry #4: invalid due "later" (ignored)"#,
            "History entry #5: invalid seq (ignored)",
            #"History entry #6: invalid date "yesterday""#,
        ])
        let summary = try await importer.apply(plan)
        #expect(summary.importedEventCount == 5)

        let events = Dictionary(uniqueKeysWithValues: try target.events(for: todo).map { ($0.id, $0) })
        #expect(events.count == 5)
        #expect(events[ids[0]]?.fromQuadrant == nil && events[ids[0]]?.toQuadrant == .urgentUnimportant)
        #expect(events[ids[1]]?.fromQuadrant == .urgentUnimportant && events[ids[1]]?.toQuadrant == nil)
        #expect(events[ids[1]]?.kind == .moved)
        #expect(events[ids[2]]?.previousDue == nil && events[ids[2]]?.due == HowyFormat.date(from: "2026-10-09T08:00:00Z"))
        #expect(events[ids[3]]?.due == nil && events[ids[3]]?.previousDue != nil)
        #expect(events[ids[4]]?.seq == 0 && events[ids[4]]?.kind == .completed)
        #expect(events[ids[4]]?.date == HowyFormat.date(from: "2026-10-01T09:04:00Z"))
        #expect(events[ids[5]] == nil)
    }

    @Test func subSecondDatesRoundTripExactlyThroughExportAndImport() async throws {
        // Random fractional dates (a fixed seed, so a failure reproduces) in todos and events.
        var generator = SeededGenerator(seed: 0x4E4F_5744)
        func randomDate() -> Date {
            Date(timeIntervalSinceReferenceDate: Double.random(in: 700_000_000..<900_000_000, using: &generator))
        }
        let source = try TodoStore.inMemory()
        var records: [TodoRecord] = []
        var events: [TodoEventRecord] = []
        for _ in 0..<12 {
            let id = UUID()
            let created = randomDate()
            records.append(TodoRecord(
                id: id, title: "T", note: "", quadrant: .urgentImportant, createdAt: created,
                sortDate: randomDate(), completedAt: Bool.random(using: &generator) ? randomDate() : nil, due: randomDate()
            ))
            events.append(TodoEventRecord(
                id: UUID(), todoID: id, kindRaw: "dueChanged", date: randomDate(), seq: 1,
                previousDue: randomDate(), due: randomDate()
            ))
        }
        try source.insert(records, events: events)
        _ = try await HowyExporter(store: source).export(to: exportFolder)
        let (target, _) = try makeStore()

        _ = try await importAll(exportFolder, into: target)

        let expected = try source.allTodos().map(\.record)
        #expect(expected.contains { $0.createdAt.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) != 0 })
        #expect(try target.allTodos().map(\.record) == expected)
        #expect(sorted(try target.allEvents()) == sorted(try source.allEvents()))
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

    @Test func eventsWithABadKeyFieldAreSkippedAndReportedUnknownKindsKept() async throws {
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
            #"History entry #4: unknown toQuadrant "later" (ignored)"#,
        ])
        #expect(plan.report.importedEventCount == 3)
        #expect(plan.report.invalidEventCount == 2)

        _ = try await importer.apply(plan)

        let history = try target.events(for: todo)
        #expect(history.map(\.kindRaw) == ["created", "moved", "pinned"], "the moved event lost only its bad quadrant")
        #expect(history.last?.id == future)
        #expect(history.last?.kind == nil)
    }
}

/// A small deterministic generator (SplitMix64), so random tests reproduce.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
