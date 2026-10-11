import Foundation
import os

/// The daily automatic export: the safety net for when the store is lost (e.g. iCloud sign-out
/// wipes it). Each backup is a folder in the same format as Export… (`howy.json` with the
/// history, plus `attachments/`), so Import… restores it.
///
/// - At most one backup per calendar day (of the Gregorian calendar in the current time zone,
///   by the store's clock), named `Howy Backup yyyy-MM-dd` so names sort by date. A backup is
///   *complete* when its folder has `howy.json`; a day's folder without one is written again.
/// - A backup is built in `Howy Backup yyyy-MM-dd.partial` and renamed into place once
///   `howy.json` is written, so a crash or a failed write never leaves a half-written folder
///   under the real name and never costs an existing complete backup. Stale `.partial` folders
///   are removed at the start of a run.
/// - Only the newest `keep` complete backups dated today or earlier stay; older ones are
///   deleted. Folders dated in the future (a clock that jumped) are neither counted nor
///   deleted, the folder just written never is, and a backup that had problems (attachment
///   files it couldn't copy) prunes nothing that run. Other files in the directory are never
///   touched.
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
    nonisolated static let partialSuffix = ".partial"
    /// How many backups stay by default: one week.
    nonisolated public static let defaultKeep = 7

    public let store: TodoStore
    public let directory: URL
    public let keep: Int
    /// Always Gregorian, so names are `yyyy-MM-dd` whatever the user's calendar is; only the
    /// time zone comes from the calendar given to `init`.
    public let calendar: Calendar
    /// Written to `howy.json` for information.
    public let appVersion: String?

    private static let log = Logger(subsystem: "lueddemann.howy", category: "DailyBackup")

    /// `calendar` only supplies the time zone (default: the current one); days are always
    /// counted on the Gregorian calendar.
    public init(
        store: TodoStore, directory: URL, keep: Int = defaultKeep,
        calendar: Calendar? = nil, appVersion: String? = nil
    ) {
        self.store = store
        self.directory = directory
        self.keep = max(keep, 1)
        self.calendar = Self.gregorian(in: calendar?.timeZone ?? .current)
        self.appVersion = appVersion
    }

    nonisolated static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `<App Group>/Library/Application Support/Backups` (in Debug, `Backups-Howy-Debug`:
    /// `TodoStore.storeScopedName`).
    public static func sharedDirectory() throws -> URL {
        guard let container = HowyAppGroup.containerURL else {
            throw TodoStoreError.appGroupUnavailable(HowyAppGroup.identifier)
        }
        return container.appending(
            path: "Library/Application Support/\(TodoStore.storeScopedName("Backups"))", directoryHint: .isDirectory
        )
    }

    /// The folder name for the day `date` falls on: `Howy Backup 2026-10-11`.
    public func folderName(for date: Date) -> String {
        Self.folderName(for: date, calendar: calendar)
    }

    nonisolated static func folderName(for date: Date, calendar: Calendar) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return folderPrefix + String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// Whether the backup for the day `date` falls on is already complete: the cheap file check
    /// the app makes (on wake, on a day change) before it opens a store at all.
    @concurrent
    nonisolated public static func isTodayComplete(in directory: URL, at date: Date, calendar: Calendar? = nil) async -> Bool {
        let calendar = gregorian(in: calendar?.timeZone ?? .current)
        return isComplete(directory.appending(path: folderName(for: date, calendar: calendar), directoryHint: .isDirectory))
    }

    /// Writes today's backup unless it exists or the store is empty, then prunes to `keep`.
    @discardableResult
    public func run() async throws -> Outcome {
        let now = store.currentDate
        let todayName = folderName(for: now)
        let folder = directory.appending(path: todayName, directoryHint: .isDirectory)
        await Self.removeStalePartials(in: directory)
        let outcome: Outcome
        var clean = true
        if await Self.isCompleteOffMain(folder) {
            outcome = .alreadyDone(folder)
        } else if try await StoreMaintenance.isEmpty(store.modelContainer) {
            outcome = .skippedEmptyStore
        } else {
            let document = try await StoreMaintenance.exportDocument(
                store.modelContainer, appVersion: appVersion, exportedAt: now, attachments: store.attachments
            )
            try await Self.createDirectory(directory)
            let result = try await HowyExporter.write(document, to: folder, files: store.attachments, atomic: true)
            if !result.problems.isEmpty {
                clean = false
                Self.log.error("Backup \(todayName, privacy: .public) had \(result.problems.count) problems; not pruning: \(result.problems.joined(separator: "; "), privacy: .public)")
            }
            outcome = .created(folder)
        }
        if clean {
            await Self.prune(directory, keep: keep, through: todayName, spare: todayName)
        }
        return outcome
    }

    nonisolated static func isComplete(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: HowyFormat.fileName).path(percentEncoded: false))
    }

    @concurrent
    nonisolated private static func isCompleteOffMain(_ folder: URL) async -> Bool {
        isComplete(folder)
    }

    @concurrent
    nonisolated private static func createDirectory(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Removes `Howy Backup yyyy-MM-dd.partial` folders: leftovers of a run that was interrupted.
    @concurrent
    nonisolated private static func removeStalePartials(in directory: URL) async {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        for name in names where isPartialName(name) {
            try? fileManager.removeItem(at: directory.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// Deletes all but the newest `keep` complete backups named `through` or earlier (names
    /// sort by date). Incomplete folders and later-dated ones (a clock that jumped) are not
    /// counted and not touched, nor is `spare` (the folder just written).
    @concurrent
    nonisolated private static func prune(_ directory: URL, keep: Int, through: String, spare: String) async {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        let backups = names
            .filter { isBackupName($0) && $0 <= through }
            .filter { isComplete(directory.appending(path: $0, directoryHint: .isDirectory)) }
            .sorted(by: >)
        for name in backups.dropFirst(keep) where name != spare {
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

    /// A backup name plus `.partial`.
    nonisolated static func isPartialName(_ name: String) -> Bool {
        name.hasSuffix(partialSuffix) && isBackupName(String(name.dropLast(partialSuffix.count)))
    }
}
