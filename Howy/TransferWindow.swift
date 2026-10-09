import AppKit
import HowyCore
import SwiftUI

/// What the import/export window shows.
enum TransferState {
    case working(String)
    case confirmImport(ImportReport)
    case exported(ExportResult)
    case imported(ImportReport)
    case failed(title: String, message: String)
}

@MainActor
@Observable
final class TransferModel {
    var state = TransferState.working("")
    @ObservationIgnored var onImport: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}
}

/// The export result, the import preview and the import summary. A normal window (not a
/// `FloatingPanel`), so it stays open while the user looks in Finder or copies the problems.
struct TransferView: View {
    let model: TransferModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .working(let text):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .confirmImport(let report):
            Text("Import").font(.headline)
            Text(TransferText.importPreview(report))
            if let warning = TransferText.retentionWarning(report.expiredCount) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ProblemList(problems: report.problems)
            buttons {
                Button("Cancel", role: .cancel) { model.onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { model.onImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(report.importCount == 0)
            }
        case .exported(let result):
            Text(TransferText.exportHeadline(result)).font(.headline)
            ProblemList(problems: result.problems)
            buttons {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.folder])
                }
                Button("Done") { model.onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        case .imported(let report):
            Text("Import Finished").font(.headline)
            ImportCounts(report: report)
            ProblemList(problems: report.problems)
            buttons {
                Button("Done") { model.onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        case .failed(let title, let message):
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(message)
                .textSelection(.enabled)
            buttons {
                Button("OK") { model.onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func buttons<Buttons: View>(@ViewBuilder _ buttons: () -> Buttons) -> some View {
        HStack {
            Spacer()
            buttons()
        }
        .padding(.top, 4)
    }
}

/// Only the counts that aren't zero, apart from "Imported".
private struct ImportCounts: View {
    let report: ImportReport

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            row("Imported", report.importCount)
            if report.attachmentCount > 0 { row("Attachments", report.attachmentCount) }
            if report.duplicateCount > 0 { row("Skipped as duplicates", report.duplicateCount) }
            if report.invalidCount > 0 { row("Skipped as invalid", report.invalidCount) }
            if report.missingAttachmentCount > 0 { row("Attachments missing", report.missingAttachmentCount) }
            if report.expiredCount > 0 { row("Will be purged by retention", report.expiredCount) }
        }
        if let warning = TransferText.retentionWarning(report.expiredCount) {
            Text(warning)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ count: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(count, format: .number).monospacedDigit()
        }
    }
}

/// One line per problem, selectable, with a Copy button. Nothing when there are none.
private struct ProblemList: View {
    let problems: [String]

    var body: some View {
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(problems.count == 1 ? "1 problem" : "\(problems.count) problems")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(problems.joined(separator: "\n"), forType: .string)
                    }
                    .controlSize(.small)
                }
                ScrollView {
                    Text(problems.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: min(CGFloat(problems.count) * 20 + 16, 200))
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Runs Export… and Import…: the save/open panel, the work, and one reusable result window.
/// Like Settings, the app is a regular app while the window (or a file panel) is up, because an
/// accessory app's windows don't reliably become key.
@MainActor
final class TransferWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = TransferModel()
    private var busy = false
    private var pendingImport: (importer: HowyImporter, plan: ImportPlan)?

    override init() {
        super.init()
        model.onClose = { [weak self] in self?.window?.close() }
        model.onImport = { [weak self] in self?.confirmImport() }
    }

    // MARK: Export

    func export(store: TodoStore) {
        guard !busy else { return focus() }
        let panel = NSSavePanel()
        panel.title = "Export Howy"
        panel.message = "Howy writes a folder with howy.json and your attachments."
        panel.prompt = "Export"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = TransferText.exportFolderName(for: .now)
        panel.canCreateDirectories = true
        run(panel) { [weak self] url in self?.export(store: store, to: url) }
    }

    private func export(store: TodoStore, to folder: URL) {
        busy = true
        show(.working("Exporting…"))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        Task { [weak self] in
            let state: TransferState
            do {
                let result = try await HowyExporter(store: store, appVersion: version).export(to: folder)
                state = .exported(result)
            } catch {
                log.error("Export failed: \(error, privacy: .public)")
                state = .failed(title: "Export failed", message: error.localizedDescription)
            }
            self?.busy = false
            self?.show(state)
        }
    }

    // MARK: Import

    func importFolder(store: TodoStore) {
        guard !busy else { return focus() }
        let panel = NSOpenPanel()
        panel.title = "Import into Howy"
        panel.message = "Choose a Howy export folder (the folder that contains howy.json)."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        run(panel) { [weak self] url in self?.analyze(store: store, folder: url) }
    }

    private func analyze(store: TodoStore, folder: URL) {
        let importer = HowyImporter(store: store, retention: .load())
        do {
            let plan = try importer.analyze(folder: folder)
            pendingImport = (importer, plan)
            show(.confirmImport(plan.report))
        } catch {
            log.error("Import refused: \(error, privacy: .public)")
            show(.failed(
                title: "Import refused",
                message: "\(error.localizedDescription) Nothing was changed."
            ))
        }
    }

    private func confirmImport() {
        guard let pending = pendingImport, !busy else { return }
        let (importer, plan) = pending
        pendingImport = nil
        busy = true
        show(.working("Importing…"))
        Task { [weak self] in
            let state: TransferState
            do {
                state = .imported(try await importer.apply(plan))
            } catch {
                log.error("Import failed: \(error, privacy: .public)")
                state = .failed(
                    title: "Import failed",
                    message: "\(error.localizedDescription) Nothing was imported."
                )
            }
            self?.busy = false
            self?.show(state)
        }
    }

    // MARK: Window

    /// Shows a save or open panel on its own (deferred, so the closing menu-bar menu can't take
    /// key status back) and calls `chosen` with the picked URL. Cancel changes nothing.
    private func run(_ panel: NSSavePanel, chosen: @escaping @MainActor (URL) -> Void) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate()
            panel.begin { response in
                MainActor.assumeIsolated {
                    if response == .OK, let url = panel.url {
                        chosen(url)
                    } else if self?.window == nil {
                        NSApp.returnToAccessoryUnlessWindowsAreOpen()
                    }
                }
            }
        }
    }

    private func show(_ state: TransferState) {
        model.state = state
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: TransferView(model: model)))
            window.title = "Howy"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.delegate = self
            window.center()
            self.window = window
        }
        focus()
    }

    private func focus() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        pendingImport = nil // closing the preview is Cancel
        NSApp.returnToAccessoryUnlessWindowsAreOpen(except: notification.object as? NSWindow)
    }
}

extension NSApplication {
    /// Back to a menu-bar-only app, unless another titled window (Settings, import/export) is
    /// still open and needs the app to stay regular.
    func returnToAccessoryUnlessWindowsAreOpen(except closing: NSWindow? = nil) {
        let open = windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        if !open { setActivationPolicy(.accessory) }
    }
}
