import Foundation
import Testing
@testable import HowyCore

@Suite struct HowyFormatTests {
    @Test func datesRoundTripExactly() throws {
        let dates = [
            Date(timeIntervalSinceReferenceDate: 800_000_000),
            Date(timeIntervalSinceReferenceDate: 800_000_000.123),
            Date(timeIntervalSinceReferenceDate: 813_456_789.987654321),
            Date(),
        ]
        for date in dates {
            #expect(HowyFormat.date(from: HowyFormat.string(from: date)) == date)
        }
        #expect(HowyFormat.string(from: try #require(HowyFormat.date(from: "2026-10-01T08:00:00Z"))) == "2026-10-01T08:00:00Z")
    }

    @Test func datesAcceptOffsetsAndPlainDays() throws {
        let utc = try #require(HowyFormat.date(from: "2026-10-01T08:00:00Z"))
        #expect(HowyFormat.date(from: "2026-10-01T10:00:00+02:00") == utc)
        #expect(HowyFormat.date(from: "2026-10-01T08:00:00.500Z") == utc.addingTimeInterval(0.5))
        #expect(HowyFormat.date(from: "2026-10-01") == utc.addingTimeInterval(-8 * 3600))
        #expect(HowyFormat.date(from: "yesterday") == nil)
    }

    @Test func quadrantNamesRoundTrip() {
        for quadrant in Quadrant.allCases {
            #expect(Quadrant(formatName: quadrant.formatName) == quadrant)
        }
        #expect(Quadrant.urgentImportant.formatName == "urgent-important")
        #expect(Quadrant.notUrgentUnimportant.formatName == "not-urgent-unimportant")
        #expect(Quadrant(formatName: "urgent") == nil)
    }

    @Test(arguments: ["", " ", ".", "..", "../x.png", "a/b.png", "a\\b.png", "x..png"])
    func unsafeAttachmentNamesAreRefused(name: String) {
        #expect(!HowyFormat.isSafeAttachmentName(name))
    }

    @Test func plainAttachmentNamesAreAllowed() {
        #expect(HowyFormat.isSafeAttachmentName("receipt.png"))
        #expect(HowyFormat.isSafeAttachmentName("Q4 plan (draft).pdf"))
    }

    @Test func descriptionCarriesTheExampleAndEveryQuadrant() {
        #expect(HowyFormat.llmDescription.hasPrefix("Convert the following data into this Howy import format."))
        #expect(HowyFormat.llmDescription.contains(HowyFormat.llmExample))
        for quadrant in Quadrant.allCases {
            #expect(HowyFormat.llmDescription.contains("\"\(quadrant.formatName)\""))
        }
    }
}

