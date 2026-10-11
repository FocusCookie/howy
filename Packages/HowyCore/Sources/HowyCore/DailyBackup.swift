import Foundation

/// The daily automatic export: the safety net for when the store is lost (e.g. iCloud sign-out
/// wipes it). Each backup is a folder in the same format as Export… (`howy.json` with the
/// history, plus `attachments/`), so Import… restores it.
///
/// - At most one backup per calendar day (of `calendar`, by the store's clock), named
///   `Howy Backup yyyy-MM-dd` so names sort by date. A day's folder without `howy.json` (an
///   interrupted run) is written again.
/// - Only the newest `keep` backups stay; older `Howy Backup …` folders are deleted. Other files
///   in the directory are never touched.
/// - An empty store (no todos and no events) is **not** backed up: a wiped store must not push
///   the good backups out, one day at a time.
///
/// The data is read on a background context; writing and pruning run off the main actor.
@MainActor
public struct DailyBackup {
    public enum Outcome: Hashable, Sendable {
        /// A new backup was written to this folder.
        case created(URL)
        /// Today's backup already exists at this folder; nothing was written.
        case alreadyDone(URL)
        /// The store is empty; nothing was written.
        case skippedEmptyStore
    }

    nonisolated public static let folderPrefix = "Howy Backup "
    /// How many backups stay by default: one week.
    public static let defaultKeep = 7

    public let store: TodoStore
    public let directory: URL
    public let keep: Int
    public let calendar: Calendar
    /// Written to `howy.json` for information.
    public let appVersion: String?

    public init(
        store: TodoStore, directory: URL, keep: Int = defaultKeep,
        calendar: Calendar = .current, appVersion: String? = nil
    ) {
        self.store = store
        self.directory = directory
        self.keep = max(keep, 1)
        self.calendar = calendar
        self.appVersion = appVersion
    }

    /// `<App Group>/Library/Application Support/Backups`.
    public static func sharedDirectory() throws -> URL {
        guard let container = HowyAppGroup.containerURL else {
            throw TodoStoreError.appGroupUnavailable(HowyAppGroup.identifier)
        }
        return container.appending(path: "Library/Application Support/Backups", directoryHint: .isDirectory)
    }

    /// The folder name for the day `date` falls on: `Howy Backup 2026-10-11`.
    public func folderName(for date: Date) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return Self.folderPrefix + String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// Writes today's backup unless it exists or the store is empty, then prunes to `keep`.
    @discardableResult
    public func run() async throws -> Outcome {
        let now = store.currentDate
        let folder = directory.appending(path: folderName(for: now), directoryHint: .isDirectory)
        let maintenance = StoreMaintenance(modelContainer: store.modelContainer)
        let outcome: Outcome
        if await Self.isComplete(folder) {
            outcome = .alreadyDone(folder)
        } else if try await maintenance.isEmpty() {
            outcome = .skippedEmptyStore
        } else {
            let document = try await maintenance.exportDocument(
                appVersion: appVersion, exportedAt: now, attachments: store.attachments
            )
            try await Self.createDirectory(directory)
            _ = try await HowyExporter.write(document, to: folder, files: store.attachments)
            outcome = .created(folder)
        }
        await Self.prune(directory, keep: keep)
        return outcome
    }

    @concurrent
    nonisolated private static func isComplete(_ folder: URL) async -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: HowyFormat.fileName).path(percentEncoded: false))
    }

    @concurrent
    nonisolated private static func createDirectory(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deletes all but the newest `keep` backup folders (by name, which sorts by date).
    @concurrent
    nonisolated private static func prune(_ directory: URL, keep: Int) async {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        let backups = names.filter(isBackupName).sorted(by: >)
        for name in backups.dropFirst(keep) {
            try? fileManager.removeItem(at: directory.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// `Howy Backup ` followed by exactly `yyyy-MM-dd`.
    nonisolated static func isBackupName(_ name: String) -> Bool {
        guard name.hasPrefix(folderPrefix) else { return false }
        let date = Array(name.dropFirst(folderPrefix.count))
        guard date.count == 10, date[4] == "-", date[7] == "-" else { return false }
        return date.enumerated().allSatisfy { index, character in index == 4 || index == 7 || character.isASCII && character.isNumber }
    }
}
