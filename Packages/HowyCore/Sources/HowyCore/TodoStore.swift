import Foundation
import os
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

public enum TodoStoreError: Error, Equatable, Sendable {
    /// The title was empty or whitespace only.
    case emptyTitle
    /// No todo with this id exists.
    case notFound(UUID)
    /// The App Group container could not be resolved (missing entitlement?).
    case appGroupUnavailable(String)
}

/// All reads and writes of todos. Main-actor bound because it owns a `ModelContext`.
///
/// Each `TodoStore` has its own `ModelContext`, so one made now reads what is on disk now
/// (including the widget extension's writes). The shared on-disk stores of a process all sit on
/// one `ModelContainer` (`SharedContainer`), built once.
///
/// Every successful write saves the context and then calls `didWrite` (by default, for the
/// shared store, `TodoStore.reloadWidgetTimelines` and `StoreChangeSignal.post`).
///
/// **Duplicates.** An id isn't unique in schema v3, and with CloudKit two rows with one id are
/// two records. The store behaves as if there were one todo (and one event) per id: every read
/// collapses rows by id to the row the duplicate cleanup keeps (`DuplicateRules`), and every
/// write by id goes to the survivor and is then copied to the other rows in the same save, so
/// identical rows stay identical. Events are recorded once per change, not once per row.
///
/// Every write that changes a todo stamps its `updatedAt` with the clock, and records what
/// happened as `TodoEvent`s in the same save (created, completed, reopened, moved, the due
/// date kinds, deleted). Title and note edits, reorders within a quadrant, and no-op writes
/// record nothing. Events are never removed.
///
/// **Attachments** (schema v4) are `StoredAttachment` rows, synced like the todos; the files in
/// `attachments` are their local copies. Attachment changes record no events and don't stamp
/// the todo's `updatedAt`.
@MainActor
public final class TodoStore {
    /// The store file of Release builds (the user's real data) and of anything without the
    /// Info.plist key.
    nonisolated public static let defaultStoreFileName = "Howy.store"
    /// The Info.plist key with this build's store file name (`HOWY_STORE_FILE_NAME` in
    /// `project.yml`: `Howy-Debug.store` in Debug, `Howy.store` in Release). The app and the
    /// widget extension of one configuration read the same value, so they open the same file,
    /// and Debug (CloudKit Development) never opens Release's file (Production).
    nonisolated public static let storeFileNameInfoKey = "HowyStoreFileName"

    /// File name of the SQLite store inside the App Group container, for this build.
    nonisolated public static var storeFileName: String {
        storeFileName(info: Bundle.main.infoDictionary)
    }

    /// The name of a folder that belongs to this build's store file, next to it in the App
    /// Group: `base` itself for `Howy.store` (Release, the real data), `base-<file stem>` for
    /// any other (`Backups-Howy-Debug` for `Howy-Debug.store`). So a Debug run never takes the
    /// day's backup slot, prunes real backups or treats real attachments as orphans.
    nonisolated public static func storeScopedName(_ base: String, storeFileName: String = storeFileName) -> String {
        guard storeFileName != defaultStoreFileName else { return base }
        return "\(base)-\(storeFileName.dropLast(".store".count))"
    }

    /// The store file name an Info.plist dictionary asks for: its `HowyStoreFileName` when that
    /// is a plain file name ending in `.store`, otherwise `Howy.store`.
    nonisolated static func storeFileName(info: [String: Any]?) -> String {
        validStoreFileName(info: info) ?? defaultStoreFileName
    }

    /// The store file name an Info.plist dictionary asks for, or `nil` when the key is missing or
    /// isn't a plain `*.store` file name (an unexpanded `$(…)` build setting, a path, a hidden file).
    nonisolated static func validStoreFileName(info: [String: Any]?) -> String? {
        guard let name = info?[storeFileNameInfoKey] as? String,
              name.hasSuffix(".store"), name.count > ".store".count,
              !name.contains("/"), !name.contains("$"), !name.hasPrefix(".")
        else { return nil }
        return name
    }

    /// Whether this build's Info.plist names its store file properly. The app doesn't turn
    /// CloudKit on without it: a Debug build that silently fell back to `Howy.store` would mirror
    /// the real data into the Development environment from the wrong place.
    nonisolated public static var hasValidStoreFileName: Bool {
        validStoreFileName(info: Bundle.main.infoDictionary) != nil
    }

    let modelContainer: ModelContainer
    public let context: ModelContext
    /// The local copies of the attached files, and staging for new ones; `nil` for stores
    /// without attachments (most tests).
    public let attachments: AttachmentStore?
    private let now: @Sendable () -> Date
    private let didWrite: (@MainActor () -> Void)?
    /// Highest `seq` handed out per todo since the last commit (events not yet saved).
    private var pendingSeq: [UUID: Int] = [:]

    public init(
        modelContainer: ModelContainer,
        attachments: AttachmentStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = nil
    ) {
        self.modelContainer = modelContainer
        self.attachments = attachments
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false // `commit` saves, together with the events
        self.context = context
        // Every date the store writes comes from here or is passed through `wholeMilliseconds`.
        self.now = { now().wholeMilliseconds }
        self.didWrite = didWrite
    }

    // MARK: Factories

    /// The on-disk store in the App Group container, shared by the app and the widget extension.
    /// By default every write reloads the widgets and posts `StoreChangeSignal`.
    ///
    /// Every call returns a new `TodoStore` with a fresh `ModelContext`, all on the process's
    /// one `ModelContainer`, which the first call builds (with the setting given to
    /// `configureSharedSync(_:)`, `.local` if none was).
    public static func shared(
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = {
            TodoStore.reloadWidgetTimelines()
            StoreChangeSignal.post()
        }
    ) throws -> TodoStore {
        let container = try buildSharedContainer()
        return try TodoStore(modelContainer: container, attachments: AttachmentStore.shared(), now: now, didWrite: didWrite)
    }

    /// Builds the process's shared container (if it isn't yet) off the main actor, so a migration,
    /// the first-mirroring preparation and the CloudKit setup don't block the menu bar. The app
    /// awaits it at launch; `shared()` then finds the container built. A `shared()` that comes
    /// first (a deep link) builds it itself, on the main actor, and this waits for it.
    @concurrent
    nonisolated public static func prepareSharedContainer() async throws {
        _ = try buildSharedContainer()
    }

    nonisolated private static func buildSharedContainer() throws -> ModelContainer {
        // Read before the build: its closure runs while the container's lock is held.
        let isAppProcess = SharedContainer.process.requestedSync.mirrors
        return try SharedContainer.process.container { sync in
            try makeContainer(url: sharedStoreURL(), healFlag: sharedHealDefaults(), sync: sync, isAppProcess: isAppProcess)
        }
    }

    /// The sync mode the shared container really has, from what was built (the fallback
    /// included), not from what was asked for: `.starting` until it is built.
    public static var sharedSyncMode: SyncState.Mode {
        SyncMonitor.mode(
            sync: SharedContainer.process.sync, fallbackReason: SharedContainer.process.fallbackReason,
            isBuilt: SharedContainer.process.isBuilt
        )
    }

    /// How the shared store really syncs: the setting given to `configureSharedSync(_:)`, or
    /// `.local` after the CloudKit build failed (`sharedSyncFallbackReason`).
    public static var sharedSync: StoreSync {
        SharedContainer.process.sync
    }

