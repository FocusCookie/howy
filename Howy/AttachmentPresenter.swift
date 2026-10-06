import AppKit
import HowyCore
import Quartz
import UniformTypeIdentifiers

/// Opens attachments for a panel: in Quick Look above it, in their default app, or picks new files.
/// Quick Look and the file picker need Howy to be the active app and take key status from the
/// panel, so the panel is held open meanwhile and gets key status back afterwards.
@MainActor
final class AttachmentPresenter {
    private weak var panel: FloatingPanel?
    /// Makes Howy the active app (remembering who to hand focus back to when the panel closes).
    private let activate: () -> Void
    private var previewer: AttachmentPreviewer?

    /// Just above the floating panel, so Quick Look and the open panel aren't hidden behind it.
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    init(panel: FloatingPanel, activate: @escaping () -> Void) {
        self.panel = panel
        self.activate = activate
    }

    func open(_ urls: [URL], at index: Int, mode: AttachmentOpenMode) {
        guard urls.indices.contains(index) else { return }
        switch mode {
        case .quickLook: quickLook(urls, at: index)
        case .defaultApp: NSWorkspace.shared.open(urls[index]) // the panel closes as on any focus loss
        }
    }

    private func quickLook(_ urls: [URL], at index: Int) {
        guard let panel, let preview = QLPreviewPanel.shared() else { return }
        // The chosen file comes first and the rest follow in a loop, so Quick Look opens right on it
        // (jumping to an index makes it flick through the files before it) and ←/→ still browse.
        let ordered = Array(urls[index...] + urls[..<index])
        if preview.isVisible, let previewer {
            previewer.urls = ordered
            preview.reloadData()
            preview.currentPreviewItemIndex = 0
            return
        }
        activate()
        let previewer = AttachmentPreviewer(urls: ordered)
        self.previewer = previewer
        panel.holdOpen()
        panel.previewSource = previewer
        panel.onPreviewEnd = { [weak self, weak panel] in
            self?.previewer = nil
            panel?.releaseHold()
        }
        preview.level = Self.level
        preview.makeKeyAndOrderFront(nil)
    }

    /// A file picker; `completion` gets the chosen files (not called on cancel).
    func chooseFiles(completion: @escaping ([URL]) -> Void) {
        guard let panel else { return }
        activate()
        panel.holdOpen()
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.prompt = "Attach"
        picker.message = "Choose files to attach"
        picker.level = Self.level
        picker.begin { [weak panel] response in
            MainActor.assumeIsolated {
                let urls = response == .OK ? picker.urls : []
                panel?.releaseHold()
                if !urls.isEmpty { completion(urls) }
            }
        }
    }
}

/// The Quick Look data source: the todo's attachments, so ←/→ in Quick Look moves between them.
/// Space closes it again, like in Finder.
final class AttachmentPreviewer: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 else { return false } // Space
        panel.orderOut(nil)
        return true
    }
}
