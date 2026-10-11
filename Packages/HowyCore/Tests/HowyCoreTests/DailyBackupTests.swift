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
}