@MainActor
@Suite final class ImportExportTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "howy-io-\(UUID().uuidString)", directoryHint: .isDirectory)
    let clock = FakeClock()

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    /// A store with attachments in its own temp folder, counting widget reloads.
    func makeStore(_ name: String) throws -> (TodoStore, TodoStoreTests.WriteCounter) {
        let clock = clock
        let writes = TodoStoreTests.WriteCounter()
        let files = AttachmentStore(root: base.appending(path: "\(name)-files", directoryHint: .isDirectory))
        let store = try TodoStore.inMemory(attachments: files, now: { clock.now }, didWrite: { writes.count += 1 })
        return (store, writes)
    }

    var exportFolder: URL { base.appending(path: "Howy Export", directoryHint: .isDirectory) }

    /// Writes `json` as `howy.json` into a fresh folder, plus `files` as `attachments/<path>`.
    func importFolder(json: String, files: [String: String] = [:]) throws -> URL {
        let folder = base.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: HowyFormat.fileName))
        for (path, contents) in files {
            let url = folder.appending(path: "attachments/\(path)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return folder
    }

    func json(_ todos: String, version: String = "1") -> String {
        #"{ "formatVersion": \#(version), "todos": [\#(todos)] }"#
    }

    func todoJSON(id: UUID = UUID(), title: String = "T", quadrant: String = "urgent-important", extra: String = "") -> String {
        #"{ "id": "\#(id)", "title": "\#(title)", "quadrant": "\#(quadrant)", "createdAt": "2026-10-01T08:00:00Z"\#(extra) }"#
    }

    func contents(_ url: URL?) throws -> String? {
        try url.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
    }

    /// A store with an open todo with two attachments, a moved todo and a done todo.
    func filledStore() throws -> TodoStore {
        let (store, _) = try makeStore("source")
        let files = try #require(store.attachments)
        let open = try store.add(title: "Prepare taxes", note: "See ![receipt](receipt.png)", quadrant: .urgentImportant)
        let receipt = try files.stage(data: Data("PNG".utf8), as: "receipt.png")
        let plan = try files.stage(data: Data("PDF".utf8), as: "Q4 plan (draft).pdf")
        try store.setAttachments([receipt, plan], for: open.id)
        clock.advance(by: 60.25)
        let moved = try store.add(title: "Call mum", quadrant: .urgentUnimportant)
        clock.advance(by: 3.5)
        try store.move(id: moved.id, to: .notUrgentImportant)
        let done = try store.add(title: "Old thing", note: "**done**", quadrant: .notUrgentUnimportant)
        clock.advance(by: 100)
        try store.complete(id: done.id)
        return store
    }

    // MARK: Export

    @Test func exportWritesJSONAndAttachmentFiles() async throws {
        let store = try filledStore()
        let result = try await HowyExporter(store: store, appVersion: "1.4.0").export(to: exportFolder)
        #expect(result.todoCount == 3)
        #expect(result.attachmentCount == 2)
        #expect(result.problems.isEmpty)

        let todo = try #require(try store.allTodos().first)
        let receipt = HowyFormat.attachmentURL(in: exportFolder, todoID: todo.id, name: "receipt.png")
        #expect(try contents(receipt) == "PNG")
        let json = try #require(try contents(exportFolder.appending(path: HowyFormat.fileName)))
        #expect(json.contains(#""formatVersion" : 1"#))
        #expect(json.contains(#""appVersion" : "1.4.0""#))
        #expect(json.contains(#""quadrant" : "urgent-important""#))
        #expect(json.contains(#""completedAt" : null"#))
    }

    @Test func exportReportsUnreadableAttachmentsButKeepsThemListed() async throws {
        let store = try filledStore()
        let files = try #require(store.attachments)
        let todo = try #require(try store.allTodos().first)
        let receipt = try #require(store.attachmentList(for: todo.id).first)
        try FileManager.default.removeItem(at: try #require(files.url(for: receipt, todoID: todo.id)))

        let result = try await HowyExporter(store: store).export(to: exportFolder)
        #expect(result.attachmentCount == 1)
        #expect(result.problems == [#""Prepare taxes": attachment "receipt.png" not found"#])
        #expect(try contents(exportFolder.appending(path: HowyFormat.fileName))?.contains("receipt.png") == true)
    }

    @Test func exportReplacesAnExistingFolder() async throws {
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: exportFolder.appending(path: "stale.txt"))
        _ = try await HowyExporter(store: try filledStore()).export(to: exportFolder)
        #expect(!FileManager.default.fileExists(atPath: exportFolder.appending(path: "stale.txt").path(percentEncoded: false)))
    }

    @Test func failedExportRemovesTheHalfWrittenFolder() async throws {
        // The destination's parent is a file, so the folder can't be created.
        let blocker = base.appending(path: "blocker")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data().write(to: blocker)
        let folder = blocker.appending(path: "Export", directoryHint: .isDirectory)
        await #expect(throws: (any Error).self) {
            try await HowyExporter(store: try self.filledStore()).export(to: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    // MARK: Round trip

    @Test func roundTripGivesIdenticalTodosAndAttachments() async throws {
        let source = try filledStore()
        _ = try await HowyExporter(store: source).export(to: exportFolder)

        let (target, writes) = try makeStore("target")
        let importer = HowyImporter(store: target, retention: ArchiveRetention(days: 90))
        let plan = try importer.analyze(folder: exportFolder)
        #expect(plan.report == ImportReport(importCount: 3, attachmentCount: 2))
        #expect(writes.count == 0)

        let summary = try await importer.apply(plan)
        #expect(summary == ImportReport(importCount: 3, attachmentCount: 2))
        #expect(writes.count == 1)

        #expect(try target.allTodos().map(\.record) == source.allTodos().map(\.record))
        for todo in try source.allTodos() {
            let list = source.attachmentList(for: todo.id)
            #expect(target.attachmentList(for: todo.id) == list)
            for attachment in list {
                #expect(try contents(target.attachments?.url(for: attachment, todoID: todo.id))
                    == contents(source.attachments?.url(for: attachment, todoID: todo.id)))
            }
        }
        #expect(try target.archivedTodos().map(\.title) == ["Old thing"])
        // The import area is cleaned up.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: try #require(target.attachments).root.path(percentEncoded: false))
        #expect(!leftovers.contains { $0.hasPrefix("import-") })
    }

    @Test func importingTwiceSkipsEverythingAsDuplicates() async throws {
        _ = try await HowyExporter(store: try filledStore()).export(to: exportFolder)
        let (target, writes) = try makeStore("target")
        let importer = HowyImporter(store: target)
        _ = try await importer.apply(try importer.analyze(folder: exportFolder))
        let before = try target.allTodos().map(\.record)

        let plan = try importer.analyze(folder: exportFolder)
        #expect(plan.report == ImportReport(duplicateCount: 3))
        let summary = try await importer.apply(plan)
        #expect(summary == ImportReport(duplicateCount: 3))
        #expect(writes.count == 1) // the second import wrote nothing
        #expect(try target.allTodos().map(\.record) == before)
    }

    @Test func existingTodosAreNeverChanged() async throws {
        let (store, _) = try makeStore("target")
        let mine = try store.add(title: "Mine", note: "keep", quadrant: .urgentImportant)
        let folder = try importFolder(json: json(todoJSON(id: mine.id, title: "Theirs", quadrant: "urgent-unimportant",
                                                          extra: #", "attachments": [{ "id": "\#(UUID())", "name": "a.txt" }]"#)),
                                      files: ["\(mine.id)/a.txt": "A"])
        let importer = HowyImporter(store: store)
        let summary = try await importer.apply(try importer.analyze(folder: folder))
        #expect(summary == ImportReport(duplicateCount: 1))
        let after = try #require(try store.todo(id: mine.id))
        #expect(after.title == "Mine")
        #expect(after.quadrant == .urgentImportant)
        #expect(store.attachmentList(for: mine.id).isEmpty)
    }

    // MARK: Invalid entries

    @Test func invalidEntriesAreSkippedAndReported() async throws {
        let (store, _) = try makeStore("target")
        let good = UUID()
        let todos = [
            todoJSON(id: good, title: "Good"),
            #"{ "id": "\#(UUID())", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" }"#,
            todoJSON(title: "Bad quadrant", quadrant: "urgent"),
            #"{ "id": "nope", "title": "x", "quadrant": "urgent-important", "createdAt": "2026-10-01T08:00:00Z" }"#,
            #"{ "id": "\#(UUID())", "title": "No date", "quadrant": "urgent-important" }"#,
            todoJSON(title: "Bad date", extra: #", "completedAt": "soon""#),
            todoJSON(title: "   "),
            #""just text""#,
            todoJSON(id: good, title: "Same id"),
        ]
        let folder = try importFolder(json: json(todos.joined(separator: ",")))
        let importer = HowyImporter(store: store)
        let plan = try importer.analyze(folder: folder)
        #expect(plan.report.problems == [
            "Entry #2: missing title",
            #"Entry #3: unknown quadrant "urgent""#,
            #"Entry #4: invalid id "nope""#,
            "Entry #5: missing createdAt",
            #"Entry #6: invalid completedAt "soon""#,
            "Entry #7: empty title",
            "Entry #8: not a todo object",
            "Entry #9: same id as entry #1",
        ])
        #expect(plan.report.invalidCount == 7)
        #expect(plan.report.duplicateCount == 1)
        #expect(plan.report.importCount == 1)
        #expect(plan.report.totalCount == 9)

        let summary = try await importer.apply(plan)
        #expect(summary.importCount == 1)
        #expect(summary.invalidCount == 7)
        #expect(try store.allTodos().map(\.title) == ["Good"])
    }

    @Test func optionalFieldsGetTheirDefaults() async throws {
        let (store, _) = try makeStore("target")
        let id = UUID()
        let folder = try importFolder(json: json(todoJSON(id: id, title: "Bare", extra: #", "unknownKey": [1, 2]"#)))
        let importer = HowyImporter(store: store)
        _ = try await importer.apply(try importer.analyze(folder: folder))
        let todo = try #require(try store.todo(id: id))
        #expect(todo.note == "")
        #expect(todo.sortDate == todo.createdAt)
        #expect(todo.completedAt == nil)
        #expect(store.attachmentList(for: id).isEmpty)
    }

    // MARK: Attachments

    @Test func missingAttachmentFileIsReportedAndTheTodoImported() async throws {
        let (store, _) = try makeStore("target")
        let id = UUID()
        let here = TodoAttachment(name: "here.txt")
        let attachments = #", "attachments": [{ "id": "\#(here.id)", "name": "here.txt" }, { "id": "\#(UUID())", "name": "receipt.png" }]"#
        let folder = try importFolder(json: json(todoJSON(id: id, title: "Buy milk", extra: attachments)),
                                      files: ["\(id)/here.txt": "H", "\(id)/ignored.txt": "not listed"])
        let importer = HowyImporter(store: store)
        let plan = try importer.analyze(folder: folder)
        #expect(plan.report.problems == [#""Buy milk": attachment "receipt.png" not found in folder"#])
        #expect(plan.report.missingAttachmentCount == 1)
        #expect(plan.report.attachmentCount == 1)

        let summary = try await importer.apply(plan)
        #expect(summary.importCount == 1)
        #expect(summary.missingAttachmentCount == 1)
        #expect(store.attachmentList(for: id) == [here])
        #expect(try contents(store.attachments?.url(for: here, todoID: id)) == "H")
    }

    @Test func pathTraversalNamesAreRefused() async throws {
        let (store, _) = try makeStore("target")
        let id = UUID()
        let names = ["../../evil.txt", "sub/evil.txt", #"a\\evil.txt"#, ""]
        let list = names.map { #"{ "id": "\#(UUID())", "name": "\#($0)" }"# }.joined(separator: ",")
        let folder = try importFolder(json: json(todoJSON(id: id, title: "Sneaky", extra: #", "attachments": [\#(list)]"#)),
                                      files: ["evil.txt": "x", "\(id)/sub/evil.txt": "x"])
        let importer = HowyImporter(store: store)
        let plan = try importer.analyze(folder: folder)
        #expect(plan.report.problems == [
            #""Sneaky": attachment name "../../evil.txt" is not allowed"#,
            #""Sneaky": attachment name "sub/evil.txt" is not allowed"#,
            #""Sneaky": attachment name "a\evil.txt" is not allowed"#,
            #""Sneaky": attachment name "" is not allowed"#,
        ])
        #expect(plan.report.missingAttachmentCount == 4)
        _ = try await importer.apply(plan)
        #expect(try store.todo(id: id) != nil)
        #expect(store.attachmentList(for: id).isEmpty)
        let root = try #require(store.attachments).root
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appending(path: "evil.txt").path(percentEncoded: false)))
    }

    @Test func attachmentsListedTwiceAreReported() throws {
        let (store, _) = try makeStore("target")
        let id = UUID()
        let list = #"{ "id": "\#(UUID())", "name": "a.txt" }, { "id": "\#(UUID())", "name": "A.txt" }"#
        let folder = try importFolder(json: json(todoJSON(id: id, title: "Twice", extra: #", "attachments": [\#(list)]"#)),
                                      files: ["\(id)/a.txt": "A"])
        let plan = try HowyImporter(store: store).analyze(folder: folder)
        #expect(plan.report.problems == [#""Twice": attachment "A.txt" is listed twice"#])
        #expect(plan.report.attachmentCount == 1)
    }

    // MARK: Refused imports

    @Test(arguments: [
        ("not json at all", HowyImportError.unreadable("it isn't valid JSON")),
        (#"{ "todos": [] }"#, .missingFormatVersion),
        (#"{ "formatVersion": null, "todos": [] }"#, .missingFormatVersion),
        (#"{ "formatVersion": 2, "todos": [] }"#, .newerFormatVersion(2)),
        (#"{ "formatVersion": 0, "todos": [] }"#, .unknownFormatVersion("0")),
        (#"{ "formatVersion": "one", "todos": [] }"#, .unknownFormatVersion("\"one\"")),
        (#"{ "formatVersion": 1 }"#, .unreadable("it has no todos list")),
    ])
    func refusedFilesWriteNothing(json: String, error: HowyImportError) throws {
        let (store, writes) = try makeStore("target")
        let folder = try importFolder(json: json)
        #expect(throws: error) { try HowyImporter(store: store).analyze(folder: folder) }
        #expect(try store.allTodos().isEmpty)
        #expect(writes.count == 0)
    }

    @Test func folderWithoutJSONIsRefused() throws {
        let (store, _) = try makeStore("target")
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        #expect(throws: HowyImportError.fileNotFound) { try HowyImporter(store: store).analyze(folder: exportFolder) }
        #expect(HowyImportError.newerFormatVersion(2).localizedDescription.contains("Update Howy"))
    }

    // MARK: Retention

    @Test func doneTodosOlderThanRetentionAreImportedAndCounted() async throws {
        let (store, _) = try makeStore("target")
        let now = clock.now
        let day: TimeInterval = 24 * 60 * 60
        func done(_ title: String, daysAgo: Double) -> String {
            let completed = HowyFormat.string(from: now.addingTimeInterval(-daysAgo * day))
            let created = HowyFormat.string(from: now.addingTimeInterval(-(daysAgo + 1) * day))
            return #"{ "id": "\#(UUID())", "title": "\#(title)", "quadrant": "urgent-important", "createdAt": "\#(created)", "completedAt": "\#(completed)" }"#
        }
        let todos = [done("Old", daysAgo: 10), done("Older", daysAgo: 40), done("Recent", daysAgo: 2), todoJSON(title: "Open")]
        let folder = try importFolder(json: json(todos.joined(separator: ",")))
        let importer = HowyImporter(store: store, retention: ArchiveRetention(days: 7))
        let plan = try importer.analyze(folder: folder)
        #expect(plan.report.expiredCount == 2)
        let summary = try await importer.apply(plan)
        #expect(summary.expiredCount == 2)
        #expect(summary.importCount == 4)
        #expect(try store.archivedTodos().count == 3)
        #expect(try store.purgeArchive(retention: ArchiveRetention(days: 7)) == 2)
    }

    // MARK: LLM example

    @Test func llmExampleImportsCleanly() async throws {
        let (store, writes) = try makeStore("target")
        let folder = try importFolder(json: HowyFormat.llmExample,
                                      files: ["6F1C2A4E-8B1D-4C55-9E0B-2D7F3A1B9C10/receipt.png": "PNG"])
        let importer = HowyImporter(store: store)
        let plan = try importer.analyze(folder: folder)
        #expect(plan.report == ImportReport(importCount: 2, attachmentCount: 1))
        let summary = try await importer.apply(plan)
        #expect(summary == ImportReport(importCount: 2, attachmentCount: 1))
        #expect(writes.count == 1)

        let open = try #require(try store.openTodos(in: .urgentImportant).first)
        #expect(open.title == "Prepare tax documents")
        #expect(open.note.contains("![receipt](receipt.png)"))
        #expect(store.attachmentList(for: open.id).map(\.name) == ["receipt.png"])
        #expect(try store.archivedTodos().map(\.title) == ["Book dentist appointment"])
    }
}