    /// Why the shared store couldn't be opened with CloudKit and runs locally in this process;
    /// `nil` when it mirrors as configured (or wasn't built yet).
    public static var sharedSyncFallbackReason: String? {
        SharedContainer.process.fallbackReason
    }

    /// Chooses whether the shared store mirrors to CloudKit. Call it once at launch, before the
    /// first `shared()`: the app with its setting, the widget extension never (it stays
    /// `.local`, so only the app mirrors). Returns `false`, changing nothing, if the container
    /// was already built with another setting.
    @discardableResult
    public static func configureSharedSync(_ sync: StoreSync) -> Bool {
        let accepted = SharedContainer.process.configure(sync: sync)
        if !accepted { log.fault("Shared store sync set to \(String(describing: sync), privacy: .public) after the container was built") }
        return accepted
    }

    /// A store on a SQLite file at `url` (tests, tools).
    static func onDisk(
        url: URL,
        healFlag: UserDefaults? = nil,
        attachments: AttachmentStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = nil
    ) throws -> TodoStore {
        // Without a given flag store, each open gets a fresh one (the backfill is idempotent).
        let flag = healFlag ?? UserDefaults(suiteName: "howy.tests.\(UUID().uuidString)")!
        return try TodoStore(
            modelContainer: makeContainer(url: url, healFlag: flag, sync: .local),
            attachments: attachments, now: now, didWrite: didWrite
        )
    }

