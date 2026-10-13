import Foundation
import SwiftData
import Testing
@testable import HowyCore

/// The one-time pass that rounds dates written before Phase 3a to whole milliseconds.
@MainActor
@Suite struct DateQuantizationTests {
    /// 1.8e9 s plus 0.123456 s: not a whole millisecond.
    static let odd = Date(timeIntervalSince1970: 1_800_000_000.123456)

    /// A todo and an event whose every date is sub-millisecond, as an old build stored them.
    func insertOldRows(into context: ModelContext) throws -> (todo: UUID, event: UUID) {
        let todo = Todo(title: "Old", quadrant: .urgentImportant, createdAt: Self.odd)
        todo.createdAt = Self.odd
        todo.sortDate = Self.odd.addingTimeInterval(1)
        todo.updatedAt = Self.odd.addingTimeInterval(2)
        todo.completedAt = Self.odd.addingTimeInterval(3)
        todo.due = Self.odd.addingTimeInterval(4)
        let event = TodoEvent(todoID: todo.id, kind: .dueChanged, date: Self.odd, previousDue: Self.odd, due: Self.odd)
        event.date = Self.odd
        event.previousDue = Self.odd.addingTimeInterval(5)
        event.due = Self.odd.addingTimeInterval(6)
        context.insert(todo)
        context.insert(event)
        try context.save()
        return (todo.id, event.id)
    }

    static func isWhole(_ date: Date?) -> Bool {
        guard let date else { return true }
        return date == date.wholeMilliseconds
    }

    func expectWhole(_ store: TodoStore, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for todo in try store.context.fetch(FetchDescriptor<Todo>()) {
            for date in [todo.createdAt, todo.sortDate, todo.updatedAt, todo.completedAt, todo.due] {
                #expect(Self.isWhole(date), sourceLocation: sourceLocation)
            }
        }
        for event in try store.context.fetch(FetchDescriptor<TodoEvent>()) {
            for date in [event.date, event.previousDue, event.due] {
                #expect(Self.isWhole(date), sourceLocation: sourceLocation)
            }
        }
    }

    @Test func roundsEveryStoredDateOnceAndKeepsTheMillisecond() throws {
        let store = try TodoStore.inMemory()
        let ids = try insertOldRows(into: store.context)
        let untouched = try store.add(title: "New", quadrant: .notUrgentImportant)
        let before = DuplicateRules.milliseconds(try #require(try store.todo(id: ids.todo)).updatedAt)

        let changed = try DateQuantization.run(in: ModelContext(store.modelContainer))

        #expect(changed == 2, "the old todo and its event; rows already whole aren't touched")
        let fresh = TodoStore(modelContainer: store.modelContainer)
        try expectWhole(fresh)
        let todo = try #require(try fresh.todo(id: ids.todo))
        #expect(DuplicateRules.milliseconds(todo.updatedAt) == before)
        #expect(todo.updatedAt == Date(timeIntervalSince1970: 1_800_000_002.123).wholeMilliseconds)
        #expect(try fresh.todo(id: untouched.id)?.title == "New")
        #expect(try DateQuantization.run(in: ModelContext(store.modelContainer)) == 0, "a second pass changes nothing")
    }

    @Test func anEmptyStoreChangesNothing() throws {
        let store = try TodoStore.inMemory()
        #expect(try DateQuantization.run(in: store.context) == 0)
    }

    @Test func theStoreFileIsQuantizedOnceBeforeItMirrors() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "howy-quantize-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Howy-Test.store")
        let flags = try #require(UserDefaults(suiteName: "howy.tests.\(UUID().uuidString)"))
        do {
            let old = try TodoStore.onDisk(url: url, healFlag: flags)
            _ = try insertOldRows(into: old.context)
        }

        #expect(try TodoStore.quantizeDatesBeforeMirroring(url: url, flags: flags) == 2)
        #expect(flags.bool(forKey: TodoStore.datesQuantizedFlagKey(fileName: "Howy-Test.store")))
        #expect(try TodoStore.quantizeDatesBeforeMirroring(url: url, flags: flags) == nil, "once per file")
        try expectWhole(TodoStore.onDisk(url: url, healFlag: flags))
    }

    @Test func theFlagIsPerStoreFile() {
        #expect(TodoStore.datesQuantizedFlagKey(fileName: "Howy.store") != TodoStore.datesQuantizedFlagKey(fileName: "Howy-Debug.store"))
    }
}
