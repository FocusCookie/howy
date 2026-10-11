import Foundation
import SwiftData
import Testing
@testable import HowyCore

/// The on-disk store's one `ModelContainer` per process.
@MainActor
@Suite struct SharedContainerTests {
    func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "howy-shared-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "Howy.store")
    }

    @Test func theContainerIsBuiltOnceAndReused() throws {
        let cache = SharedContainer()
        let url = temporaryStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var builds = 0
        func build(_ sync: StoreSync) throws -> ModelContainer {
            builds += 1
            #expect(sync == .local)
            return try TodoStore.makeContainer(url: url, healFlag: UserDefaults(suiteName: "howy.tests.\(UUID().uuidString)")!, sync: sync)
        }

        let first = try cache.container(build)
        let second = try cache.container(build)

        #expect(first === second)
        #expect(builds == 1)
        // Stores on it share the container, each with its own context.
        let a = TodoStore(modelContainer: first)
        let b = TodoStore(modelContainer: second)
        #expect(a.context !== b.context)
        let todo = try a.add(title: "Seen by both", quadrant: .urgentImportant)
        #expect(try b.todo(id: todo.id)?.title == "Seen by both")
    }

    @Test func aFailedBuildIsTriedAgain() throws {
        struct Failure: Error {}
        let cache = SharedContainer()
        #expect(throws: Failure.self) { try cache.container { _ in throw Failure() } }
        let container = try cache.container { _ in try TodoStore.inMemory().modelContainer }
        #expect(try cache.container { _ in throw Failure() } === container)
    }

    @Test func syncIsConfiguredBeforeTheFirstBuildOnly() throws {
        let cache = SharedContainer()
        #expect(cache.sync == .local)
        #expect(cache.configure(sync: .iCloud(containerIdentifier: StoreSync.containerIdentifier)))
        var seen: StoreSync?
        _ = try cache.container { sync in
            seen = sync
            return try TodoStore.inMemory().modelContainer
        }
        #expect(seen == .iCloud(containerIdentifier: StoreSync.containerIdentifier))
        #expect(!cache.configure(sync: .local), "too late: the container already mirrors")
        #expect(cache.configure(sync: .iCloud(containerIdentifier: StoreSync.containerIdentifier)), "the same setting again is fine")
    }

    @Test func onlyTheICloudSettingMirrors() {
        #expect(!StoreSync.local.mirrors)
        #expect(StoreSync.iCloud(containerIdentifier: StoreSync.containerIdentifier).mirrors)
        #expect(StoreSync.containerIdentifier == "iCloud.lueddemann.howy")
    }
}