    /// The App Group store URL: `<group container>/Library/Application Support/Howy.store`.
    nonisolated public static func sharedStoreURL() throws -> URL {
        guard let container = HowyAppGroup.containerURL else {
            throw TodoStoreError.appGroupUnavailable(HowyAppGroup.identifier)
        }
        let directory = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: storeFileName)
    }

    /// Where the per-store flags live (self-heal, quantization, mirrored): the App Group's
    /// `UserDefaults`, shared by the app and the widget.
    nonisolated static func sharedHealDefaults() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: HowyAppGroup.identifier) else {
            throw TodoStoreError.appGroupUnavailable(HowyAppGroup.identifier)
        }
        return defaults
    }

    /// The flag key of the one-time self-heal before it was scoped per store file. It still
    /// counts for `Howy.store`, whose heal ran under it.
    nonisolated static let selfHealFlagKey = "howy.eventBackfillSelfHealDone"

    /// The `UserDefaults` key that marks the store file named `fileName` as self-healed.
    nonisolated static func selfHealFlagKey(fileName: String) -> String {
        "\(selfHealFlagKey).\(fileName)"
    }

    /// The `UserDefaults` key that marks the store file named `fileName` as built with CloudKit
    /// mirroring at least once (set when the mirroring container is first built).
    nonisolated static func mirroredFlagKey(fileName: String) -> String {
        "howy.storeMirrored.\(fileName)"
    }

    /// The `UserDefaults` key that marks the store file named `fileName` as quantized.
    nonisolated static func datesQuantizedFlagKey(fileName: String) -> String {
        "howy.datesQuantized.\(fileName)"
    }

    /// Whether the store file named `fileName` mirrored before, or was prepared for it. The
    /// quantization flag counts: it is only ever set right before the first mirroring build, and
    /// builds from before the mirrored flag existed set it.
    nonisolated static func hasMirrored(_ flags: UserDefaults, fileName: String) -> Bool {
        flags.bool(forKey: mirroredFlagKey(fileName: fileName)) || flags.bool(forKey: datesQuantizedFlagKey(fileName: fileName))
    }

    /// A new container on the store file at `url`: migrated to the live schema, and for the app
    /// process (`isAppProcess`) self-healed. With `sync.mirrors` the file is first prepared
    /// (`prepareBeforeMirroring`: self-heal, date quantization), then opened with CloudKit, and
    /// the mirrored flag is set. The widget extension (`isAppProcess == false`) never heals:
    /// once the app mirrors, todos can be there before their events, and a backfill would add
    /// false ones.
    nonisolated static func makeContainer(
        url: URL, healFlag flags: UserDefaults, sync: StoreSync, isAppProcess: Bool = true
    ) throws -> ModelContainer {
        let fileName = url.lastPathComponent
        if sync.mirrors { try prepareBeforeMirroring(url: url, flags: flags, isAppProcess: isAppProcess) }
        let container = try openContainer(url: url, sync: sync)
        if sync.mirrors {
            flags.set(true, forKey: mirroredFlagKey(fileName: fileName))
        } else {
            try selfHeal(container, flag: flags, fileName: fileName, isAppProcess: isAppProcess)
        }
        return container
    }

    /// Before a file mirrors for the first time: on a container that doesn't mirror, the
    /// self-heal and the date quantization, both once per file (flags in `flags`). A file that
    /// doesn't exist yet has nothing to heal or quantize, so it only sets the flags and no
    /// container is opened. Does nothing for a file that was prepared or mirrored before. If it
    /// throws, the flags stay unset and the next launch tries again.
    nonisolated static func prepareBeforeMirroring(url: URL, flags: UserDefaults, isAppProcess: Bool) throws {
        let fileName = url.lastPathComponent
        let quantizedKey = datesQuantizedFlagKey(fileName: fileName)
        guard !flags.bool(forKey: quantizedKey) else { return }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            flags.set(true, forKey: selfHealFlagKey(fileName: fileName))
            flags.set(true, forKey: quantizedKey)
            return
        }
        let container = try openContainer(url: url, sync: .local)
        try selfHeal(container, flag: flags, fileName: fileName, isAppProcess: isAppProcess)
        try quantizeDatesBeforeMirroring(url: url, flags: flags, container: container)
    }

    /// Rounds every stored date of the store file at `url` to whole milliseconds, once per file
    /// (flag in `flags`, keyed by the file name), on a container that doesn't mirror. Runs
    /// before the mirroring container opens, so the first upload already has whole-millisecond
    /// dates (rows written before Phase 3a may not). Returns how many rows it changed; `nil`
    /// when the flag was already set. If it throws, the flag stays unset.
    @discardableResult
    nonisolated static func quantizeDatesBeforeMirroring(
        url: URL, flags: UserDefaults, container: ModelContainer? = nil
    ) throws -> Int? {
        let key = datesQuantizedFlagKey(fileName: url.lastPathComponent)
        guard !flags.bool(forKey: key) else { return nil }
        let container = try container ?? openContainer(url: url, sync: .local)
        let changed = try DateQuantization.run(in: ModelContext(container))
        flags.set(true, forKey: key)
        log.notice("Quantized the dates of \(changed) rows in \(url.lastPathComponent, privacy: .public) before mirroring")
        return changed
    }

    /// A container on the store file at `url`, migrated to the live schema.
    nonisolated private static func openContainer(url: URL, sync: StoreSync) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Schema(versionedSchema: HowySchemaV4.self),
            url: url,
            cloudKitDatabase: sync.cloudKitDatabase
        )
        return try ModelContainer(
            for: Schema(versionedSchema: HowySchemaV4.self),
            migrationPlan: HowyMigrationPlan.self,
            configurations: configuration
        )
    }

    /// One-time self-heal: todos without any event mean the migration's backfill didn't run or
    /// failed. It runs only
    ///
    /// - in the app process (`isAppProcess`); the widget extension never does,
    /// - on a store file that never mirrored (`hasMirrored`): with CloudKit, todos can arrive
    ///   before their events, and a backfill then would add false events,
    /// - while the file's flag (`selfHealFlagKey(fileName:)`, and for `Howy.store` the older
    ///   unscoped one) isn't set.
    ///
    /// It sets the flag after any successful run, the no-op case of an empty store included.
    /// If the backfill throws, the flag stays unset and the next open tries again.
    nonisolated static func selfHeal(
        _ container: ModelContainer, flag flags: UserDefaults, fileName: String, isAppProcess: Bool
    ) throws {
        guard isAppProcess, !hasMirrored(flags, fileName: fileName),
              !flags.bool(forKey: selfHealFlagKey(fileName: fileName)),
              !(fileName == defaultStoreFileName && flags.bool(forKey: selfHealFlagKey))
        else { return }
        try HowyMigrationPlan.backfillEvents(in: ModelContext(container))
        flags.set(true, forKey: selfHealFlagKey(fileName: fileName))
    }

    /// An in-memory store for tests and previews.
    public static func inMemory(
        attachments: AttachmentStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        didWrite: (@MainActor () -> Void)? = nil
    ) throws -> TodoStore {
        let schema = Schema(versionedSchema: HowySchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: HowyMigrationPlan.self, configurations: configuration)
        return TodoStore(modelContainer: container, attachments: attachments, now: now, didWrite: didWrite)
    }

    /// Asks WidgetKit to reload every Howy widget timeline.
    public static func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: Writes

    @discardableResult
    public func add(id: UUID = UUID(), title: String, note: String = "", quadrant: Quadrant, due: Date? = nil) throws -> Todo {
        let title = try Self.validated(title)
        let stamp = now()
        let due = due.wholeMilliseconds
        let todo = Todo(id: id, title: title, note: note, quadrant: quadrant, createdAt: stamp, due: due)
        context.insert(todo)
        record(.created, for: todo.id, at: stamp, to: quadrant, due: due)
        try commit()
        return todo
    }

    /// Inserts todos and their history exactly as given, timestamps and `completedAt` included
    /// (import). Ids that already exist, or repeat within `records`, are skipped; existing todos
    /// are never changed. `updatedAt` is the clock's now.
    ///
    /// `events` are inserted as they are, except those whose id already exists (or repeats), so
    /// importing the same file again adds nothing. That includes events of todos that already
    /// exist (their history grows, the todo itself never changes) and of todos that aren't in
    /// `records` (deleted ones). An inserted todo that has no event in `events` (a format v1
    /// file) gets a `created` event at its `createdAt`, and a `completed` one at its
    /// `completedAt` if archived.
    ///
    /// All of it is one write, so widgets reload once; nothing new writes nothing. Returns the
    /// todo ids inserted, in order.
    @discardableResult
    public func insert(_ records: [TodoRecord], events: [TodoEventRecord] = []) throws -> [UUID] {
        try insertReporting(records, events: events).todoIDs
    }

    /// What `insertReporting` wrote.
    struct InsertResult {
        /// The todo ids inserted, in order.
        var todoIDs: [UUID]
        /// Events inserted from the given ones (not counting made-up `created`/`completed`).
        var eventCount: Int
    }

    /// `insert`, also telling how many of the given events were new. `attachments` are, per todo,
    /// files already committed to its folder (`AttachmentStore.commitImport`); the inserted
    /// todos get them in the same save.
    func insertReporting(
        _ records: [TodoRecord], events: [TodoEventRecord], attachments files: [UUID: [TodoAttachment]] = [:]
    ) throws -> InsertResult {
        let validated = try records.map { record in
            var record = record
            record.title = try Self.validated(record.title)
            return record
        }
        var taken = try allIDs()
        var inserted: [UUID] = []
        let stamp = now()
        let withHistory = Set(events.map(\.todoID))
        for record in validated where taken.insert(record.id).inserted {
            context.insert(Todo(
                id: record.id, title: record.title, note: record.note, quadrant: record.quadrant,
                createdAt: record.createdAt, sortDate: record.sortDate, completedAt: record.completedAt,
                due: record.due, updatedAt: stamp
            ))
            if !withHistory.contains(record.id) {
                self.record(.created, for: record.id, at: record.createdAt, to: record.quadrant, due: record.due)
                if let completedAt = record.completedAt {
                    self.record(.completed, for: record.id, at: completedAt)
                }
            }
            inserted.append(record.id)
            for (position, attachment) in (files[record.id] ?? []).enumerated() {
                guard let url = attachments?.committedFile(attachment, todoID: record.id) else { continue }
                context.insert(StoredAttachment(
                    id: attachment.id, todoID: record.id, name: attachment.name, position: position,
                    data: try Data(contentsOf: url), updatedAt: stamp
                ))
            }
        }
        var eventIDs = try allEventIDs()
        var insertedEvents = 0
        for event in events where eventIDs.insert(event.id).inserted {
            context.insert(TodoEvent(record: event))
            insertedEvents += 1
        }
        guard !inserted.isEmpty || insertedEvents > 0 else { return InsertResult(todoIDs: [], eventCount: 0) }
        try commit()
        return InsertResult(todoIDs: inserted, eventCount: insertedEvents)
    }

    /// Changes a todo, keeping its due date. Moving it to another quadrant bumps `sortDate` so it
    /// shows on top there.
    public func update(id: UUID, title: String, note: String, quadrant: Quadrant) throws {
        try update(id: id, title: title, note: note, quadrant: quadrant, due: try require(id).survivor.due)
    }

    /// Changes a todo, its due date included (`nil` removes it). Moving it to another quadrant
    /// bumps `sortDate` so it shows on top there.
    public func update(id: UUID, title: String, note: String, quadrant: Quadrant, due: Date?) throws {
        let title = try Self.validated(title)
        let due = due.wholeMilliseconds
        let rows = try require(id)
        let todo = rows.survivor
        // An untouched edit is a no-op: don't write or reload widgets.
        guard todo.title != title || todo.note != note || todo.quadrant != quadrant || todo.due != due else { return }
        let stamp = now()
        todo.title = title
        todo.note = note
        changeDue(of: todo, to: due, at: stamp)
        moveOnTop(todo, to: quadrant, at: stamp)
        todo.updatedAt = stamp
        try commit(rows)
    }

    /// Sets (or with `nil` removes) a todo's due date. The same date again writes nothing.
    /// Due dates never change the quadrant or the order.
    public func setDue(id: UUID, to due: Date?) throws {
        try setDue(id: id, to: due, snoozed: false, at: now())
    }

    private func setDue(id: UUID, to due: Date?, snoozed: Bool, at stamp: Date) throws {
        let due = due.wholeMilliseconds
        let rows = try require(id)
        let todo = rows.survivor
        guard todo.due != due else { return }
        changeDue(of: todo, to: due, snoozed: snoozed, at: stamp)
        todo.updatedAt = stamp
        try commit(rows)
    }

    /// Removes a todo's due date.
    public func clearDue(id: UUID) throws {
        try setDue(id: id, to: nil)
    }

    /// Moves the due date to `interval` from now (the notification's "Snooze 1 h").
    public func snooze(id: UUID, by interval: TimeInterval) throws {
        let stamp = now()
        try setDue(id: id, to: stamp.addingTimeInterval(interval), snoozed: true, at: stamp)
    }

    /// Moves the due date to `date` (the notification's "Tomorrow 9:00").
    public func snooze(id: UUID, until date: Date) throws {
        try setDue(id: id, to: date, snoozed: true, at: now())
    }

    /// Moves a todo to another quadrant (Browse's ⌘1–4 / move picker): like an edit-modal move
    /// in `update`, `sortDate` is bumped so it lands on top there. Returns the `sortDate` it had
    /// before, for `moveBack`. Moving to its own quadrant writes nothing.
    @discardableResult
    public func move(id: UUID, to quadrant: Quadrant) throws -> Date {
        let rows = try require(id)
        let todo = rows.survivor
        let previous = todo.sortDate
        guard todo.quadrant != quadrant else { return previous }
        let stamp = now()
        moveOnTop(todo, to: quadrant, at: stamp)
        todo.updatedAt = stamp
        try commit(rows)
        return previous
    }

    /// Moves a todo to `index` of `quadrant`'s open todos (Overview drag and drop; a drop on the
    /// header is index 0). `index` counts the other todos there and is clamped to their count.
    /// The target's `sortDate`s are rewritten downwards from now, so the order holds and a todo
    /// added later still lands on top. Returns the `sortDate` the todo had before, for
    /// `moveBack` (⌘Z). Within its own quadrant this reorders; already there writes nothing.
    @discardableResult
    public func move(id: UUID, to quadrant: Quadrant, at index: Int) throws -> Date {
        let rows = try require(id)
        let todo = rows.survivor
        let previous = todo.sortDate
        let current = try openRows(in: quadrant)
        var ordered = current.filter { $0.id != id }
        ordered.insert(rows, at: min(max(index, 0), ordered.count))
        guard ordered.map(\.id) != current.map(\.id) else { return previous } // already there
        let stamp = now()
        recordMove(of: todo, to: quadrant, at: stamp)
        todo.quadrant = quadrant
        todo.updatedAt = stamp
        let newest = max(stamp, ordered.first(where: { $0.id != id })?.survivor.sortDate ?? .distantPast)
        for (position, item) in ordered.enumerated() {
            setSortDate(of: item.survivor, to: newest.addingTimeInterval(-Double(position) * 0.001), at: stamp)
        }
        try commit(ordered)
        return previous
    }

    /// Takes back a `move` (Browse's ⌘Z): the todo returns to `quadrant` with the `sortDate`
    /// `move` returned, so it is back at the position it had there.
    public func moveBack(id: UUID, to quadrant: Quadrant, sortDate: Date) throws {
        let sortDate = sortDate.wholeMilliseconds
        let rows = try require(id)
        let todo = rows.survivor
        guard todo.quadrant != quadrant || todo.sortDate != sortDate else { return }
        let stamp = now()
        recordMove(of: todo, to: quadrant, at: stamp)
        todo.quadrant = quadrant
        todo.sortDate = sortDate
        todo.updatedAt = stamp
        try commit(rows)
    }

    /// Archives the todo. Completing an already archived todo keeps its original `completedAt`.
    /// The due date stays (its notification is cancelled by the next notification sync).
    public func complete(id: UUID) throws {
        let rows = try require(id)
        let todo = rows.survivor
        guard todo.completedAt == nil else { return } // no-op: don't write or reload widgets
        let stamp = now()
        todo.completedAt = stamp
        todo.updatedAt = stamp
        record(.completed, for: id, at: stamp)
        try commit(rows)
    }

    /// Brings an archived todo back into its original quadrant, on top: `sortDate` is bumped so
    /// an undone tick doesn't vanish under "+N more". With `onTop` false (Browse's ⌘Z, moments
    /// after the tick) `sortDate` is left alone, so the todo returns to the position it had.
    /// Restoring an open todo does nothing. The due date is kept.
    public func restore(id: UUID, onTop: Bool = true) throws {
        let rows = try require(id)
        let todo = rows.survivor
        guard todo.completedAt != nil else { return }
        let stamp = now()
        todo.completedAt = nil
        if onTop { todo.sortDate = stamp }
        todo.updatedAt = stamp
        record(.reopened, for: id, at: stamp)
        try commit(rows)
    }

    /// Puts a quadrant's open todos in the given order (e.g. after a drag). Rewrites `sortDate`
    /// downwards from the newest one already there, so the order holds and a todo added later
    /// still lands on top. Open todos missing from `ids` keep their relative order after the
    /// listed ones; unknown ids are ignored.
    public func reorder(_ ids: [UUID], in quadrant: Quadrant) throws {
        let todos = try openRows(in: quadrant)
        guard let newest = todos.first?.survivor.sortDate else { return }
        let byID = Dictionary(todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered = ids.compactMap { byID[$0] }
        let listed = Set(ordered.map(\.id))
        ordered += todos.filter { !listed.contains($0.id) }
        guard ordered.map(\.id) != todos.map(\.id) else { return } // unchanged: no write
        let stamp = now()
        for (index, todo) in ordered.enumerated() {
            setSortDate(of: todo.survivor, to: newest.addingTimeInterval(-Double(index) * 0.001), at: stamp)
        }
        try commit(ordered)
    }

    /// Deletes the todo (every row with this id, should duplicates exist) and its local attachment
    /// files. Its events stay, plus one `deleted` one.
    ///
    /// The attachment rows are not deleted here: if another Mac edits the todo before it sees the
    /// delete, the todo survives (`StoreMaintenance.removeDeletedTodos` keeps a row written after
    /// the event) and must still have its attachments. `removeOrphanedAttachments` deletes the
    /// rows of a todo that is really gone, an hour after the `deleted` event.
    public func delete(id: UUID) throws {
        let rows = try require(id)
        record(.deleted, for: id, at: now(), from: rows.survivor.quadrant)
        rows.all.forEach(context.delete)
        try commit()
        attachments?.removeAll(for: id)
    }

    // MARK: Cleanups

    /// Removes rows that share an id with a row of other values, on a background context: per id
    /// the survivor's values stay (`Todo.prefers(_:over:)`, `TodoEvent.prefers(_:over:)`: the
    /// newest `updatedAt` first, then a total order over the stored values), so every device
    /// deletes the same records. Fully identical rows are all kept; reads show them as one.
    /// Records no events. Calls `didWrite` (widgets, `StoreChangeSignal`) only when it removed
    /// something; a clean store isn't written.
    @discardableResult
    public func removeDuplicates() async throws -> DuplicateCleanup {
        let result = try await StoreMaintenance.removeDuplicates(modelContainer)
        if !result.isEmpty { didWrite?() }
        return result
    }

    /// Removes todos that came back after they were deleted: rows whose `updatedAt` is at or
    /// before the newest `deleted` event of their id (see `StoreMaintenance.removeDeletedTodos`),
    /// on a background context. Their attachment folders are left to
    /// `removeOrphanedAttachments`. Calls `didWrite` only when it removed something. Returns the
    /// ids removed.
    @discardableResult
    public func removeDeletedTodos() async throws -> Set<UUID> {
        let removed = try await StoreMaintenance.removeDeletedTodos(modelContainer)
        if !removed.isEmpty { didWrite?() }
        return removed
    }

    /// How long a fresh attachment folder is safe from `removeOrphanedAttachments`: a new todo's
    /// files are committed before the todo is saved, and an import's before its insert. Also how
    /// long the attachment rows of a deleted todo wait after the `deleted` event.
    public static let orphanGracePeriod: TimeInterval = 60 * 60

    /// How old attachment rows must be before `removeOrphanedAttachments` deletes those of a todo
    /// with no row and no events at all (a crash between saving the files and creating the todo).
    public static let unclaimedAttachmentRetention: TimeInterval = 30 * 24 * 3600

    /// Takes the attachment folders of todo ids that no longer exist in the store (e.g. deleted
    /// on another device) out of service. Never deletes them: each moves to
    /// `Attachments/.trash/<id>/` and is deleted by a later run once it has been there
    /// `AttachmentStore.trashRetention` (14 days, by the store's clock).
    ///
    /// Folders changed within `gracePeriod` before the clock's now are left alone, and so are
    /// staging and import areas. Two brakes stop a cleanup that would be a mass deletion if the
    /// store were wrong (say, wiped by an iCloud sign-out): it does nothing, and logs it, when
    /// the store has no todos, or when more than 3 folders are candidates and more than half of
    /// them look orphaned. The trash is only emptied on a run that passes the brakes, and never
    /// of a todo that exists. A trashed folder whose todo exists again (it came back through
    /// sync) is moved back first, unless it has a new folder already.
    ///
    /// The folders are local copies; the attachments themselves are rows in the store. First,
    /// rows of a todo that is gone are deleted (`StoreMaintenance.removeOrphanedAttachmentRows`):
    /// when the todo has no row and its newest `deleted` event is older than `gracePeriod`, or
    /// when it has no row and no events at all and its rows are older than
    /// `unclaimedAttachmentRetention`, and the same two brakes pass. A todo that has events but
    /// no `deleted` one may only have failed to arrive, and a recent one may still be arriving;
    /// their attachments stay. That deletion syncs, and calls `didWrite`.
    ///
    /// The file work runs off the main actor, the store work on a background context. Returns
    /// the number of folders moved to the trash.
    @discardableResult
    public func removeOrphanedAttachments(gracePeriod: TimeInterval = orphanGracePeriod) async throws -> Int {
        let stamp = now()
        let removedRows = try await StoreMaintenance.removeOrphanedAttachmentRows(
            modelContainer, deletedBefore: stamp.addingTimeInterval(-gracePeriod),
            unclaimedBefore: stamp.addingTimeInterval(-Self.unclaimedAttachmentRetention)
        )
        if removedRows > 0 {
            Self.log.notice("Removed \(removedRows) attachments of todos that are gone")
            didWrite?()
        }
        guard let attachments else { return 0 }
        let candidates = await Self.todoFolders(in: attachments, changedBefore: stamp.addingTimeInterval(-gracePeriod))
        // Read after listing: a todo saved meanwhile is in here, its folder spared.
        let existing = try await StoreMaintenance.todoIDs(modelContainer)
        guard !existing.isEmpty else {
            if !candidates.isEmpty { Self.log.notice("Orphan cleanup skipped: the store has no todos") }
            return 0
        }
        // A todo that came back through sync gets its trashed files back first.
        await Self.restoreTrashed(for: existing, in: attachments)
        var orphans = candidates.subtracting(existing)
        if candidates.count > 3, orphans.count * 2 > candidates.count {
            Self.log.notice("Orphan cleanup skipped: \(orphans.count) of \(candidates.count) attachment folders look orphaned")
            return 0
        }
        // Read again right before the move: rows that arrived meanwhile keep their folders.
        let latest = try await StoreMaintenance.todoIDs(modelContainer)
        orphans.subtract(latest)
        return await Self.trash(orphans, keeping: existing.union(latest), in: attachments, at: stamp)
    }

    nonisolated private static let log = Logger(subsystem: "lueddemann.howy", category: "TodoStore")

    @concurrent
    nonisolated private static func todoFolders(in attachments: AttachmentStore, changedBefore cutoff: Date) async -> Set<UUID> {
        attachments.todoFolderIDs(changedBefore: cutoff)
    }

    /// Moves `ids` to the trash and empties what has been there longer than the retention,
    /// except the entries of todos in `keeping` (they exist).
    @concurrent
    nonisolated private static func trash(_ ids: Set<UUID>, keeping: Set<UUID>, in attachments: AttachmentStore, at stamp: Date) async -> Int {
        let moved = ids.filter { attachments.moveToTrash($0, at: stamp) }.count
        attachments.purgeTrash(olderThan: stamp.addingTimeInterval(-AttachmentStore.trashRetention), keeping: keeping)
        return moved
    }

    @concurrent
    nonisolated private static func restoreTrashed(for ids: Set<UUID>, in attachments: AttachmentStore) async {
        let restored = attachments.restoreFromTrash(for: ids)
        if restored > 0 { log.notice("Restored the attachments of \(restored) todos that came back") }
    }

    /// Makes `list` the todo's attachments, in this order, in one save: an attachment the todo
    /// has keeps its bytes (a new name or place is written), a staged one is moved into the
    /// todo's folder and stored, and one with neither a row nor a file is dropped. Calls
    /// `didWrite` (widgets show a paperclip) only when something changed. Records no events.
    ///
    /// `original` is the list the edit started from (the one the user saw when the panel opened,
    /// or when the stashed draft was first made). Only attachments in it and missing from `list`
    /// are deleted (rows and local copies): the user removed those. A row in neither (another
    /// Mac added it since, and sync brought it) is kept and goes after the listed ones. Without
    /// `original`, `list` is taken as complete and everything not in it is deleted.
    ///
    /// A todo whose attachments an older build kept in `attachments.json` (not adopted yet) has
    /// that list removed by this save: its attachments are in `list`, which `attachmentList`
    /// showed with them, and the ones missing from `list` were removed by the user.
    ///
    /// Works for an id with no todo yet: a new todo's attachments are saved just before it.
    public func setAttachments(_ list: [TodoAttachment], for id: UUID, startedWith original: [TodoAttachment]? = nil) throws {
        let existing = Dictionary(grouping: try attachmentRows(for: id), by: \.id)
        let removable = original.map { Set($0.map(\.id)) }
        let stamp = now()
        var kept = Set<UUID>()
        var changed = false
        for attachment in list where !kept.contains(attachment.id) {
            let position = kept.count
            if let rows = existing[attachment.id] {
                for row in rows where row.name != attachment.name || row.position != position {
                    row.name = attachment.name
                    row.position = position
                    row.updatedAt = stamp
                    changed = true
                }
            } else {
                guard let url = try attachments?.commitStaged(attachment, for: id) else { continue }
                context.insert(StoredAttachment(
                    id: attachment.id, todoID: id, name: attachment.name, position: position,
                    data: try Data(contentsOf: url), updatedAt: stamp
                ))
                changed = true
            }
            kept.insert(attachment.id)
        }
        // Rows the edit didn't start with (added on another Mac meanwhile) stay, after the list.
        if let removable {
            let others = existing.filter { !kept.contains($0.key) && !removable.contains($0.key) }
            for survivor in Array(others.values.joined()).orderedSurvivors {
                let position = kept.count
                for row in others[survivor.id] ?? [] where row.position != position {
                    row.position = position
                    row.updatedAt = stamp
                    changed = true
                }
                kept.insert(survivor.id)
            }
        }
        for (attachmentID, rows) in existing where !kept.contains(attachmentID) {
            rows.forEach(context.delete)
            changed = true
        }
        let hasLegacyList = attachments?.legacyAttachments(for: id) != nil
        guard changed || hasLegacyList else { return }
        if changed { try commit() }
        if hasLegacyList { attachments?.removeLegacyList(for: id) }
        attachments?.prune(id, keeping: kept)
    }

    /// Deletes every attachment of `id`, in the store and on disk, without a todo write (a new
    /// todo whose save failed after its attachments were saved).
    public func discardAttachments(for id: UUID) {
        do {
            let rows = try attachmentRows(for: id)
            if !rows.isEmpty {
                rows.forEach(context.delete)
                try commit()
            }
        } catch {
            context.rollback()
            Self.log.error("Discarding attachments failed: \(error, privacy: .public)")
        }
        attachments?.removeAll(for: id)
    }

    /// Moves the attachments that builds before schema v4 kept only on disk (a todo folder with
    /// `attachments.json`) into the store, so they sync. Runs on background contexts, at launch
    /// and again with the cleanups after each sync import (a todo may arrive later). Only
    /// folders of todos the store has are taken, each attachment once (an id already stored is
    /// skipped), after the rows the todo already has. Todo by todo: each is saved on its own, so
    /// a file that can't be read, or a failed save, keeps only that todo's list for a retry; the
    /// list of a todo is removed once all its readable files are stored. Folders of todos the
    /// store doesn't have stay as they are (the todo may still arrive; the orphan cleanup
    /// handles the rest). Until a todo is adopted, `attachmentList` shows its old list. Adopted
    /// rows carry no edit time (`updatedAt` is `.distantPast`), so two Macs adopting one file
    /// write identical rows. Calls `didWrite` only when it stored something. Returns how many.
    @discardableResult
    public func adoptLegacyAttachments() async -> Int {
        guard let attachments else { return 0 }
        let result = await StoreMaintenance.adoptLegacyAttachments(modelContainer, files: attachments)
        if result.incompleteTodos > 0 {
            Self.log.error("\(result.incompleteTodos) todos have attachment files that couldn't be read; they stay as files for the next run")
        }
        if result.failedTodos > 0 {
            Self.log.error("Moving the attachments of \(result.failedTodos) todos into the store failed; the next run tries again")
        }
        if result.adopted > 0 {
            Self.log.notice("Moved \(result.adopted) attachments into the store")
            didWrite?()
        }
        return result.adopted
    }

    /// Writes the local copies this Mac lacks of a todo's attachments from the store's bytes, on
    /// a background context and off the main actor (a file that came through sync has no copy
    /// yet). The edit panel calls it when it opens; nothing else writes copies. Returns how
    /// many it wrote. Attachments whose bytes haven't arrived are skipped.
    @discardableResult
    public func materializeAttachments(for todoID: UUID) async throws -> Int {
        guard let attachments else { return 0 }
        return try await StoreMaintenance.writeLocalCopies(modelContainer, files: attachments, todoID: todoID)
    }

    /// The file of an attachment, for opening it: the local copy or a staged file, if there is
    /// one. Only looks; it never writes (it runs while a view renders). `nil` when this Mac has
    /// no file yet: `materializeAttachments` makes one from the store.
    public func attachmentURL(for attachment: TodoAttachment, todoID: UUID?) -> URL? {
        attachments?.url(for: attachment, todoID: todoID)
    }

    /// Deletes archived todos (and their attachments, rows and files, in the same save: a todo
    /// completed that long ago coming back through a racing edit is too unlikely to keep rows
    /// for, and a purge records no event for the orphan cleanup to go by) completed longer than
    /// `retention` before `now` (default: the injected clock). A todo completed exactly `retention` ago is kept. Returns the
    /// number removed. Their events stay, and the purge records none: the history ends at
    /// `completed`.
    @discardableResult
    public func purgeArchive(now: Date? = nil, retention: ArchiveRetention = .default) throws -> Int {
        let cutoff = (now ?? self.now()).addingTimeInterval(-retention.interval)
        // A fresh context, read right before the delete: a row that arrived or changed through
        // sync since this store's own context last read (a twin completed again, an edit that
        // reopened the todo) is seen, not deleted from a stale snapshot.
        let fresh = ModelContext(modelContainer)
        let expired = try fresh.fetch(FetchDescriptor<Todo>(predicate: #Predicate { todo in
            todo.completedAt.flatMap { $0 < cutoff } == true
        }))
        guard !expired.isEmpty else { return 0 }
        var ids: [UUID] = []
        for id in Set(expired.map(\.id)) {
            let all = try fresh.fetch(FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id }))
            // The todo counts as it reads: by its survivor (`DuplicateRules`).
            guard let survivor = DuplicateRules.survivor(of: all), let done = survivor.completedAt, done < cutoff else { continue }
            all.forEach(fresh.delete)
            try fresh.fetch(FetchDescriptor<StoredAttachment>(predicate: #Predicate { $0.todoID == id })).forEach(fresh.delete)
            ids.append(id)
        }
        guard !ids.isEmpty else { return 0 }
        do {
            try fresh.save()
        } catch {
            fresh.rollback()
            throw error
        }
        didWrite?()
        // The files go only when no row of the id is left (one may have come back since).
        for id in ids where try fresh.fetchCount(FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id })) == 0 {
            attachments?.removeAll(for: id)
        }
        return ids.count
    }

    // MARK: Reads

    /// The todo with this id (the survivor, should duplicates exist).
    public func todo(id: UUID) throws -> Todo? {
        try rows(id: id)?.survivor
    }

    /// Every row with this id, as stored: one, unless duplicates exist (the id isn't unique in
    /// schema v3). Only for tests and the cleanups; everything else reads through `rows(id:)`.
    func todos(id: UUID) throws -> [Todo] {
        try context.fetch(FetchDescriptor<Todo>(predicate: #Predicate { $0.id == id }))
    }

    /// Every todo, open and archived, oldest `createdAt` first (export).
    public func allTodos() throws -> [Todo] {
        try fetchTodos(FetchDescriptor<Todo>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    /// A todo's events, oldest first (by `date`, then `seq`). Kept after the todo is deleted or
    /// purged. Events that share an id show once (`DuplicateRules`).
    public func events(for todoID: UUID) throws -> [TodoEvent] {
        try fetchEvents(FetchDescriptor<TodoEvent>(
            predicate: #Predicate { $0.todoID == todoID },
            sortBy: Self.eventOrder
        ))
    }

    /// Every event of every todo, oldest first (by `date`, then `seq`), one per id.
    public func allEvents() throws -> [TodoEvent] {
        DuplicateRules.collapsed(try context.fetch(FetchDescriptor<TodoEvent>(sortBy: Self.eventOrder)))
    }

    private static let eventOrder = [SortDescriptor(\TodoEvent.date), SortDescriptor(\TodoEvent.seq)]

    /// The ids of all todos.
    func allIDs() throws -> Set<UUID> {
        var descriptor = FetchDescriptor<Todo>()
        descriptor.propertiesToFetch = [\.id]
        return Set(try context.fetch(descriptor).map(\.id))
    }

    /// The ids of all events.
    func allEventIDs() throws -> Set<UUID> {
        var descriptor = FetchDescriptor<TodoEvent>()
        descriptor.propertiesToFetch = [\.id]
        return Set(try context.fetch(descriptor).map(\.id))
    }

    /// The injected clock's time.
    var currentDate: Date { now() }

    /// Open todos in a quadrant, newest `sortDate` first.
    public func openTodos(in quadrant: Quadrant) throws -> [Todo] {
        try openRows(in: quadrant).map(\.survivor)
    }

    private func openRows(in quadrant: Quadrant, repeated: Set<UUID>? = nil) throws -> [TodoRows] {
        let raw = quadrant.rawValue
        return try fetchRows(FetchDescriptor<Todo>(
            predicate: #Predicate { $0.completedAt == nil && $0.quadrantRaw == raw },
            sortBy: [SortDescriptor(\.sortDate, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]
        ), repeated: repeated)
    }

    /// All archived todos, most recently completed first.
    public func archivedTodos() throws -> [Todo] {
        try fetchTodos(FetchDescriptor<Todo>(
            predicate: #Predicate { $0.completedAt != nil },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        ))
    }

    /// Open todos for every quadrant as value snapshots, newest first (input for `WidgetContentBuilder`).
    public func openSnapshots() throws -> [Quadrant: [TodoSnapshot]] {
        var result: [Quadrant: [TodoSnapshot]] = [:]
        let repeated = try repeatedTodoIDs() // once for all four quadrants
        let counts = try attachmentCounts()
        for quadrant in Quadrant.allCases {
            result[quadrant] = try openRows(in: quadrant, repeated: repeated).map { snapshot(of: $0.survivor, counts: counts) }
        }
        return result
    }

    /// Open todos that have a due date, earliest due first (input for `NotificationPlan`).
    public func openDueSnapshots() throws -> [TodoSnapshot] {
        let counts = try attachmentCounts()
        return try fetchTodos(FetchDescriptor<Todo>(
            predicate: #Predicate { $0.completedAt == nil && $0.due != nil },
            sortBy: [SortDescriptor(\.createdAt)]
        ))
        .map { snapshot(of: $0, counts: counts) }
        .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// A todo as a value, with its attachment count.
    public func snapshot(of todo: Todo) -> TodoSnapshot {
        var snapshot = todo.snapshot
        snapshot.attachmentCount = attachmentList(for: todo.id).count
        return snapshot
    }

    private func snapshot(of todo: Todo, counts: [UUID: Int]) -> TodoSnapshot {
        var snapshot = todo.snapshot
        snapshot.attachmentCount = counts[todo.id] ?? 0
        return snapshot
    }

    /// A todo's attachments, in order (one per id, should duplicates exist). Reads the store,
    /// so attachments that came through sync are in it whether or not this Mac has their files.
    /// Attachments an older build kept in `attachments.json` and that aren't adopted yet follow
    /// the stored ones, so they show before the adoption ran.
    public func attachmentList(for id: UUID) -> [TodoAttachment] {
        do {
            let stored = try attachmentRows(for: id).orderedSurvivors.map(\.attachment)
            return stored + (attachments?.unadoptedAttachments(for: id, excluding: Set(stored.map(\.id))) ?? [])
        } catch {
            Self.log.error("Reading attachments failed: \(error, privacy: .public)")
            return []
        }
    }

    /// Every attachment row of a todo, as stored (duplicates included). The bytes aren't loaded
    /// until `data` is read.
    func attachmentRows(for todoID: UUID) throws -> [StoredAttachment] {
        try context.fetch(FetchDescriptor<StoredAttachment>(predicate: #Predicate { $0.todoID == todoID }))
    }

    /// How many attachments each todo has (distinct ids), read without the bytes.
    private func attachmentCounts() throws -> [UUID: Int] {
        var descriptor = FetchDescriptor<StoredAttachment>()
        descriptor.propertiesToFetch = [\.id, \.todoID]
        var ids: [UUID: Set<UUID>] = [:]
        for row in try context.fetch(descriptor) { ids[row.todoID, default: []].insert(row.id) }
        var counts = ids.mapValues(\.count)
        // Attachments of an older build, not adopted yet.
        for todoID in attachments?.legacyTodoIDs() ?? [] {
            let extra = attachments?.unadoptedAttachments(for: todoID, excluding: ids[todoID] ?? []).count ?? 0
            if extra > 0 { counts[todoID, default: 0] += extra }
        }
        return counts
    }

    // MARK: Duplicate-aware fetches

    /// Every row of one todo id, read through the survivor (`DuplicateRules`). Writes change the
    /// survivor and `commit` copies its values to the other rows, so they stay identical (and
    /// rows that differed become copies of the survivor).
    struct TodoRows {
        let survivor: Todo
        let all: [Todo]
        /// The survivor's values when the rows were read, before the write.
        private let before: Values

        var id: UUID { survivor.id }

        init(survivor: Todo, all: [Todo]) {
            self.survivor = survivor
            self.all = all
            self.before = Values(survivor)
        }

        init(single todo: Todo) {
            self.init(survivor: todo, all: [todo])
        }

        /// Every stored value but `id`.
        private struct Values {
            var title: String
            var note: String
            var quadrantRaw: Int
            var createdAt: Date
            var sortDate: Date
            var completedAt: Date?
            var due: Date?
            var updatedAt: Date

            init(_ todo: Todo) {
                title = todo.title
                note = todo.note
                quadrantRaw = todo.quadrantRaw
                createdAt = todo.createdAt
                sortDate = todo.sortDate
                completedAt = todo.completedAt
                due = todo.due
                updatedAt = todo.updatedAt
            }
        }

        /// Copies to the other rows the values this write changed on the survivor (against the
        /// snapshot taken when the rows were read), so a twin that got a newer value for a field
        /// the write didn't touch keeps it. Dates compare at the millisecond, and a value that
        /// is the same isn't set, so an unchanged row isn't marked as changed (and not uploaded).
        ///
        /// A twin that would still win over the survivor afterwards gets every value, so the
        /// write can't be hidden by an older row.
        func mirrorSurvivor() {
            let source = survivor
            let now = Values(source)
            for row in all where row !== source {
                if now.title != before.title, row.title != now.title { row.title = now.title }
                if now.note != before.note, row.note != now.note { row.note = now.note }
                if now.quadrantRaw != before.quadrantRaw, row.quadrantRaw != now.quadrantRaw { row.quadrantRaw = now.quadrantRaw }
                if Self.differs(now.createdAt, before.createdAt), Self.differs(row.createdAt, now.createdAt) { row.createdAt = now.createdAt }
                if Self.differs(now.sortDate, before.sortDate), Self.differs(row.sortDate, now.sortDate) { row.sortDate = now.sortDate }
                if Self.differs(now.completedAt, before.completedAt), Self.differs(row.completedAt, now.completedAt) { row.completedAt = now.completedAt }
                if Self.differs(now.due, before.due), Self.differs(row.due, now.due) { row.due = now.due }
                if Self.differs(now.updatedAt, before.updatedAt), Self.differs(row.updatedAt, now.updatedAt) { row.updatedAt = now.updatedAt }
                if Todo.prefers(row.duplicateKey, over: source.duplicateKey) { copy(source, to: row) }
            }
        }

        /// Every stored value of `source` onto `row` (only those that differ).
        private func copy(_ source: Todo, to row: Todo) {
            if row.title != source.title { row.title = source.title }
            if row.note != source.note { row.note = source.note }
            if row.quadrantRaw != source.quadrantRaw { row.quadrantRaw = source.quadrantRaw }
            if Self.differs(row.createdAt, source.createdAt) { row.createdAt = source.createdAt }
            if Self.differs(row.sortDate, source.sortDate) { row.sortDate = source.sortDate }
            if Self.differs(row.completedAt, source.completedAt) { row.completedAt = source.completedAt }
            if Self.differs(row.due, source.due) { row.due = source.due }
            if Self.differs(row.updatedAt, source.updatedAt) { row.updatedAt = source.updatedAt }
        }

        private static func differs(_ a: Date, _ b: Date) -> Bool {
            DuplicateRules.milliseconds(a) != DuplicateRules.milliseconds(b)
        }

        private static func differs(_ a: Date?, _ b: Date?) -> Bool {
            DuplicateRules.milliseconds(a) != DuplicateRules.milliseconds(b)
        }
    }

    /// The rows of one id, or `nil` if there are none.
    private func rows(id: UUID) throws -> TodoRows? {
        let all = try todos(id: id)
        return DuplicateRules.survivor(of: all).map { TodoRows(survivor: $0, all: all) }
    }

    /// Fetches todos and collapses rows that share an id to their survivor, keeping the fetch's
    /// order. The one way `TodoStore` reads todos.
    private func fetchTodos(_ descriptor: FetchDescriptor<Todo>) throws -> [Todo] {
        try fetchRows(descriptor).map(\.survivor)
    }

    /// `fetchTodos`, with every row of each todo. A todo is in the result when its survivor
    /// matches the descriptor (a duplicate that matches while its survivor doesn't is left out),
    /// at the survivor's place in the fetch order.
    ///
    /// Not for a descriptor with `fetchLimit` or `fetchOffset`: a page could cut a group of rows
    /// that share an id, and a todo whose survivor falls outside it would show as missing.
    /// `repeated` is the result of `repeatedTodoIDs()` when the caller has it already.
    private func fetchRows(_ descriptor: FetchDescriptor<Todo>, repeated known: Set<UUID>? = nil) throws -> [TodoRows] {
        precondition(descriptor.fetchLimit == nil && (descriptor.fetchOffset ?? 0) == 0, "fetchRows can't page: duplicates need every row")
        let fetched = try context.fetch(descriptor)
        guard !fetched.isEmpty else { return [] }
        let repeated = try known ?? repeatedTodoIDs()
        guard !repeated.isEmpty else { return fetched.map(TodoRows.init(single:)) }
        var groups: [UUID: TodoRows] = [:]
        var result: [TodoRows] = []
        for row in fetched {
            guard repeated.contains(row.id) else {
                result.append(TodoRows(single: row))
                continue
            }
            if groups[row.id] == nil { groups[row.id] = try rows(id: row.id) }
            if let group = groups[row.id], group.survivor === row { result.append(group) }
        }
        return result
    }

    /// Fetches events and collapses those that share an id to their survivor, keeping the
    /// fetch's order (an event is left out when its survivor doesn't match the descriptor).
    ///
    /// Only the ids of the fetched events are looked up (one query by id), not the whole log, so
    /// a read of one todo's events doesn't scan every event.
    private func fetchEvents(_ descriptor: FetchDescriptor<TodoEvent>) throws -> [TodoEvent] {
        let fetched = try context.fetch(descriptor)
        guard !fetched.isEmpty else { return [] }
        let ids = Array(Set(fetched.map(\.id)))
        let sharing = try context.fetch(FetchDescriptor<TodoEvent>(predicate: #Predicate { ids.contains($0.id) }))
        let groups = Dictionary(grouping: sharing, by: \.id)
        guard groups.count < sharing.count else { return fetched } // no id twice
        let survivors = groups.mapValues { DuplicateRules.survivor(of: $0) }
        return fetched.filter { survivors[$0.id].flatMap { $0 } === $0 }
    }

    /// The todo ids that more than one row has.
    private func repeatedTodoIDs() throws -> Set<UUID> {
        var descriptor = FetchDescriptor<Todo>()
        descriptor.propertiesToFetch = [\.id]
        return DuplicateRules.repeated(try context.fetch(descriptor).map(\.id))
    }

    // MARK: Helpers

    private static func validated(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TodoStoreError.emptyTitle }
        return trimmed
    }

    /// The one quadrant change (edit modal and Browse): on top of the new quadrant. Records the
    /// move.
    private func moveOnTop(_ todo: Todo, to quadrant: Quadrant, at stamp: Date) {
        guard todo.quadrant != quadrant else { return }
        recordMove(of: todo, to: quadrant, at: stamp)
        todo.quadrant = quadrant
        todo.sortDate = stamp
    }

    /// Sets the due date and records the matching event (nothing when unchanged). Doesn't
    /// stamp `updatedAt`; the caller does.
    private func changeDue(of todo: Todo, to due: Date?, snoozed: Bool = false, at stamp: Date) {
        guard todo.due != due else { return }
        let kind: TodoEventKind = switch (todo.due, due) {
        case (_, nil): .dueRemoved
        case (nil, _): .dueSet // also a snooze of an undated todo
        case _ where snoozed: .dueSnoozed
        default: .dueChanged
        }
        record(kind, for: todo.id, at: stamp, previousDue: todo.due, due: due)
        todo.due = due
    }

    /// Records a `moved` event if `quadrant` is another one than the todo's.
    private func recordMove(of todo: Todo, to quadrant: Quadrant, at stamp: Date) {
        guard todo.quadrant != quadrant else { return }
        record(.moved, for: todo.id, at: stamp, from: todo.quadrant, to: quadrant)
    }

    /// Rewrites a `sortDate` (reorders), stamping `updatedAt` only if it really changes.
    private func setSortDate(of todo: Todo, to date: Date, at stamp: Date) {
        let date = date.wholeMilliseconds
        guard todo.sortDate != date else { return }
        todo.sortDate = date
        todo.updatedAt = stamp
    }

    /// Inserts an event into the context; the caller's `commit` saves it with the change.
    private func record(
        _ kind: TodoEventKind, for todoID: UUID, at date: Date,
        from: Quadrant? = nil, to: Quadrant? = nil, previousDue: Date? = nil, due: Date? = nil
    ) {
        context.insert(TodoEvent(
            todoID: todoID, kind: kind, date: date,
            from: from, to: to, previousDue: previousDue, due: due, seq: nextSeq(for: todoID)
        ))
    }

    /// The highest `seq` among the todo's events (saved or pending) plus one; 0 for the first.
    private func nextSeq(for todoID: UUID) -> Int {
        var highest = pendingSeq[todoID]
        if highest == nil {
            var descriptor = FetchDescriptor<TodoEvent>(
                predicate: #Predicate { $0.todoID == todoID },
                sortBy: [SortDescriptor(\.seq, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            highest = (try? context.fetch(descriptor))?.first?.seq
        }
        let next = (highest ?? -1) + 1
        pendingSeq[todoID] = next
        return next
    }

    private func require(_ id: UUID) throws -> TodoRows {
        guard let rows = try rows(id: id) else { throw TodoStoreError.notFound(id) }
        return rows
    }

    /// Saves the todo and event changes together. The writes went to each todo's survivor;
    /// `rows` lists the todos written, whose other rows get the survivor's values first, in the
    /// same save. On an error the context is rolled back, so a failed write doesn't leak its
    /// pending changes into the next save.
    private func commit(_ rows: TodoRows...) throws {
        try commit(rows)
    }

    private func commit(_ rows: [TodoRows]) throws {
        rows.forEach { $0.mirrorSurvivor() }
        pendingSeq.removeAll()
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        didWrite?()
    }
}
