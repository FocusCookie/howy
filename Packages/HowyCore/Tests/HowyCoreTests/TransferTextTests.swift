import Foundation
import Testing
@testable import HowyCore

@Suite struct TransferTextTests {
    @Test func exportFolderNameUsesLocalTime() throws {
        let date = try #require(HowyFormat.date(from: "2026-10-09T13:05:00Z"))
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        #expect(TransferText.exportFolderName(for: date, timeZone: berlin) == "Howy Export 2026-10-09 1505")
    }

    @Test func exportHeadlinePluralises() {
        let folder = URL(filePath: "/tmp/x")
        #expect(TransferText.exportHeadline(ExportResult(folder: folder, todoCount: 12, attachmentCount: 3, problems: []))
            == "Exported 12 todos and 3 attachments")
        #expect(TransferText.exportHeadline(ExportResult(folder: folder, todoCount: 1, attachmentCount: 1, problems: []))
            == "Exported 1 todo and 1 attachment")
    }

    @Test func importPreviewNamesSkippedTodos() {
        var report = ImportReport()
        report.importCount = 73
        report.duplicateCount = 12
        report.invalidCount = 2
        report.attachmentCount = 23
        #expect(TransferText.importPreview(report)
            == "Found 87 todos (12 already exist and will be skipped, 2 invalid), 23 attachments. Import?")
    }

    @Test func cleanImportPreviewIsShort() {
        var report = ImportReport()
        report.importCount = 1
        #expect(TransferText.importPreview(report) == "Found 1 todo. Import?")
    }

    @Test func previewSaysWhenThereIsNothingToImport() {
        var report = ImportReport()
        report.duplicateCount = 1
        #expect(TransferText.importPreview(report) == "Found 1 todo (1 already exists and will be skipped). Nothing to import.")
    }

    @Test func retentionWarningOnlyWhenSomethingExpires() {
        #expect(TransferText.retentionWarning(0) == nil)
        #expect(TransferText.retentionWarning(1) == "1 archived todo is older than your retention and will be removed.")
        #expect(TransferText.retentionWarning(4) == "4 archived todos are older than your retention and will be removed.")
    }
}
