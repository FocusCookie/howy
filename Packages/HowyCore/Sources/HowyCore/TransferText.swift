import Foundation

/// The sentences the import/export windows show, kept out of the views so the wording and the
/// plurals are tested.
public enum TransferText {
    /// The export folder name the save panel suggests: `Howy Export yyyy-MM-dd HHmm`, local time.
    public static func exportFolderName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Howy Export \(formatter.string(from: date))"
    }

    /// "Exported 12 todos and 3 attachments".
    public static func exportHeadline(_ result: ExportResult) -> String {
        "Exported \(count(result.todoCount, "todo")) and \(count(result.attachmentCount, "attachment"))"
    }

    /// The question before an import, e.g. "Found 87 todos (12 already exist and will be
    /// skipped, 2 invalid), 23 attachments. Import?"
    public static func importPreview(_ report: ImportReport) -> String {
        var skipped: [String] = []
        if report.duplicateCount > 0 {
            let verb = report.duplicateCount == 1 ? "exists" : "exist"
            skipped.append("\(report.duplicateCount) already \(verb) and will be skipped")
        }
        if report.invalidCount > 0 {
            skipped.append("\(report.invalidCount) invalid")
        }
        var sentence = "Found \(count(report.totalCount, "todo"))"
        if !skipped.isEmpty { sentence += " (\(skipped.joined(separator: ", ")))" }
        if report.attachmentCount > 0 { sentence += ", \(count(report.attachmentCount, "attachment"))" }
        sentence += "."
        sentence += report.importCount > 0 ? " Import?" : " Nothing to import."
        return sentence
    }

    /// The retention warning, or nil when no imported todo is past the archive retention.
    public static func retentionWarning(_ expiredCount: Int) -> String? {
        guard expiredCount > 0 else { return nil }
        return expiredCount == 1
            ? "1 archived todo is older than your retention and will be removed."
            : "\(expiredCount) archived todos are older than your retention and will be removed."
    }

    /// "1 todo", "3 todos".
    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
