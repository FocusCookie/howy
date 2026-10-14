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
/// Attachments: references to the todo's attachments (`attachmentNames`) show as chips like links
/// (`NoteChips`), with a paperclip (a file) or a photo (an image). ⌘V of one file copied in Finder
/// or of a screenshot, and one file dropped on the text, ask for the chip's title first
/// (`onPasteAttachment`); pasted over a one-line selection, the selection becomes the title and no
/// dialog opens. Several files are attached at once (`onAttach`) and their chips inserted inline,
/// separated by spaces. A thumbnail dragged from the strip (`AttachmentDrag`) asks for a title
/// for a chip at the drop point (`onDropAttachment`). ⌘O / ⌥⌘O (or ⌘-click) open the attachment
/// at the caret (`onOpenAttachment`), ⌘E edits the chip's title (`onEditAttachment`). The
/// attachment under the caret or pointer is reported, and the chips of `highlightedName` get a
/// strong accent highlight. While the flow is in the attachments, `ghostSelection` shows where
/// **I** inserts: a wide, steady accent caret (or a tinted range).
///
/// Lists: Tab nests the list items the selection touches one level deeper, ⇧⇥ takes one level
/// away (`MarkdownListIndent`); ⇧⇥ on a top-level item or outside a list still goes to the title.
/// A line of three or more `-`, `*` or `_` is drawn as a horizontal rule.
///
/// Checklists: ⇧⌘L turns the selected lines into task items or ticks / unticks them
/// (`MarkdownTaskToggle`), and a click on a box ticks or unticks it, with a pointing hand and a
/// soft rounded highlight over the box. Both are one undo step each.
///
/// Links (`NoteLinks`): a Markdown link shows as a chip with a link icon and its title; `[` and `](url)`
/// stay in the text but take no space. The caret steps over a chip, the first ⌫ / ⌦ next to one
/// selects it, and an edit cutting into one takes all of it (the same for attachment chips).
/// Pasting a URL over selected text links that text; otherwise `onPasteURL` asks for a title. ⌘O
/// (or ⌘-click) opens the link at the caret, ⌘E edits it (`onEditLink`); a click on a chip puts the
/// caret after it. The chip at the caret is reported with its frame (`onChipChange`) for its
/// popover. A dialog's result arrives as `pendingEdit` and is applied as one undo step.
struct MarkdownNoteEditor: NSViewRepresentable {
    let text: String
    /// The flow is in the note field: the text view should be first responder.
    let isFocused: Bool
    let onChange: (String) -> Void
    /// The user clicked into the text view.
    let onFocus: () -> Void
    /// The current attachments' names (which link targets are attachment references).
    var attachmentNames: Set<String> = []
    /// Highlight the chips of this attachment.
    var highlightedName: String?
    /// Where **I** in the attachments inserts (`QuickEntryFlow.ghostNoteSelection`), drawn while
    /// the text view isn't first responder.
    var ghostSelection: NSRange?
    /// The selection changed (every change, for `QuickEntryFlow.noteSelectionChanged`).
    var onSelectionChange: (NSRange) -> Void = { _ in }
    /// Attaches pasted / dropped content at once and returns the attachments, in order.
    var onAttach: ([QuickEntryModel.AttachmentSource]) -> [TodoAttachment] = { _ in [] }
    /// One file pasted or dropped: ask for its chip's title, the chip going over this range.
    var onPasteAttachment: (QuickEntryModel.AttachmentSource, NSRange) -> Void = { _, _ in }
    /// A thumbnail from the strip dropped on the text (the attachment's id, the drop point).
    /// False when there is no such attachment: the drop is then handled as a file.
    var onDropAttachment: (UUID, NSRange) -> Bool = { _, _ in false }
    /// ⌘O, ⌥⌘O (`alternate`) or ⌘-click on an attachment chip (the attachment's name).
    var onOpenAttachment: (String, Bool) -> Void = { _, _ in }
    /// ⌘E on an attachment chip.
    var onEditAttachment: (AttachmentChip) -> Void = { _ in }
    /// The attachment referenced under the caret (while focused) or the pointer changed.
    var onReferenceChange: (String?) -> Void = { _ in }
    /// A dialog's change to the note, applied once (then `onEditApplied` with its id).
    var pendingEdit: QuickEntryFlow.PendingNoteEdit?
    var onEditApplied: (Int) -> Void = { _ in }
    /// A URL was pasted with no text selected to link: ask for a title for the link over this range.
    var onPasteURL: (String, NSRange) -> Void = { _, _ in }
    /// ⌘E on a link.
    var onEditLink: (NoteLink) -> Void = { _ in }
    /// ⌘O or ⌘-click on a link.
    var onOpenLink: (NoteLink) -> Void = { _ in }
    /// The chip (or bare URL) at the caret (while focused) changed, or its chip moved.
    var onChipChange: (NoteChipAnchor?) -> Void = { _ in }
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
        textView.textLayoutManager?.delegate = textView.blockLayout
        let scale = context.environment.panelScale
        textView.font = MarkdownStyler.baseFont(scale: scale)
        textView.typingAttributes = MarkdownStyler.baseAttributes(scale: scale)
        textView.textContainerInset = NSSize(width: 0, height: 2 * scale)
        textView.string = text
        textView.registerForDraggedTypes([.fileURL, AttachmentDrag.pasteboardType])
        MarkdownStyler.apply(to: textView, scale: scale, highlighting: highlightedName, among: attachmentNames)
        context.coordinator.appliedHighlight = highlightedName
        context.coordinator.appliedNames = attachmentNames
        context.coordinator.appliedScale = scale
        textView.ghostSelection = ghostSelection

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Scrolling moves a chip under its popover.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        let scale = context.environment.panelScale
        let coordinator = context.coordinator
        if textView.string != text, !textView.hasMarkedText() {
            // Changed from outside (e.g. an attachment's reference was removed).
            // The caret stays where it was (clamped), not at the end.
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            restyle(textView, scale: scale, coordinator: coordinator)
        } else if coordinator.appliedHighlight != highlightedName || coordinator.appliedScale != scale
                    || coordinator.appliedNames != attachmentNames, !textView.hasMarkedText() {
            // A new attachment's reference becomes a chip, a removed one's a link.
            restyle(textView, scale: scale, coordinator: coordinator)
        }
        textView.ghostSelection = ghostSelection
        context.coordinator.syncFocus(textView)
        context.coordinator.applyPendingEdit(to: textView)
    }

    /// Styles the whole text at `scale` (a zoom change restyles it at the new sizes).
    private func restyle(_ textView: NSTextView, scale: CGFloat, coordinator: Coordinator) {
        if coordinator.appliedScale != scale {
            textView.font = MarkdownStyler.baseFont(scale: scale)
            textView.textContainerInset = NSSize(width: 0, height: 2 * scale)
        }
        MarkdownStyler.apply(to: textView, scale: scale, highlighting: highlightedName, among: attachmentNames)
        coordinator.appliedHighlight = highlightedName
        coordinator.appliedNames = attachmentNames
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
        /// The attachment names the text's chips are currently styled with.
        var appliedNames: Set<String> = []
        /// The panel zoom the text is currently styled at.
        var appliedScale: CGFloat = 1
        private var caretReference: String?
        private var hoverReference: String?
        private var reportedReference: String?
        weak var textViewForFocus: NSTextView?
        /// The last `pendingEdit` applied (each is applied once).
        private var appliedEditID: Int?
        private var reportedChip: NoteChipAnchor?
        private var reportedSelection: NSRange?
        private weak var scrollView: NSScrollView?
        private var scrollObservers: [any NSObjectProtocol] = []

        init(_ parent: MarkdownNoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Mid-composition the marked text carries the IME's own attributes: restyle once it commits.
            if !textView.hasMarkedText() {
                MarkdownStyler.apply(to: textView, scale: appliedScale, highlighting: parent.highlightedName, among: parent.attachmentNames)
                appliedHighlight = parent.highlightedName
                appliedNames = parent.attachmentNames
            }
            parent.onChange(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selection = textView.selectedRange()
            let isFocused = textView.window?.firstResponder === textView
            caretReference = isFocused ? chip(in: textView)?.attachment?.name : nil
            reportReference()
            reportChip(textView)
            reportSelection(selection)
        }

        /// Every selection change goes to the flow (where **I** inserts), once per change.
        private func reportSelection(_ selection: NSRange) {
            guard selection.location != NSNotFound, selection != reportedSelection else { return }
            reportedSelection = selection
            DispatchQueue.main.async { [weak self] in self?.parent.onSelectionChange(selection) } // not during a view update
        }

        /// The caret steps over a chip; a selection grows and shrinks by whole chips.
        func textView(
            _ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange
        ) -> NSRange {
            guard !textView.hasMarkedText(), new.location != NSNotFound else { return new }
            return NoteChips.snap(new, from: old, in: textView.string, attachmentNames: parent.attachmentNames)
        }

        /// An edit cutting into a chip (⌥⌫, cut) takes the whole chip instead.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacementString, !textView.hasMarkedText() else { return true }
            let widened = NoteChips.widen(range, in: textView.string, attachmentNames: parent.attachmentNames)
            guard widened != range else { return true }
            textView.insertText(replacementString, replacementRange: widened)
            return false
        }

        // MARK: Chips

        /// ⌘V of a single URL: links the selected text, or asks for a title.
        func pasteURL(_ url: String, in textView: NoteTextView) {
            let selection = textView.selectedRange()
            if let edit = NoteLinks.linkSelection(url: url, in: textView.string, selection: selection) {
                textView.applyEdit(range: edit.range, replacement: edit.replacement, selection: edit.selection, actionName: "Add Link")
            } else {
                parent.onPasteURL(url, selection)
            }
        }

        /// The chip at the caret, or the one the selection lies in; else a bare URL there.
        func chip(in textView: NSTextView) -> NoteChip? {
            let selection = textView.selectedRange()
            let text = textView.string
            if let chip = NoteChips.chip(at: selection, in: NoteChips.chips(in: text, attachmentNames: parent.attachmentNames)) {
                return chip
            }
            return NoteLinks.link(at: selection, in: NoteLinks.links(in: text).filter(\.isBare)).map(NoteChip.link)
        }

        func applyPendingEdit(to textView: NoteTextView) {
            guard let pending = parent.pendingEdit, pending.id != appliedEditID else { return }
            appliedEditID = pending.id
            DispatchQueue.main.async { [weak self, weak textView] in // not during a view update
                guard let self, let textView else { return }
                let edit = pending.edit
                if NSMaxRange(edit.range) <= (textView.string as NSString).length {
                    textView.applyEdit(range: edit.range, replacement: edit.replacement, selection: edit.selection, actionName: pending.actionName)
                    textView.scrollRangeToVisible(edit.selection)
                }
                self.parent.onEditApplied(pending.id)
            }
        }

        /// Scrolling, the editor moving in the panel and the panel resizing all move the chip at
        /// the caret, and its popover with it.
        func observeScrolling(of scrollView: NSScrollView) {
            self.scrollView = scrollView
            let center = NotificationCenter.default
            let report: @Sendable (Notification) -> Void = { [weak self] note in
                // Only Sendable bits of the notification go onto the main actor.
                let resized = note.name == NSWindow.didResizeNotification ? note.object.map { ObjectIdentifier($0 as AnyObject) } : nil
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textViewForFocus else { return }
                    if let resized, resized != textView.window.map(ObjectIdentifier.init) { return }
                    self.reportChip(textView)
                }
            }
            scrollObservers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main, using: report),
                center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main, using: report),
                center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main, using: report),
            ]
        }

        /// Reports the chip at the caret (or the chip selected whole) while focused, with its
        /// frame in the editor (nil for a bare URL or a chip scrolled out of view).
        func reportChip(_ textView: NSTextView) {
            var anchor: NoteChipAnchor?
            let selection = textView.selectedRange()
            if parent.isFocused, textView.window?.firstResponder === textView, !textView.hasMarkedText(),
               let chip = chip(in: textView), selection.length == 0 || selection == chip.range {
                anchor = NoteChipAnchor(chip: chip, frame: chip.isChip ? screenFrame(of: chip.range, in: textView) : nil)
            }
            guard anchor != reportedChip else { return }
            reportedChip = anchor
            DispatchQueue.main.async { [weak self] in self?.parent.onChipChange(anchor) } // not during a view update
        }

        /// A character range's frame on screen, if it is in view.
        private func screenFrame(of range: NSRange, in textView: NSTextView) -> CGRect? {
            guard let scrollView, let window = textView.window, let rect = (textView as? NoteTextView)?.rect(forCharacters: range),
                  scrollView.contentView.documentVisibleRect.intersects(rect) else { return nil }
            return window.convertToScreen(textView.convert(rect, to: nil))
        }

        /// The pointer is over the chip of this attachment (nil: over none).
        func pointerMoved(toAttachmentNamed name: String?) {
            hoverReference = name
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

        /// Pasted / dropped content at the selection. One file asks for its chip's title (no
        /// dialog when pasted over a one-line selection: that text is the title); several are
        /// attached at once, their chips inline with their default titles. One undo step either way.
        func attach(_ sources: [QuickEntryModel.AttachmentSource], in textView: NoteTextView) {
            guard !sources.isEmpty else { return }
            let text = textView.string
            let names = parent.attachmentNames
            let selection = textView.selectedRange()
            if sources.count == 1, let source = sources.first {
                // A stand-in with the file's name: the selection decides, not the file.
                let probe = TodoAttachment(name: source.fileName)
                if NoteAttachments.insert(probe, titledBySelection: selection, in: text, attachmentNames: names) != nil {
                    guard let attachment = parent.onAttach([source]).first,
                          let edit = NoteAttachments.insert(attachment, titledBySelection: selection, in: text, attachmentNames: names)
                    else { return }
                    textView.applyEdit(range: edit.range, replacement: edit.replacement, selection: edit.selection, actionName: "Add Attachment")
                    return
                }
                parent.onPasteAttachment(source, NoteChips.widen(selection, in: text, attachmentNames: names))
                return
            }
            let attachments = parent.onAttach(sources)
            guard !attachments.isEmpty else { return }
            let edit = NoteAttachments.insert(attachments, replacing: NoteChips.widen(selection, in: text, attachmentNames: names), in: text)
            textView.applyEdit(range: edit.range, replacement: edit.replacement, selection: edit.selection, actionName: "Add Attachments")
        }

        /// A thumbnail from the strip dropped at `index`: a chip for it there (after a chip the
        /// point falls in), through the title dialog.
        func dropAttachment(id: UUID, at index: Int, in textView: NSTextView) -> Bool {
            let caret = NoteChips.widen(NSRange(location: index, length: 0), in: textView.string, attachmentNames: parent.attachmentNames)
            let point = NSRange(location: NSMaxRange(caret), length: 0)
            let previous = textView.selectedRange()
            textView.setSelectedRange(point)
            if parent.onDropAttachment(id, point) { return true }
            textView.setSelectedRange(previous)
            return false
        }

        /// Enter inside a list item continues the list; Enter on an empty item ends it. Tab nests
        /// the list items under the selection (a plain tab elsewhere).
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                return (textView as? NoteTextView)?.indentListItems() ?? false
            }
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
                self.reportChip(textView)
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
    /// The layout manager's delegate (held weakly there): code boxes and quote bars.
    let blockLayout = BlockLayoutDelegate()

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            coordinator?.didBecomeFirstResponder()
            setNeedsChipUpdate() // the real caret takes over from the ghost
        }
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
            let isChipKey = flags == .command && (key == "o" || key == "e") || flags == [.command, .option] && key == "o"
            if isChipKey, !hasMarkedText(), let chip = coordinator?.chip(in: self), let parent = coordinator?.parent {
                switch chip {
                case .link(let link):
                    guard flags == .command else { break } // ⌥⌘O is the attachments'
                    if key == "o" { parent.onOpenLink(link) } else { parent.onEditLink(link) }
                    return true
                case .attachment(let attachment):
                    if key == "o" {
                        parent.onOpenAttachment(attachment.name, flags.contains(.option))
                    } else {
                        parent.onEditAttachment(attachment)
                    }
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setNeedsChipUpdate() } // the ghost caret shows while the focus is elsewhere
        return resigned
    }

    // MARK: Checklists

    private static let checklistUndoName = "Toggle Checklist Item"

    /// ⇧⌘L: lines become checklist items, or their boxes are ticked / unticked (`MarkdownTaskToggle`).
    private func toggleChecklist() {
        guard !hasMarkedText(), let edit = MarkdownTaskToggle.toggle(in: string, selection: selectedRange()) else { return }
        applyEdit(range: edit.range, replacement: edit.replacement, selection: edit.selection, actionName: Self.checklistUndoName)
    }

    // MARK: List nesting

    /// Tab: nests the list items under the selection one level deeper (`MarkdownListIndent`).
    /// False when there's none, so Tab types a tab.
    func indentListItems() -> Bool {
        guard !hasMarkedText(), let edit = MarkdownListIndent.indent(in: string, selection: selectedRange()) else { return false }
        applyEdit(range: edit.range, replacement: edit.replacement, selection: edit.selection, actionName: "Indent")
        return true
    }

    /// ⇧⇥: takes one level from the nested list items under the selection. False when there's
    /// none, so ⇧⇥ goes back to the title.
    func outdentListItems() -> Bool {
        guard !hasMarkedText(), let edit = MarkdownListIndent.outdent(in: string, selection: selectedRange()) else { return false }
        applyEdit(range: edit.range, replacement: edit.replacement, selection: edit.selection, actionName: "Outdent")
        return true
    }

    // MARK: Caret

    /// The caret, wider than the system's 1 pt so it is easy to find, also in dark mode.
    private var caretWidth: CGFloat { max(2, 2 * bodyScale) }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var rect = rect
        rect.size.width = caretWidth
        if flag {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: caretWidth / 2, yRadius: caretWidth / 2).fill()
        } else {
            setNeedsDisplay(rect, avoidAdditionalLayout: true)
        }
    }

    /// The text view invalidates a 1 pt caret; the wide one needs its whole rect redrawn.
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = rect
        rect.size.width += caretWidth
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    /// Replaces as one undo step through the normal text-change path (binding, restyle).
    func applyEdit(range: NSRange, replacement: String, selection: NSRange, actionName: String) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: replacement) else { return }
        breakUndoCoalescing() // not merged into the typing before it
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        breakUndoCoalescing() // nor into the typing after it
        undoManager?.setActionName(actionName)
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
    func rect(forCharacters range: NSRange) -> NSRect? {
        segmentRects(forCharacters: range).reduce(nil) { union, rect in union.map { $0.union(rect) } ?? rect }
    }

    /// The rects a character range covers, one per line, in view coordinates (TextKit 2).
    private func segmentRects(forCharacters range: NSRange) -> [NSRect] {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end),
              let laidOut = NSTextRange(location: content.documentRange.location, end: end) else { return [] }
        // From the start: lines above the viewport otherwise keep estimated heights, and the range
        // would be measured off by the difference until they are laid out (scrolling up).
        layout.ensureLayout(for: laidOut)
        var rects: [NSRect] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame)
            return true
        }
        let origin = textContainerOrigin
        return rects.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// A click on a box ticks or unticks it, leaving the selection where it was. A click on a
    /// chip puts the caret after it (its popover opens), a ⌘-click opens its link or attachment
    /// (⌥⌘-click: the attachment the other way).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !hasMarkedText(), let chip = chip(at: point) {
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
            let flags = event.modifierFlags
            if flags.contains(.command), let parent = coordinator?.parent {
                switch NoteChips.chips(in: string, attachmentNames: parent.attachmentNames).first(where: { $0.range == chip.range }) {
                case .link(let link): parent.onOpenLink(link)
                case .attachment(let attachment): parent.onOpenAttachment(attachment.name, flags.contains(.option))
                case nil: break
                }
            } else {
                setSelectedRange(NSRange(location: NSMaxRange(chip.range), length: 0))
            }
            return
        }
        guard !hasMarkedText(), let box = taskBox(at: point) else {
            super.mouseDown(with: event)
            return
        }
        guard event.clickCount == 1 else { return } // a double click doesn't tick twice or select
        let selection = selectedRange()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if let edit = MarkdownTaskToggle.toggleBox(in: string, at: box.range) {
            // Same length: the selection stays valid.
            applyEdit(range: edit.range, replacement: edit.replacement, selection: selection, actionName: Self.checklistUndoName)
        }
        // The text changed (the highlight was cleared): show it again under the pointer.
        updateTaskHover(at: point)
    }

    // MARK: Box hover

    private static let boxPadding: CGFloat = 2
    private static let boxCornerRadius: CGFloat = 4

    /// A soft rounded rect behind the box under the pointer. A plain subview below the text,
    /// so it scrolls with the text and never takes clicks.
    private var boxHighlight: RoundedHighlightView?
    private static let boxColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
    private var hoveredBox: NSRange?

    /// Highlights the box under `point` (view coordinates) and shows the pointing hand over it.
    /// Returns whether the pointer is over a box.
    @discardableResult
    private func updateTaskHover(at point: NSPoint?) -> Bool {
        let box = point.flatMap { taskBox(at: $0) }
        if let box {
            let highlight = boxHighlight ?? {
                let view = RoundedHighlightView(color: Self.boxColor, cornerRadius: Self.boxCornerRadius)
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
        caretNeedsReveal = true
        setNeedsChipUpdate()
    }

    /// An edit happened and the caret's line may be out of view.
    private var caretNeedsReveal = false

    /// TextKit 2 lays the text out (and makes the view taller) after the edit, too late for the
    /// text view's own scrolling: a new line could end up below the editor. Once the layout is
    /// done, the caret's line is scrolled into view.
    private func revealCaretIfNeeded() {
        guard caretNeedsReveal else { return }
        caretNeedsReveal = false
        guard window?.firstResponder === self, !hasMarkedText(), let caret = revealRect(at: selectedRange().location) else { return }
        scrollToVisible(caret.insetBy(dx: 0, dy: -textContainerInset.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clearTaskHover() // a new width rewraps the lines
        setNeedsChipUpdate()
    }

    // MARK: Chips

    /// One chip as drawn: its range, its rects (one per line), its icon, whether it is highlighted,
    /// and the attachment it points to (nil for a link).
    private struct DrawnChip: Equatable {
        let range: NSRange
        let rects: [NSRect]
        let symbol: String
        let isHighlighted: Bool
        let attachmentName: String?
    }

    /// The rounded backgrounds behind the chips, one per line a chip covers (reused).
    private var chipViews: [RoundedHighlightView] = []
    /// The icons at the start of the chips, one per chip (reused).
    private var chipIcons: [ChipIconView] = []
    /// Each chip as drawn, for clicks and the pointer.
    private var drawnChips: [DrawnChip] = []
    private var chipUpdateScheduled = false
    private var chipScale: CGFloat = 0
    private static let chipColor = NSColor.linkColor.withAlphaComponent(0.13)
    /// The chips of the strip's selected or hovered attachment.
    private static let highlightedChipColor = NSColor.controlAccentColor.withAlphaComponent(0.38)

    /// TextKit lays the text out again later (a restyle, a zoom, the panel growing), which can move
    /// the lines under the chip backgrounds; they follow.
    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        setNeedsChipUpdate()
    }

    /// Redraws the chip backgrounds (and the ghost caret), and after an edit reveals the caret,
    /// once the current layout pass is done.
    func setNeedsChipUpdate() {
        guard !chipUpdateScheduled else { return }
        chipUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.chipUpdateScheduled = false
            self.revealCaretIfNeeded()
            self.updateChips()
            self.updateGhost()
        }
    }

    /// The body text size. Not `font` (the first character's font, or the caret's): a note that
    /// starts with a chip starts with its hidden, near-zero `[`.
    private var bodyPointSize: CGFloat { MarkdownStyler.baseFont(scale: bodyScale).pointSize }

    /// The panel zoom the text was last styled at (`MarkdownStyler.apply`).
    var bodyScale: CGFloat = 1

    private func updateChips() {
        let names = coordinator?.parent.attachmentNames ?? []
        let highlighted = coordinator?.parent.highlightedName
        let chips = string.isEmpty ? [] : NoteChips.chips(in: string, attachmentNames: names)
        let drawn = chips.map { chip -> DrawnChip in
            let attachment = chip.attachment
            let symbol = switch attachment?.kind {
            case .image: "photo"
            case .file: "paperclip"
            case nil: "link"
            }
            return DrawnChip(range: chip.range, rects: segmentRects(forCharacters: chip.range), symbol: symbol,
                             isHighlighted: attachment != nil && attachment?.name == highlighted, attachmentName: attachment?.name)
        }
        let scale = bodyPointSize / NSFont.systemFontSize
        // Every layout pass asks; only a change moves the views.
        guard drawn != drawnChips || scale != chipScale else { return }
        drawnChips = drawn
        chipScale = scale
        let rects = drawn.flatMap { chip in chip.rects.map { (rect: $0, isHighlighted: chip.isHighlighted) } }
        let radius = bodyPointSize * 0.35
        while chipViews.count < rects.count {
            let view = RoundedHighlightView(color: Self.chipColor, cornerRadius: radius)
            addSubview(view, positioned: .below, relativeTo: nil)
            chipViews.append(view)
        }
        for (index, view) in chipViews.enumerated() {
            view.isHidden = index >= rects.count
            guard index < rects.count else { continue }
            view.frame = rects[index].rect.insetBy(dx: 0, dy: 1).integral
            view.layer?.cornerRadius = radius
            view.color = rects[index].isHighlighted ? Self.highlightedChipColor : Self.chipColor
        }
        updateChipIcons(for: drawn)
    }

    /// An icon in the space the kerning of `[` leaves at the start of each chip.
    private func updateChipIcons(for chips: [DrawnChip]) {
        let scale = chipScale
        let size = MarkdownStyler.chipIconSize * scale
        let starts = chips.compactMap { chip in chip.rects.first.map { (rect: $0, chip: chip) } }
        while chipIcons.count < starts.count {
            let icon = ChipIconView()
            addSubview(icon, positioned: .above, relativeTo: nil)
            chipIcons.append(icon)
        }
        for (index, icon) in chipIcons.enumerated() {
            icon.isHidden = index >= starts.count
            guard index < starts.count else { continue }
            let (start, chip) = starts[index]
            icon.configure(symbol: chip.symbol, size: size, tint: chip.isHighlighted ? .controlAccentColor : .linkColor)
            icon.frame = NSRect(
                x: start.minX + MarkdownStyler.chipPadding * scale, y: start.midY - size / 2, width: size, height: size
            ).integral
        }
    }

    /// The chip under `point` (view coordinates).
    private func chip(at point: NSPoint) -> DrawnChip? {
        drawnChips.first { $0.rects.contains { $0.contains(point) } }
    }

    // MARK: Ghost caret

    /// Where **I** in the attachments inserts (`MarkdownNoteEditor.ghostSelection`).
    var ghostSelection: NSRange? {
        didSet { if ghostSelection != oldValue { setNeedsChipUpdate() } }
    }

    /// The ghost caret, or the tinted rects of the remembered selection (reused).
    private var ghostViews: [RoundedHighlightView] = []
    private static let ghostCaretColor = NSColor.controlAccentColor.withAlphaComponent(0.5)
    private static let ghostRangeColor = NSColor.controlAccentColor.withAlphaComponent(0.25)

    /// A wide, steady accent caret at `ghostSelection` (a tinted range when it has a length),
    /// only while the focus is elsewhere: the real caret is drawn otherwise.
    private func updateGhost() {
        var frames: [NSRect] = []
        var color = Self.ghostCaretColor
        if let ghost = ghostSelection, window?.firstResponder !== self, NSMaxRange(ghost) <= (string as NSString).length {
            if ghost.length > 0 {
                frames = segmentRects(forCharacters: ghost).map { $0.integral }
                color = Self.ghostRangeColor
            } else if let caret = caretRect(at: ghost.location) {
                let width = max(3, 2.5 * bodyPointSize / NSFont.systemFontSize)
                frames = [NSRect(x: caret.minX - width / 2, y: caret.minY, width: width, height: caret.height)]
            }
        }
        while ghostViews.count < frames.count {
            let view = RoundedHighlightView(color: color, cornerRadius: 1.5)
            addSubview(view, positioned: .above, relativeTo: nil)
            ghostViews.append(view)
        }
        for (index, view) in ghostViews.enumerated() {
            view.isHidden = index >= frames.count
            guard index < frames.count else { continue }
            view.frame = frames[index]
            view.color = color
        }
    }

    /// The insertion point's rect at `location` in view coordinates (TextKit 2): the caret's
    /// segment, or the start of the text when there is none yet.
    private func caretRect(at location: Int) -> NSRect? {
        let lineHeight = (font ?? MarkdownStyler.baseFont(scale: 1)).boundingRectForFont.height
        let origin = textContainerOrigin
        return caretSegment(at: location) ?? NSRect(x: origin.x, y: origin.y, width: 0, height: lineHeight)
    }

    /// The caret's segment at `location` in view coordinates, nil when TextKit has none (e.g.
    /// after a space that hangs past the end of a full line).
    private func caretSegment(at location: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location),
              let range = NSTextRange(location: start, end: start),
              let laidOut = NSTextRange(location: content.documentRange.location, end: start) else { return nil }
        layout.ensureLayout(for: laidOut) // from the start, like `segmentRects`
        var caret: NSRect?
        layout.enumerateTextSegments(in: range, type: .selection, options: .rangeNotRequired) { _, frame, _, _ in
            caret = frame
            return false
        }
        guard let caret, caret.height > 0 else { return nil }
        return caret.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The line to keep in view for the caret at `location`: its segment, else the character
    /// before it, else (an empty last line) the end of the text. Never the top: that jumped.
    private func revealRect(at location: Int) -> NSRect? {
        let rect = caretSegment(at: location) ?? {
            let ns = string as NSString
            if location > 0, ns.character(at: location - 1) != 0x0A,
               let previous = segmentRects(forCharacters: NSRange(location: location - 1, length: 1)).last {
                return previous
            }
            return location == ns.length ? NSRect(x: 0, y: bounds.maxY - 1, width: 1, height: 1) : nil
        }()
        // Only the height matters: the text never scrolls sideways.
        return rect.map { NSRect(x: 0, y: $0.minY, width: 1, height: $0.height) }
    }

    /// The first ⌫ after a chip selects it; the next one deletes it (an attachment chip: only
    /// the reference, the attachment stays).
    override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(),
           let chip = NoteChips.deleteBackward(in: string, selection: selectedRange(), attachmentNames: coordinator?.parent.attachmentNames ?? []) {
            setSelectedRange(chip)
        } else {
            super.deleteBackward(sender)
        }
    }

    /// The first ⌦ before a chip selects it; the next one deletes it.
    override func deleteForward(_ sender: Any?) {
        if !hasMarkedText(),
           let chip = NoteChips.deleteForward(in: string, selection: selectedRange(), attachmentNames: coordinator?.parent.attachmentNames ?? []) {
            setSelectedRange(chip)
        } else {
            super.deleteForward(sender)
        }
    }

    /// ⌘V: files copied in Finder, or an image (a screenshot) without text, become attachments
    /// (`Coordinator.attach`); a single web address becomes a link (`Coordinator.pasteURL`).
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if !hasMarkedText(), let text = pasteboard.string(forType: .string), let url = NoteLinks.pastedURL(text),
           Self.fileURLs(on: pasteboard)?.isEmpty ?? true {
            coordinator?.pasteURL(url, in: self)
        } else if let urls = Self.fileURLs(on: pasteboard), !urls.isEmpty {
            coordinator?.attach(urls.map { .file($0) }, in: self)
        } else if !(pasteboard.types ?? []).contains(.string), let png = Self.pngData(on: pasteboard) {
            coordinator?.attach([.image(png)], in: self)
        } else {
            super.paste(sender)
        }
    }

    /// A thumbnail from the strip (`AttachmentDrag`) goes in as a chip at the drop point; files
    /// from elsewhere are attached there.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        if let id = AttachmentDrag.attachmentID(on: pasteboard) {
            window?.makeFirstResponder(self)
            if coordinator?.dropAttachment(id: id, at: index, in: self) == true { return true }
            // Not one of this todo's attachments: treated like any other file below.
        }
        guard let urls = Self.fileURLs(on: pasteboard), !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
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
        let chip = chip(at: point)
        coordinator?.pointerMoved(toAttachmentNamed: chip?.attachmentName)
        updateTaskHover(at: point) // the pointing hand over a box
        if chip != nil { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.pointerMoved(toAttachmentNamed: nil)
        clearTaskHover()
    }

    // MARK: Drops from the strip

    /// NSTextView re-registers its own types now and then (a font or ruler change, a new window);
    /// listing the strip's type here keeps it registered.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [AttachmentDrag.pasteboardType]
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptingStripDrag(super.draggingEntered(sender), sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptingStripDrag(super.draggingUpdated(sender), sender)
    }

    /// A thumbnail from the strip is always welcome (as a copy: it stays attached).
    private func acceptingStripDrag(_ operation: NSDragOperation, _ sender: any NSDraggingInfo) -> NSDragOperation {
        guard AttachmentDrag.isOnPasteboard(sender.draggingPasteboard) else { return operation }
        return operation.isEmpty ? .copy : operation
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.syncFocus(self) // the first update can run before there is a window
    }
}

