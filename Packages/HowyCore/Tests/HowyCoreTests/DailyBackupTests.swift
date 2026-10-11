import Foundation
import Testing
@testable import HowyCore

@MainActor
@Suite final class DailyBackupTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "howy-backups-\(UUID().uuidString)", directoryHint: .isDirectory)
    /// 2026-10-11 10:00 UTC.
    let clock = FakeClock(HowyFormat.date(from: "2026-10-11T10:00:00Z")!)
    let writes = TodoStoreTests.WriteCounter()
    let files: AttachmentStore
    let store: TodoStore
    let day: TimeInterval = 24 * 3600

    init() throws {
        let clock = clock
        let writes = writes
        files = AttachmentStore(root: base.appending(path: "files", directoryHint: .isDirectory))
        store = try TodoStore.inMemory(attachments: files, now: { clock.now }, didWrite: { writes.count += 1 })
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    var directory: URL { base.appending(path: "Backups", directoryHint: .isDirectory) }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func backup(keep: Int = DailyBackup.defaultKeep) -> DailyBackup {
        DailyBackup(store: store, directory: directory, keep: keep, calendar: utc, appVersion: "1.8.0")
    }

    func backupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
    }

    @Test func folderNamesSortByDay() {
        #expect(backup().folderName(for: clock.now) == "Howy Backup 2026-10-11")
        #expect(backup().folderName(for: HowyFormat.date(from: "2026-01-02T23:59:00Z")!) == "Howy Backup 2026-01-02")
        #expect(DailyBackup.isBackupName("Howy Backup 2026-10-11"))
        #expect(!DailyBackup.isBackupName("Howy Backup 2026-10-11 copy"))
        #expect(!DailyBackup.isBackupName("Howy Export 2026-10-11 1000"))
    }

    @Test func writesAnExportThatImportsBack() async throws {
        let todo = try store.add(title: "Taxes", quadrant: .urgentImportant)
        let receipt = try files.stage(data: Data("PNG".utf8), as: "receipt.png")
        try store.setAttachments([receipt], for: todo.id)
        try store.move(id: todo.id, to: .notUrgentImportant)
        writes.count = 0

        let outcome = try await backup().run()

        let folder = directory.appending(path: "Howy Backup 2026-10-11", directoryHint: .isDirectory)
        #expect(outcome == .created(folder))
        #expect(writes.count == 0, "a backup doesn't write the store")
        let json = String(decoding: try Data(contentsOf: folder.appending(path: HowyFormat.fileName)), as: UTF8.self)
        #expect(json.contains(#""appVersion" : "1.8.0""#))
        #expect(json.contains(#""kind" : "moved""#))
        #expect(FileManager.default.fileExists(atPath: HowyFormat.attachmentURL(in: folder, todoID: todo.id, name: "receipt.png").path(percentEncoded: false)))

        let restored = try TodoStore.inMemory(attachments: AttachmentStore(root: base.appending(path: "restored", directoryHint: .isDirectory)))
        let importer = HowyImporter(store: restored)
        let summary = try await importer.apply(try importer.analyze(folder: folder))
        #expect(summary == ImportReport(importCount: 1, attachmentCount: 1))
        #expect(try restored.allTodos().map(\.record) == store.allTodos().map(\.record))
        #expect(try restored.allEvents().map(\.record) == store.allEvents().map(\.record))
    }

    @Test func noSecondBackupOnTheSameDay() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        let folder = directory.appending(path: "Howy Backup 2026-10-11", directoryHint: .isDirectory)
        #expect(try await backup().run() == .created(folder))
        try store.add(title: "B", quadrant: .urgentImportant)
        clock.advance(by: 13 * 3600) // 23:00, still the 11th

        #expect(try await backup().run() == .alreadyDone(folder))
        #expect(try backupNames() == ["Howy Backup 2026-10-11"])
        let json = String(decoding: try Data(contentsOf: folder.appending(path: HowyFormat.fileName)), as: UTF8.self)
        #expect(!json.contains(#""title" : "B""#), "the day's backup isn't rewritten")
    }

    @Test func theNextDayGetsANewBackup() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        try await backup().run()
        clock.advance(by: 14 * 3600) // 00:00 on the 12th

        let outcome = try await backup().run()

        #expect(outcome == .created(directory.appending(path: "Howy Backup 2026-10-12", directoryHint: .isDirectory)))
        #expect(try backupNames() == ["Howy Backup 2026-10-11", "Howy Backup 2026-10-12"])
    }

    @Test func anInterruptedBackupIsWrittenAgain() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        let folder = directory.appending(path: "Howy Backup 2026-10-11", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) // no howy.json

        #expect(try await backup().run() == .created(folder))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: HowyFormat.fileName).path(percentEncoded: false)))
    }

    @Test func keepsOnlyTheNewestSeven() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        let stray = directory.appending(path: "notes.txt")
        for _ in 0..<10 {
            try await backup().run()
            clock.advance(by: day)
        }
        try Data("mine".utf8).write(to: stray)
        try await backup().run()

        #expect(try backupNames() == [
            "Howy Backup 2026-10-15", "Howy Backup 2026-10-16", "Howy Backup 2026-10-17", "Howy Backup 2026-10-18",
            "Howy Backup 2026-10-19", "Howy Backup 2026-10-20", "Howy Backup 2026-10-21", "notes.txt",
        ])
    }

    @Test func anEmptyStoreIsNotBackedUpAndKeepsTheOldBackups() async throws {
        let todo = try store.add(title: "A", quadrant: .urgentImportant)
        for _ in 0..<7 {
            try await backup().run()
            clock.advance(by: day)
        }
        let before = try backupNames()
        // The store is wiped (e.g. iCloud sign-out): no todos, no events.
        try store.todos(id: todo.id).forEach(store.context.delete)
        try store.allEvents().forEach(store.context.delete)
        try store.context.save()

        for _ in 0..<3 {
            #expect(try await backup().run() == .skippedEmptyStore)
            clock.advance(by: day)
        }
        #expect(try backupNames() == before)
    }

    @Test func aStoreWithOnlyHistoryIsBackedUp() async throws {
        let todo = try store.add(title: "A", quadrant: .urgentImportant)
        try store.delete(id: todo.id)
        #expect(try await backup().run() == .created(directory.appending(path: "Howy Backup 2026-10-11", directoryHint: .isDirectory)))
    }

    @Test func theDayFollowsTheCalendarsTimeZone() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        clock.advance(by: 5 * 3600) // 15:00 UTC is 00:00 on the 12th in Tokyo
        let backup = DailyBackup(store: store, directory: directory, calendar: tokyo)
        #expect(try await backup.run() == .created(directory.appending(path: "Howy Backup 2026-10-12", directoryHint: .isDirectory)))
    }

    // MARK: Atomic writes

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: name).path(percentEncoded: false))
    }

    func complete(_ name: String) throws {
        let folder = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appending(path: HowyFormat.fileName))
    }

    @Test func aSameDayPartialIsReplacedAndLeavesNoPartialBehind() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        let partial = directory.appending(path: "Howy Backup 2026-10-11.partial", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partial.appending(path: "junk"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appending(path: "Howy Backup 2026-10-03.partial", directoryHint: .isDirectory), withIntermediateDirectories: true)

        let outcome = try await backup().run()

        #expect(outcome == .created(directory.appending(path: "Howy Backup 2026-10-11", directoryHint: .isDirectory)))
        #expect(try backupNames() == ["Howy Backup 2026-10-11"], "the stale partials are gone")
        #expect(exists("Howy Backup 2026-10-11/\(HowyFormat.fileName)"))
    }

    @Test func existingBackupsSurviveAFailedWrite() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        for _ in 0..<3 {
            try await backup().run()
            clock.advance(by: day)
        }
        let before = try backupNames()
        let before1 = try Data(contentsOf: directory.appending(path: "Howy Backup 2026-10-11/\(HowyFormat.fileName)"))
        // Nothing can be created in the directory, so the new backup's write fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false)) }

        await #expect(throws: (any Error).self) { try await backup().run() }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
        #expect(try backupNames() == before)
        #expect(try Data(contentsOf: directory.appending(path: "Howy Backup 2026-10-11/\(HowyFormat.fileName)")) == before1)
    }

    @Test func aFailedWriteOfAnExistingDaysFolderKeepsTheCompleteOne() async throws {
        // The exporter alone: an atomic write over a complete folder replaces it only on success.
        try store.add(title: "A", quadrant: .urgentImportant)
        let folder = directory.appending(path: "Howy Backup 2026-10-11", directoryHint: .isDirectory)
        try complete("Howy Backup 2026-10-11")
        let document = HowyExport(todos: [])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false)) }

        await #expect(throws: (any Error).self) { try await HowyExporter.write(document, to: folder, files: nil, atomic: true) }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
        #expect(try String(contentsOf: folder.appending(path: HowyFormat.fileName), encoding: .utf8) == "{}")
        #expect(try backupNames() == ["Howy Backup 2026-10-11"])
    }

    // MARK: Pruning

    @Test func aClockJumpBackDeletesNoGoodBackups() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        for _ in 0..<7 {
            try await backup().run()
            clock.advance(by: day)
        }
        let before = try backupNames()
        clock.advance(by: -100 * day) // far in the past: every backup is dated in the future

        #expect(try await backup().run() == .created(directory.appending(path: "Howy Backup 2026-07-10", directoryHint: .isDirectory)))

        #expect(try backupNames() == (["Howy Backup 2026-07-10"] + before))
    }

    @Test func aClockJumpForwardKeepsTheNewestSevenAndNeverTheFutureOnesAgainstTheGoodOnes() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        for _ in 0..<7 {
            try await backup().run()
            clock.advance(by: day)
        }
        clock.advance(by: 300 * day)
        try await backup().run() // a wild date: 8 complete backups, the oldest goes
        #expect(try backupNames().count == 7)
        clock.advance(by: -300 * day) // the clock comes back
        let names = try backupNames()
        let bogus = try #require(names.last)

        try await backup().run() // today (the 18th) is new; the bogus future one isn't counted
        let after = try backupNames()
        #expect(after.contains(bogus), "a future-dated folder is left alone")
        #expect(after.contains("Howy Backup 2026-10-18"))
        #expect(after.filter { $0 <= "Howy Backup 2026-10-18" }.count == 7)
    }

    @Test func incompleteFoldersAreNeitherCountedNorPruned() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        let hollow = directory.appending(path: "Howy Backup 2026-09-01", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hollow, withIntermediateDirectories: true)
        for _ in 0..<8 {
            try await backup(keep: 7).run()
            clock.advance(by: day)
        }
        #expect(exists("Howy Backup 2026-09-01"), "an incomplete folder is left alone")
        #expect(try backupNames().filter { $0 != "Howy Backup 2026-09-01" }.count == 7)
    }

    @Test func theFolderJustWrittenIsNeverPruned() async throws {
        try store.add(title: "A", quadrant: .urgentImportant)
        for name in ["Howy Backup 2026-10-12", "Howy Backup 2026-10-13"] { try complete(name) } // future
        try complete("Howy Backup 2026-10-01")
        try await backup(keep: 1).run()
        #expect(exists("Howy Backup 2026-10-11"))
        #expect(!exists("Howy Backup 2026-10-01"))
        #expect(exists("Howy Backup 2026-10-12") && exists("Howy Backup 2026-10-13"))
    }

    @Test func aBackupWithProblemsPrunesNothing() async throws {
        let todo = try store.add(title: "A", quadrant: .urgentImportant)
        let receipt = try files.stage(data: Data("PNG".utf8), as: "receipt.png")
        try store.setAttachments([receipt], for: todo.id)
        for name in ["Howy Backup 2026-10-01", "Howy Backup 2026-10-02", "Howy Backup 2026-10-03"] { try complete(name) }
        // The attachment file goes missing, so the export lists it as a problem.
        try FileManager.default.removeItem(at: files.url(for: receipt, todoID: todo.id)!)

        try await backup(keep: 1).run()

        #expect(try backupNames().count == 4, "nothing pruned this run")
        clock.advance(by: day)
        try await backup(keep: 1).run() // still has the problem
        #expect(try backupNames().count == 5)
    }

    // MARK: Names

    @Test func nonGregorianCalendarsStillGiveGregorianNames() throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        for identifier in [Calendar.Identifier.buddhist, .japanese, .islamicUmmAlQura, .hebrew, .persian] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = tokyo
            let backup = DailyBackup(store: store, directory: directory, calendar: calendar)
            #expect(backup.folderName(for: clock.now) == "Howy Backup 2026-10-11", "\(identifier)")
            #expect(DailyBackup.isBackupName(backup.folderName(for: clock.now)))
        }
        // No calendar given: Gregorian in the current time zone.
        #expect(DailyBackup(store: store, directory: directory).calendar.identifier == .gregorian)
        #expect(DailyBackup(store: store, directory: directory).calendar.timeZone == .current)
    }

    @Test func todaysCompletenessIsACheapFileCheck() async throws {
        #expect(await DailyBackup.isTodayComplete(in: directory, at: clock.now, calendar: utc) == false)
        try complete("Howy Backup 2026-10-11")
        #expect(await DailyBackup.isTodayComplete(in: directory, at: clock.now, calendar: utc))
        #expect(await DailyBackup.isTodayComplete(in: directory, at: clock.now.addingTimeInterval(day), calendar: utc) == false)
    }
}
