import AppKit
import HowyCore
import SwiftUI

/// The note field: a plain-text `NSTextView` that restyles its Markdown live on every edit
/// (Bear/Typora-like). The syntax characters stay in the text, dimmed; only attributes change,
/// so the caret, undo and IME composition are untouched.
///
/// Keys still go through `FloatingPanel.keyHandler` first (⌘↩ save, Esc, ⇧⇥); whatever the flow
/// doesn't consume (Enter = newline, Tab, typing) reaches the text view.
///
/// Attachments: ⌘V of an image or of files copied in Finder, and files dropped on the text, are
/// attached via `onAttach` and their references inserted on their own line at the caret / drop
/// point (undoable). The reference under the caret or pointer is reported, and the references to
/// `highlightedName` get a soft background.
struct MarkdownNoteEditor: NSViewRepresentable {
    let text: String
    /// The flow is in the note field: the text view should be first responder.
    let isFocused: Bool
    let onChange: (String) -> Void
    /// The user clicked into the text view.
    let onFocus: () -> Void
    /// The current attachments' names (which link targets are attachment references).
    var attachmentNames: Set<String> = []
    /// Highlight the references to this attachment.
    var highlightedName: String?
    /// Attaches pasted / dropped content and returns the references to insert.
    var onAttach: ([QuickEntryModel.AttachmentSource]) -> [String] = { _ in [] }
    /// The attachment referenced under the caret (while focused) or the pointer changed.
    var onReferenceChange: (String?) -> Void = { _ in }

    static let minHeight: CGFloat = 60
    static let maxHeight: CGFloat = 260

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.font = MarkdownStyler.baseFont
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.string = text
        textView.registerForDraggedTypes([.fileURL])
        MarkdownStyler.apply(to: textView, highlighting: highlightedName, among: attachmentNames)
        context.coordinator.appliedHighlight = highlightedName

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        if textView.string != text, !textView.hasMarkedText() {
            // Changed from outside (e.g. an attachment's reference was removed).
            textView.string = text
            MarkdownStyler.apply(to: textView, highlighting: highlightedName, among: attachmentNames)
            context.coordinator.appliedHighlight = highlightedName
        } else if context.coordinator.appliedHighlight != highlightedName, !textView.hasMarkedText() {
            MarkdownStyler.apply(to: textView, highlighting: highlightedName, among: attachmentNames)
            context.coordinator.appliedHighlight = highlightedName
        }
        context.coordinator.syncFocus(textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let textView = nsView.documentView as? NSTextView, let storage = textView.textStorage else {
            return CGSize(width: width, height: Self.minHeight)
        }
        let measured = storage.length == 0 ? 0 : storage.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        // A trailing newline starts a line the bounding rect doesn't count.
        let trailingLine = storage.string.hasSuffix("\n") ? MarkdownStyler.baseFont.boundingRectForFont.height : 0
        let height = ceil(measured + trailingLine) + textView.textContainerInset.height * 2
        // A scroller only when the note is taller than the editor: while the editor first appears it
        // is briefly laid out smaller than its text, which would flash an overlay scroller.
        let overflows = height > Self.maxHeight
        if nsView.hasVerticalScroller != overflows { nsView.hasVerticalScroller = overflows }
        return CGSize(width: width, height: min(max(height, Self.minHeight), Self.maxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownNoteEditor
        /// The caret goes to the end on the first programmatic focus (restored drafts, edits).
        private var hasBeenFocused = false
        /// The highlighted attachment name the text is currently styled with.
        var appliedHighlight: String?
        private var caretReference: String?
        private var hoverReference: String?
        private var reportedReference: String?
        weak var textViewForFocus: NSTextView?

        init(_ parent: MarkdownNoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Mid-composition the marked text carries the IME's own attributes: restyle once it commits.
            if !textView.hasMarkedText() {
                MarkdownStyler.apply(to: textView, highlighting: parent.highlightedName, among: parent.attachmentNames)
                appliedHighlight = parent.highlightedName
            }
            parent.onChange(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selection = textView.selectedRange()
            let isFocused = textView.window?.firstResponder === textView
            caretReference = isFocused && selection.length == 0
                ? AttachmentReference.name(at: selection.location, in: textView.string, names: parent.attachmentNames)
                : nil
            reportReference()
        }

        /// The pointer is over this character (nil: outside the text).
        func pointerMoved(to index: Int?, in textView: NSTextView) {
            hoverReference = index.flatMap {
                AttachmentReference.name(at: $0, in: textView.string, names: parent.attachmentNames)
            }
            reportReference()
        }

        func focusChanged(_ textView: NSTextView) {
            textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: textView))
        }

        private func reportReference() {
            let current = hoverReference ?? caretReference
            guard current != reportedReference else { return }
            reportedReference = current
            DispatchQueue.main.async { [weak self] in self?.parent.onReferenceChange(current) } // not during a view update
        }

        /// Attaches pasted / dropped content and inserts the references at the selection, each on its own line.
        func attach(_ sources: [QuickEntryModel.AttachmentSource], in textView: NSTextView) {
            let references = parent.onAttach(sources)
            guard !references.isEmpty else { return }
            let selection = textView.selectedRange()
            let text = textView.string as NSString
            var insertion = references.joined(separator: "\n")
            if selection.location > 0, text.character(at: selection.location - 1) != 0x0A { insertion = "\n" + insertion }
            let end = NSMaxRange(selection)
            if end >= text.length || text.character(at: end) != 0x0A { insertion += "\n" }
            textView.insertText(insertion, replacementRange: selection)
        }

        /// Enter inside a list item continues the list; Enter on an empty item ends it.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }
            let text = textView.string as NSString
            let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let beforeCaret = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            switch MarkdownListContinuation.action(forLineBeforeCaret: beforeCaret) {
            case .insert(let continuation):
                textView.insertText(continuation, replacementRange: selection)
            case .removeMarker(let length):
                textView.insertText("", replacementRange: NSRange(location: selection.location - length, length: length))
            case nil:
                return false
            }
            return true
        }

        func didBecomeFirstResponder() {
            hasBeenFocused = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textViewForFocus else { return }
                self.focusChanged(textView)
            }
            guard !parent.isFocused else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.onFocus() } // not during a view update
        }

        /// Makes the text view first responder when the flow is in the note, and gives it up otherwise.
        func syncFocus(_ textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, let window = textView.window else { return }
                let isFirstResponder = window.firstResponder === textView
                if self.parent.isFocused, !isFirstResponder {
                    let first = !self.hasBeenFocused
                    window.makeFirstResponder(textView)
                    if first {
                        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                        textView.scrollRangeToVisible(textView.selectedRange())
                    }
                } else if !self.parent.isFocused, isFirstResponder {
                    window.makeFirstResponder(nil)
                    self.caretReference = nil
                    self.reportReference()
                }
            }
        }
    }
}

