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
///
/// Checklists: ⇧⌘L turns the selected lines into task items or ticks / unticks them
/// (`MarkdownTaskToggle`), and a click on a box ticks or unticks it, with a pointing hand and a
/// soft rounded highlight over the box. Both are one undo step each.
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
    /// Take all the height offered (an Overview tile's editor) instead of growing with the text
    /// up to `maxHeight`.
    var fillsHeight = false

    /// The editor's height range at 100 %; the panel zoom (`\.panelScale`) multiplies both, like
    /// the text's sizes (`MarkdownStyler`).
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
        let scale = context.environment.panelScale
        textView.font = MarkdownStyler.baseFont(scale: scale)
        textView.typingAttributes = MarkdownStyler.baseAttributes(scale: scale)
        textView.textContainerInset = NSSize(width: 0, height: 2 * scale)
        textView.string = text
        textView.registerForDraggedTypes([.fileURL])
        MarkdownStyler.apply(to: textView, scale: scale, highlighting: highlightedName, among: attachmentNames)
        context.coordinator.appliedHighlight = highlightedName
        context.coordinator.appliedScale = scale

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
        let scale = context.environment.panelScale
        let coordinator = context.coordinator
        if textView.string != text, !textView.hasMarkedText() {
            // Changed from outside (e.g. an attachment's reference was removed).
            textView.string = text
            restyle(textView, scale: scale, coordinator: coordinator)
        } else if coordinator.appliedHighlight != highlightedName || coordinator.appliedScale != scale,
                  !textView.hasMarkedText() {
            restyle(textView, scale: scale, coordinator: coordinator)
        }
        context.coordinator.syncFocus(textView)
    }

    /// Styles the whole text at `scale` (a zoom change restyles it at the new sizes).
    private func restyle(_ textView: NSTextView, scale: CGFloat, coordinator: Coordinator) {
        if coordinator.appliedScale != scale {
            textView.font = MarkdownStyler.baseFont(scale: scale)
            textView.textContainerInset = NSSize(width: 0, height: 2 * scale)
        }
        MarkdownStyler.apply(to: textView, scale: scale, highlighting: highlightedName, among: attachmentNames)
        coordinator.appliedHighlight = highlightedName
        coordinator.appliedScale = scale
        (textView as? NoteTextView)?.clearTaskHover() // the text or its sizes changed under it
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        let scale = context.environment.panelScale
        let minHeight = Self.minHeight * scale
        let maxHeight = Self.maxHeight * scale
        guard let textView = nsView.documentView as? NSTextView, let storage = textView.textStorage else {
            return CGSize(width: width, height: minHeight)
        }
        let measured = storage.length == 0 ? 0 : storage.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        // A trailing newline starts a line the bounding rect doesn't count.
        let trailingLine = storage.string.hasSuffix("\n") ? MarkdownStyler.baseFont(scale: scale).boundingRectForFont.height : 0
        let height = ceil(measured + trailingLine) + textView.textContainerInset.height * 2
        // A scroller only when the note is taller than the editor: while the editor first appears it
        // is briefly laid out smaller than its text, which would flash an overlay scroller.
        let offered = proposal.height.flatMap { $0.isFinite ? $0 : nil }
        let limit = fillsHeight ? max(offered ?? maxHeight, minHeight) : maxHeight
        let overflows = height > limit
        if nsView.hasVerticalScroller != overflows { nsView.hasVerticalScroller = overflows }
        if fillsHeight, offered != nil { return CGSize(width: width, height: limit) }
        return CGSize(width: width, height: min(max(height, minHeight), maxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownNoteEditor
        /// The caret goes to the end on the first programmatic focus (restored drafts, edits).
        private var hasBeenFocused = false
        /// The highlighted attachment name the text is currently styled with.
        var appliedHighlight: String?
        /// The panel zoom the text is currently styled at.
        var appliedScale: CGFloat = 1
        private var caretReference: String?
        private var hoverReference: String?
        private var reportedReference: String?
        weak var textViewForFocus: NSTextView?

        init(_ parent: MarkdownNoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Mid-composition the marked text carries the IME's own attributes: restyle once it commits.
            if !textView.hasMarkedText() {
                MarkdownStyler.apply(to: textView, scale: appliedScale, highlighting: parent.highlightedName, among: parent.attachmentNames)
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

    /// ⌘V goes to `paste` here even if no menu offers Paste (a menu-bar-only app); ⇧⌘L toggles
    /// the checklist items under the selection.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if window?.firstResponder === self {
            if flags == .command, key == "v" {
                paste(nil)
                return true
            }
            if flags == [.command, .shift], key == "l" {
                toggleChecklist()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Checklists

    private static let checklistUndoName = "Toggle Checklist Item"

    /// ⇧⌘L: lines become checklist items, or their boxes are ticked / unticked (`MarkdownTaskToggle`).
    private func toggleChecklist() {
        guard !hasMarkedText(), let edit = MarkdownTaskToggle.toggle(in: string, selection: selectedRange()) else { return }
        applyChecklistEdit(edit, selection: edit.selection)
    }

    /// Replaces as one undo step through the normal text-change path (binding, restyle).
    private func applyChecklistEdit(_ edit: MarkdownTaskToggle.Edit, selection: NSRange) {
        guard let storage = textStorage, shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        breakUndoCoalescing() // not merged into the typing before it
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        breakUndoCoalescing() // nor into the typing after it
        undoManager?.setActionName(Self.checklistUndoName)
        setSelectedRange(selection)
    }

    /// The task box (from `MarkdownHighlighter.taskBoxes`) whose glyphs, padded a little, contain
    /// `point` (view coordinates), and its rect.
    private func taskBox(at point: NSPoint) -> (range: NSRange, rect: NSRect)? {
        guard !string.isEmpty else { return nil }
        for box in MarkdownHighlighter.taskBoxes(in: string) {
            guard let rect = rect(forCharacters: box.range) else { continue }
            if rect.insetBy(dx: -Self.boxPadding, dy: -Self.boxPadding).contains(point) { return (box.range, rect) }
        }
        return nil
    }

    /// The bounding rect of a character range in view coordinates (TextKit 2).
    private func rect(forCharacters range: NSRange) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        layout.ensureLayout(for: textRange)
        var union: NSRect?
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        let origin = textContainerOrigin
        return union.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// A click on a box ticks or unticks it, leaving the selection where it was.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !hasMarkedText(), let box = taskBox(at: point) else {
            super.mouseDown(with: event)
            return
        }
        guard event.clickCount == 1 else { return } // a double click doesn't tick twice or select
        let selection = selectedRange()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if let edit = MarkdownTaskToggle.toggleBox(in: string, at: box.range) {
            applyChecklistEdit(edit, selection: selection) // same length: the selection stays valid
        }
        // The text changed (the highlight was cleared): show it again under the pointer.
        updateTaskHover(at: point)
    }

    // MARK: Box hover

    private static let boxPadding: CGFloat = 2
    private static let boxCornerRadius: CGFloat = 4

    /// A soft rounded rect behind the box under the pointer. A plain subview below the text,
    /// so it scrolls with the text and never takes clicks.
    private var boxHighlight: BoxHighlightView?
    private var hoveredBox: NSRange?

    /// Highlights the box under `point` (view coordinates) and shows the pointing hand over it.
    /// Returns whether the pointer is over a box.
    @discardableResult
    private func updateTaskHover(at point: NSPoint?) -> Bool {
        let box = point.flatMap { taskBox(at: $0) }
        if let box {
            let highlight = boxHighlight ?? {
                let view = BoxHighlightView(cornerRadius: Self.boxCornerRadius)
                addSubview(view, positioned: .below, relativeTo: nil)
                boxHighlight = view
                return view
            }()
            if hoveredBox != box.range || highlight.isHidden {
                highlight.frame = box.rect.insetBy(dx: -Self.boxPadding, dy: -Self.boxPadding).integral
                highlight.isHidden = false
            }
            hoveredBox = box.range
            NSCursor.pointingHand.set()
        } else {
            clearTaskHover()
        }
        return box != nil
    }

    /// Removes the box highlight (the text or its layout changed, or the pointer left).
    func clearTaskHover() {
        hoveredBox = nil
        if let boxHighlight, !boxHighlight.isHidden { boxHighlight.isHidden = true }
    }

    override func didChangeText() {
        super.didChangeText()
        clearTaskHover()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clearTaskHover() // a new width rewraps the lines
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
        super.mouseMoved(with: event) // sets the I-beam
        let point = convert(event.locationInWindow, from: nil)
        let index = string.isEmpty ? nil : characterIndexForInsertion(at: point)
        coordinator?.pointerMoved(to: index, in: self)
        updateTaskHover(at: point) // the pointing hand over a box
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.pointerMoved(to: nil, in: self)
        clearTaskHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.syncFocus(self) // the first update can run before there is a window
    }
}

/// The soft rounded background behind a hovered task box. Never takes the mouse: clicks go to
/// the text view, which hit-tests the boxes itself.
private final class BoxHighlightView: NSView {
    private static let color = NSColor.controlAccentColor.withAlphaComponent(0.18)

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolved here, so it follows light / dark mode and the accent colour.
        layer?.backgroundColor = Self.color.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Applies `MarkdownHighlighter` spans to a text view's storage. Every size (the body text,
/// headings, code, line spacing) is multiplied by the panel zoom's `scale`.
@MainActor
enum MarkdownStyler {
    /// The body text at `scale` (13 pt at 100 %).
    static func baseFont(scale: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize * scale)
    }

    static func baseAttributes(scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2 * scale
        return [.font: baseFont(scale: scale), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    /// Heading sizes at 100 %, by level (deeper levels are body-sized and bold).
    private static func headingSize(level: Int) -> CGFloat? {
        switch level {
        case 1: 20
        case 2: 17
        case 3: 15
        default: nil
        }
    }

    private static let codeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)

    private static let referenceHighlight = NSColor.controlAccentColor.withAlphaComponent(0.22)

    /// Restyles the whole text; references to `highlightedName` (among the attachment `names`)
    /// get a soft accent background.
    static func apply(
        to textView: NSTextView, scale: CGFloat, highlighting highlightedName: String? = nil, among names: Set<String> = []
    ) {
        guard let storage = textView.textStorage else { return }
        let spans = MarkdownHighlighter.spans(in: storage.string).sorted { order($0.style) < order($1.style) }
        let full = NSRange(location: 0, length: storage.length)
        let base = baseAttributes(scale: scale)
        storage.beginEditing()
        storage.setAttributes(base, range: full)
        for span in spans { apply(span, to: storage, scale: scale) }
        if let highlightedName, names.contains(highlightedName) {
            for match in AttachmentReference.matches(in: storage.string, names: [highlightedName]) {
                storage.addAttribute(.backgroundColor, value: referenceHighlight, range: match.range)
            }
        }
        storage.endEditing()
        textView.typingAttributes = base
    }

    /// Blocks first, inline styles on top, dimming last; a task box and its check last of all.
    /// A ticked item's grey and strike-through go right after the inline styles: its bold and
    /// italic fonts stay, a link in it turns grey too, and its markup is still dimmed below that.
    private static func order(_ style: MarkdownStyleSpan.Style) -> Int {
        switch style {
        case .heading, .quote, .codeBlock: 0
        case .bold, .italic, .strikethrough, .link, .listMarker: 1
        case .inlineCode, .taskDone: 2
        case .quoteMarker: 3
        case .syntax: 4
        case .taskBox: 5
        case .taskCheck: 6
        }
    }

    private static func apply(_ span: MarkdownStyleSpan, to storage: NSTextStorage, scale: CGFloat) {
        let range = span.range
        let baseSize = NSFont.systemFontSize * scale
        switch span.style {
        case .heading(let level):
            let size = headingSize(level: level).map { $0 * scale } ?? baseSize
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: range)
        case .bold:
            transformFont(in: range, of: storage, scale: scale) { withTraits(.bold, $0) }
        case .italic:
            transformFont(in: range, of: storage, scale: scale) { withTraits(.italic, $0) }
        case .strikethrough:
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: range)
        case .inlineCode, .codeBlock:
            // 0.93 × the surrounding size, which is already zoomed (body or heading).
            transformFont(in: range, of: storage, scale: scale) {
                NSFont.monospacedSystemFont(ofSize: $0.pointSize * 0.93, weight: .regular)
            }
            storage.addAttribute(.backgroundColor, value: codeBackground, range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .quoteMarker:
            storage.addAttributes([
                .foregroundColor: NSColor.controlAccentColor.withAlphaComponent(0.7),
                .font: NSFont.systemFont(ofSize: baseSize, weight: .heavy),
            ], range: range)
        case .listMarker:
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            transformFont(in: range, of: storage, scale: scale) { withTraits(.bold, $0) }
        case .link:
            storage.addAttributes([
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        case .syntax, .taskBox:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        case .taskCheck:
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            transformFont(in: range, of: storage, scale: scale) { withTraits(.bold, $0) }
        case .taskDone:
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
            ], range: range)
        }
    }

    private static func transformFont(
        in range: NSRange, of storage: NSTextStorage, scale: CGFloat, _ transform: (NSFont) -> NSFont
    ) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = (value as? NSFont) ?? baseFont(scale: scale)
            storage.addAttribute(.font, value: transform(font), range: subrange)
        }
    }

    private static func withTraits(_ traits: NSFontDescriptor.SymbolicTraits, _ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
