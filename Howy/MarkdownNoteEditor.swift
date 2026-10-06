import AppKit
import HowyCore
import SwiftUI

/// The note field: a plain-text `NSTextView` that restyles its Markdown live on every edit
/// (Bear/Typora-like). The syntax characters stay in the text, dimmed; only attributes change,
/// so the caret, undo and IME composition are untouched.
///
/// Keys still go through `FloatingPanel.keyHandler` first (⌘↩ save, Esc, ⇧⇥); whatever the flow
/// doesn't consume (Enter = newline, Tab, typing) reaches the text view.
struct MarkdownNoteEditor: NSViewRepresentable {
    let text: String
    /// The flow is in the note field: the text view should be first responder.
    let isFocused: Bool
    let onChange: (String) -> Void
    /// The user clicked into the text view.
    let onFocus: () -> Void

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
        MarkdownStyler.apply(to: textView)

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
            // Changed from outside (e.g. ⌘⌫ cleared the draft).
            textView.string = text
            MarkdownStyler.apply(to: textView)
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
        return CGSize(width: width, height: min(max(height, Self.minHeight), Self.maxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownNoteEditor
        /// The caret goes to the end on the first programmatic focus (restored drafts, edits).
        private var hasBeenFocused = false

        init(_ parent: MarkdownNoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Mid-composition the marked text carries the IME's own attributes: restyle once it commits.
            if !textView.hasMarkedText() { MarkdownStyler.apply(to: textView) }
            parent.onChange(textView.string)
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
                }
            }
        }
    }
}

/// Reports focus and window changes to the coordinator.
final class NoteTextView: NSTextView {
    weak var coordinator: MarkdownNoteEditor.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.didBecomeFirstResponder() }
        return became
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

    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let spans = MarkdownHighlighter.spans(in: storage.string).sorted { order($0.style) < order($1.style) }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        for span in spans { apply(span, to: storage) }
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