/// Reports focus and window changes to the coordinator.
final class NoteTextView: NSTextView {
    weak var coordinator: MarkdownNoteEditor.Coordinator? {
        didSet { coordinator?.textViewForFocus = self }
    }
    private var hoverArea: NSTrackingArea?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.didBecomeFirstResponder() }
        return became
    }

    // MARK: Attachments

    /// ⌘V goes to `paste` here even if no menu offers Paste (a menu-bar-only app).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v", window?.firstResponder === self {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘V: files copied in Finder, or an image (a screenshot) without text, become attachments.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = Self.fileURLs(on: pasteboard), !urls.isEmpty {
            coordinator?.attach(urls.map { .file($0) }, in: self)
        } else if !(pasteboard.types ?? []).contains(.string), let png = Self.pngData(on: pasteboard) {
            coordinator?.attach([.image(png)], in: self)
        } else {
            super.paste(sender)
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = Self.fileURLs(on: sender.draggingPasteboard), !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: index, length: 0))
        coordinator?.attach(urls.map { .file($0) }, in: self)
        return true
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    private static func pngData(on pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) else { return nil }
        return image.representation(using: .png, properties: [:])
    }

    // MARK: Pointer over references

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let index = string.isEmpty ? nil : characterIndexForInsertion(at: point)
        coordinator?.pointerMoved(to: index, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.pointerMoved(to: nil, in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.syncFocus(self) // the first update can run before there is a window
    }
}

/// Applies `MarkdownHighlighter` spans to a text view's storage.
@MainActor
enum MarkdownStyler {
    static let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private static let codeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)

    private static let referenceHighlight = NSColor.controlAccentColor.withAlphaComponent(0.22)

    /// Restyles the whole text; references to `highlightedName` (among the attachment `names`)
    /// get a soft accent background.
    static func apply(to textView: NSTextView, highlighting highlightedName: String? = nil, among names: Set<String> = []) {
        guard let storage = textView.textStorage else { return }
        let spans = MarkdownHighlighter.spans(in: storage.string).sorted { order($0.style) < order($1.style) }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        for span in spans { apply(span, to: storage) }
        if let highlightedName, names.contains(highlightedName) {
            for match in AttachmentReference.matches(in: storage.string, names: [highlightedName]) {
                storage.addAttribute(.backgroundColor, value: referenceHighlight, range: match.range)
            }
        }
        storage.endEditing()
        textView.typingAttributes = baseAttributes
    }

    /// Blocks first, inline styles on top, dimming last.
    private static func order(_ style: MarkdownStyleSpan.Style) -> Int {
        switch style {
        case .heading, .quote, .codeBlock: 0
        case .bold, .italic, .strikethrough, .link, .listMarker: 1
        case .inlineCode: 2
        case .quoteMarker: 3
        case .syntax: 4
        }
    }

    private static func apply(_ span: MarkdownStyleSpan, to storage: NSTextStorage) {
        let range = span.range
        switch span.style {
        case .heading(let level):
            let size: CGFloat = switch level {
            case 1: 20
            case 2: 17
            case 3: 15
            default: baseFont.pointSize
            }
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: range)
        case .bold:
            transformFont(in: range, of: storage) { withTraits(.bold, $0) }
        case .italic:
            transformFont(in: range, of: storage) { withTraits(.italic, $0) }
        case .strikethrough:
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: range)
        case .inlineCode, .codeBlock:
            transformFont(in: range, of: storage) {
                NSFont.monospacedSystemFont(ofSize: $0.pointSize * 0.93, weight: .regular)
            }
            storage.addAttribute(.backgroundColor, value: codeBackground, range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .quoteMarker:
            storage.addAttributes([
                .foregroundColor: NSColor.controlAccentColor.withAlphaComponent(0.7),
                .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .heavy),
            ], range: range)
        case .listMarker:
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            transformFont(in: range, of: storage) { withTraits(.bold, $0) }
        case .link:
            storage.addAttributes([
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        case .syntax:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }

    private static func transformFont(in range: NSRange, of storage: NSTextStorage, _ transform: (NSFont) -> NSFont) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? baseFont
            storage.addAttribute(.font, value: transform(font), range: subrange)
        }
    }

    private static func withTraits(_ traits: NSFontDescriptor.SymbolicTraits, _ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