/// The chip (or bare URL) at the caret and the chip's frame on screen (nil for a bare URL or a
/// chip out of view), for the popover (`ChipPopoverController`).
struct NoteChipAnchor: Equatable {
    let chip: NoteChip
    let frame: CGRect?
}

extension NoteChip {
    /// Drawn as a chip: an attachment reference or a Markdown link (not a bare URL).
    var isChip: Bool {
        switch self {
        case .link(let link): link.isChip
        case .attachment: true
        }
    }
}

/// A soft rounded background behind a hovered task box or a link chip. Never takes the mouse:
/// clicks go to the text view, which hit-tests boxes and chips itself.
private final class RoundedHighlightView: NSView {
    var color: NSColor {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    init(color: NSColor, cornerRadius: CGFloat) {
        self.color = color
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
        layer?.backgroundColor = color.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The symbol at the start of a chip (a link, a paperclip, a photo). Never takes the mouse, like
/// the chip's background.
private final class ChipIconView: NSImageView {
    private var size: CGFloat = 0
    private var symbol = ""

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        contentTintColor = .linkColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(symbol: String, size: CGFloat, tint: NSColor) {
        if contentTintColor != tint { contentTintColor = tint }
        guard size != self.size || symbol != self.symbol else { return }
        self.size = size
        self.symbol = symbol
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
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

    /// Behind inline code, and behind a fenced code block (`BlockLayoutFragment` draws that one).
    nonisolated static let codeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)

    /// Xcode-like colours for the tokens in a code block; system colours, so they follow dark mode.
    private static func codeColor(_ token: CodeHighlighter.Token) -> NSColor {
        switch token {
        case .keyword, .literal: .systemPink
        case .string: .systemRed
        case .number: .systemPurple
        case .comment: .secondaryLabelColor
        case .property: .systemBlue
        case .type: .systemTeal
        }
    }

    /// Restyles the whole text; links and the references to the attachment `names` become chips
    /// (`NoteChips`), those of `highlightedName` in the accent colour (`NoteTextView` draws their
    /// backgrounds and icons).
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
        markBlocks(MarkdownHighlighter.codeBlocks(in: storage.string), as: .codeBlockLine, in: storage, scale: scale)
        markBlocks(MarkdownHighlighter.quoteBlocks(in: storage.string), as: .quoteLine, in: storage, scale: scale)
        markBlocks(spans.filter { $0.style == .rule }.map(\.range), as: .ruleLine, in: storage, scale: scale)
        for chip in NoteChips.chips(in: storage.string, attachmentNames: names) {
            let isHighlighted = highlightedName != nil && chip.attachment?.name == highlightedName
            applyChip(chip, to: storage, scale: scale, color: isHighlighted ? .controlAccentColor : .linkColor)
        }
        storage.endEditing()
        // Restyling every line drops their layout; lines out of view would get estimated heights,
        // the text's height would change with each keystroke and the view jump. Notes are short:
        // lay it all out again.
        if let layout = textView.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        textView.typingAttributes = base
        (textView as? NoteTextView)?.bodyScale = scale
        (textView as? NoteTextView)?.setNeedsChipUpdate()
    }

    /// A chip: the title in `color`, `[` (or `![`) and `](target)` invisible and next to no width,
    /// their kerning the chip's padding, and before the title the room for its icon
    /// (`NoteTextView` draws the rounded background and the icon).
    private static func applyChip(_ chip: NoteChip, to storage: NSTextStorage, scale: CGFloat, color: NSColor) {
        let title = chip.titleRange
        let range = chip.range
        let open = NSRange(location: range.location, length: title.location - range.location)
        let close = NSRange(location: NSMaxRange(title), length: NSMaxRange(range) - NSMaxRange(title))
        let hidden: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]
        storage.addAttributes(hidden, range: open)
        storage.addAttributes(hidden, range: close)
        // The last opening character (`[`) carries the room for the padding and the icon.
        storage.addAttribute(.kern, value: (chipPadding + chipIconSize + chipIconGap) * scale,
                             range: NSRange(location: title.location - 1, length: 1))
        storage.addAttribute(.kern, value: chipPadding * scale, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        storage.removeAttribute(.underlineStyle, range: title)
        storage.addAttribute(.foregroundColor, value: color, range: title)
    }

    /// Marks each line of the blocks with `key` (a `BlockLine`), for `BlockLayoutFragment` to draw
    /// the code box or the quote bar with the text. A code line is also inset, inside its box.
    private static func markBlocks(_ blocks: [NSRange], as key: NSAttributedString.Key, in storage: NSTextStorage, scale: CGFloat) {
        let ns = storage.string as NSString
        for block in blocks {
            var paragraphs: [NSRange] = []
            ns.enumerateSubstrings(in: block, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
                paragraphs.append(enclosing)
            }
            for (index, paragraph) in paragraphs.enumerated() {
                let line = BlockLine(isFirst: index == 0, isLast: index == paragraphs.count - 1, scale: scale)
                storage.addAttribute(key, value: line, range: paragraph)
                guard key == .codeBlockLine else { continue }
                let style = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
                    .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.firstLineHeadIndent = BlockLayoutFragment.codeInset * scale
                style.headIndent = BlockLayoutFragment.codeInset * scale
                style.tailIndent = -BlockLayoutFragment.codeInset * scale
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            }
        }
    }

    /// The space inside a chip at each end, at 100 %.
    static let chipPadding: CGFloat = 5
    /// The link icon at the start of a chip, and the space between it and the title, at 100 %.
    static let chipIconSize: CGFloat = 11
    private static let chipIconGap: CGFloat = 3

    /// Blocks first, inline styles on top, dimming last; a task box and its check last of all.
    /// A ticked item's grey and strike-through go right after the inline styles: its bold and
    /// italic fonts stay, a link in it turns grey too, and its markup is still dimmed below that.
    private static func order(_ style: MarkdownStyleSpan.Style) -> Int {
        switch style {
        case .heading, .quote, .codeBlock, .rule: 0
        case .bold, .italic, .strikethrough, .link, .listMarker, .code: 1
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
            // A block's background is one rounded box drawn with its lines (`BlockLayoutFragment`),
            // without the gaps the line spacing leaves between per-line backgrounds.
            if span.style == .inlineCode {
                storage.addAttribute(.backgroundColor, value: codeBackground, range: range)
            }
        case .code(let token):
            storage.addAttribute(.foregroundColor, value: codeColor(token), range: range)
        case .quote:
            transformFont(in: range, of: storage, scale: scale) { withTraits(.italic, $0) }
        case .quoteMarker:
            // Invisible, but keeping its width: `BlockLayoutFragment` draws the quote's bar there.
            storage.addAttributes([
                .foregroundColor: NSColor.clear,
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
        case .syntax, .taskBox, .rule:
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

// MARK: - Code boxes and quote bars

extension NSAttributedString.Key {
    /// A line of a fenced code block (a `BlockLine`).
    static let codeBlockLine = NSAttributedString.Key("HowyCodeBlockLine")
    /// A line of a quote (a `BlockLine`).
    static let quoteLine = NSAttributedString.Key("HowyQuoteLine")
    /// A thematic break line, "---" (a `BlockLine`).
    static let ruleLine = NSAttributedString.Key("HowyRuleLine")
}

/// Where a line sits in its code block or quote: the first rounds the top corners, the last the
/// bottom ones. `scale` is the panel zoom.
final class BlockLine: NSObject {
    let isFirst: Bool
    let isLast: Bool
    let scale: CGFloat

    init(isFirst: Bool, isLast: Bool, scale: CGFloat) {
        self.isFirst = isFirst
        self.isLast = isLast
        self.scale = scale
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockLine else { return false }
        return isFirst == other.isFirst && isLast == other.isLast && scale == other.scale
    }

    override var hash: Int { Int(scale * 100) * 4 + (isFirst ? 2 : 0) + (isLast ? 1 : 0) }
}

/// Gives the lines of code blocks and quotes a `BlockLayoutFragment`, so the box or bar is laid
/// out and drawn with the text itself and can never drift from it.
final class BlockLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let range = textElement.elementRange
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else {
            return NSTextLayoutFragment(textElement: textElement, range: range)
        }
        let text = paragraph.attributedString
        if let line = text.attribute(.codeBlockLine, at: 0, effectiveRange: nil) as? BlockLine {
            return BlockLayoutFragment(textElement: textElement, range: range, line: line, kind: .code)
        }
        if let line = text.attribute(.quoteLine, at: 0, effectiveRange: nil) as? BlockLine {
            let marker = (text.string as NSString).range(of: ">")
            return BlockLayoutFragment(textElement: textElement, range: range, line: line, kind: .quote(marker: marker.location))
        }
        if let line = text.attribute(.ruleLine, at: 0, effectiveRange: nil) as? BlockLine {
            return BlockLayoutFragment(textElement: textElement, range: range, line: line, kind: .rule)
        }
        return NSTextLayoutFragment(textElement: textElement, range: range)
    }
}

/// A line of a code block, on its part of the rounded box the width of the text, a line of a
/// quote, with its part of the accent bar where the (hidden) `>` sits, or a rule line. Consecutive lines' parts
/// meet, line spacing included, so a block reads as one box or one bar.
final class BlockLayoutFragment: NSTextLayoutFragment {
    enum Kind {
        case code
        /// `marker`: the `>`'s offset in the line.
        case quote(marker: Int)
        /// A horizontal rule across the width, through the (dimmed) dashes.
        case rule
    }

    /// The text's inset inside a code box, at 100 %.
    static let codeInset: CGFloat = 8

    private let line: BlockLine
    private let kind: Kind

    init(textElement: NSTextElement, range: NSTextRange?, line: BlockLine, kind: Kind) {
        self.line = line
        self.kind = kind
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The box or bar, in the fragment's coordinates.
    private var decoration: CGRect {
        let height = layoutFragmentFrame.height
        switch kind {
        case .code:
            let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
            return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: width, height: height)
        case .quote(let marker):
            var x: CGFloat = 0
            if let first = textLineFragments.first, marker != NSNotFound, marker < first.attributedString.length {
                x = first.typographicBounds.minX + first.locationForCharacter(at: marker).x
            }
            return CGRect(x: x, y: 0, width: 3 * line.scale, height: height)
        case .rule:
            let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
            let thickness = max(1, line.scale)
            var y = height / 2
            if let first = textLineFragments.first, first.attributedString.length > 0,
               let font = first.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                // Through the middle of a dash: half the x-height above the baseline.
                y = first.typographicBounds.minY + first.glyphOrigin.y - font.xHeight / 2
            }
            return CGRect(x: -layoutFragmentFrame.minX, y: y - thickness / 2, width: width, height: thickness)
        }
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(decoration) }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = decoration.offsetBy(dx: point.x, dy: point.y)
        let (color, radius): (NSColor, CGFloat) = switch kind {
        case .code: (MarkdownStyler.codeBackground, 6 * line.scale)
        case .quote: (NSColor.controlAccentColor.withAlphaComponent(0.7), 1.5 * line.scale)
        case .rule: (NSColor.tertiaryLabelColor, 0)
        }
        // Only the block's outer corners are round: the shape runs past the clip where it meets
        // the next line.
        var shape = rect
        if !line.isFirst { shape.origin.y -= radius; shape.size.height += radius }
        if !line.isLast { shape.size.height += radius }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSBezierPath(rect: rect).addClip()
        color.setFill()
        NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        super.draw(at: point, in: context)
    }
}
