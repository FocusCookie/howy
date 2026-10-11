import Foundation
import os
import SwiftData
import Synchronization

/// Whether the shared on-disk store mirrors to CloudKit.
///
/// Only one process may mirror a store (Apple TN3164, "Avoid synchronizing a store with multiple
/// persistent containers"): the app does, and the widget extension opens the same file with
/// `.local`. SwiftData records persistent history for every store, so what the widget writes
/// still reaches the app's mirroring, which exports it.
public enum StoreSync: Hashable, Sendable {
    /// No CloudKit (`cloudKitDatabase: .none`): the widget extension, and the app until sync is
    /// turned on.
    case local
    /// Mirrors to this CloudKit container's private database (`.private(containerIdentifier)`).
    case iCloud(containerIdentifier: String)

    /// Howy's CloudKit container, shared with the later iOS app.
    public static let containerIdentifier = "iCloud.lueddemann.howy"

    /// Whether a container with this setting mirrors to CloudKit.
    public var mirrors: Bool {
        if case .iCloud = self { true } else { false }
    }

    var cloudKitDatabase: ModelConfiguration.CloudKitDatabase {
        switch self {
        case .local: .none
        case .iCloud(let identifier): .private(identifier)
        }
    }
}

/// The process's one `ModelContainer` for the shared on-disk store, built on first use.
///
/// One container per process, not one per `TodoStore`: with CloudKit every container would
/// start its own mirroring of the same file. Every `TodoStore.shared()` and the background
/// `StoreMaintenance` work run on it, each with its own `ModelContext`.
///
/// The state sits behind a `Mutex`, so it can be read from any thread. A build that throws
/// caches nothing, and the next call tries again.
///
/// **Fallback.** When the `.iCloud` build throws (say, a missing entitlement), the container is
/// built `.local` on the same file for the rest of the run, and `fallbackReason` says why. The
/// CloudKit build is never tried again in this process: from then on the setting is `.local`.
final class SharedContainer: Sendable {
    private struct State {
        var sync: StoreSync = .local
        var container: ModelContainer?
        var fallbackReason: String?
    }

    private let state = Mutex(State())
    private static let log = Logger(subsystem: "lueddemann.howy", category: "SharedContainer")

    /// The process-wide instance behind `TodoStore.shared()`. Tests make their own.
    static let process = SharedContainer()

    /// The sync setting the container is (or will be) built with: after a fallback, `.local`.
    var sync: StoreSync {
        state.withLock { $0.sync }
    }

    /// Why the `.iCloud` build failed and the container was built `.local` instead; `nil` when
    /// it didn't (or hasn't been tried yet).
    var fallbackReason: String? {
        state.withLock { $0.fallbackReason }
    }

    /// Whether the container has been built.
    var isBuilt: Bool {
        state.withLock { $0.container != nil }
    }

    /// Sets how the container syncs. Only takes effect before it is built and before a fallback:
    /// returns `false`, and changes nothing, when it already exists with another setting (or the
    /// CloudKit build already failed and this asks for it again).
    @discardableResult
    func configure(sync: StoreSync) -> Bool {
        state.withLock { state in
            if state.container != nil || state.fallbackReason != nil { return state.sync == sync }
            state.sync = sync
            return true
        }
    }

    /// The container, built with `build` (given the sync setting) on the first call. The lock is
    /// held while it builds, so a second caller waits for it instead of building another. A
    /// mirroring build that throws falls back to `.local` (see the type's comment).
    func container(_ build: (StoreSync) throws -> ModelContainer) throws -> ModelContainer {
        try state.withLock { state in
            if let container = state.container { return container }
            let container: ModelContainer
            do {
                container = try build(state.sync)
            } catch where state.sync.mirrors {
                let reason = String(describing: error)
                Self.log.error("CloudKit store unavailable, using the local store for this run: \(reason, privacy: .public)")
                state.sync = .local
                state.fallbackReason = reason
                container = try build(.local)
            }
            state.container = container
            return container
        }
    }
}
