import HowyCore
import SwiftUI

/// The quick-entry and edit modal: a thin view over `QuickEntryFlow`.
/// Keys arrive via `FloatingPanel.keyHandler`; this view only renders the flow and keeps focus in sync.
/// `inTile`: inside an Overview tile, where the note takes the height the tile has left and the
/// key hints shorten to fit.
struct QuickEntryView: View {
    let model: QuickEntryModel
    var inTile = false

    /// Only the title is a SwiftUI focus target; the note editor (AppKit) focuses itself from the phase.
    private enum Field: Hashable { case title }
    @FocusState private var focus: Field?
    @State private var panel = PanelBox()
    /// Heights measured in an Overview tile: the room above the footer, the fields above the note,
    /// and the attachment divider and strip (the last height they had while shown).
    @State private var tileSpace = TileSpace()
    /// The last unfinished phase, so the layout doesn't flip while the panel fades out after Esc/save.
    @State private var activePhase: QuickEntryFlow.Phase?
    @Environment(\.panelScale) private var scale

    private var flow: QuickEntryFlow { model.flow }

    private var shownPhase: QuickEntryFlow.Phase {
        flow.isFinished ? (activePhase ?? flow.phase) : flow.phase
    }

    var body: some View {
        Group { // the card is drawn once by the panel (PanelRoot)
            VStack(alignment: .leading, spacing: gap) {
                if inTile {
                    tileContent
                } else if shownPhase == .pickingQuadrant {
                    picker
                } else {
                    fields()
                }
                footer
            }
        }
        .overlay { linkDialog }
        .overlay { attachmentDialog }
        .dueDialogOverlay(isPresented: flow.dueDialog != nil, topInset: 40 * scale, onDismiss: { flow.cancelDue() }) {
            dueDialog
        }
        .background(WindowReader { panel.window = $0 as? FloatingPanel })
        .onChange(of: flow.dueDialog == nil) { _, closed in
            // Back from the due-date dialog: the field under it gets the keyboard again.
            if closed, !flow.isFinished { DispatchQueue.main.async { focusField(for: flow.phase) } }
        }
        .onChange(of: flow.phase) { _, phase in
            if !flow.isFinished { activePhase = phase }
            // Defer: the target field may only be inserted by this very phase change.
            DispatchQueue.main.async { focusField(for: phase) }
        }
        .onChange(of: focus) { _, field in
            // A click into the title moves the flow there.
            if field == .title, flow.phase != .editingTitle { flow.focus(.editingTitle) }
        }
        .onAppear {
            activePhase = flow.phase
            DispatchQueue.main.async { focusField(for: flow.phase) }
        }
    }

    /// Moves focus to the phase's field. A refocused title field selects all of its text, so the
    /// next keystroke would replace the title: put the caret at the end every time.
    private func focusField(for phase: QuickEntryFlow.Phase) {
        switch phase {
        case .editingTitle:
            focus = .title
            DispatchQueue.main.async { panel.window?.moveCaretToEnd() }
        case .pickingQuadrant, .browsingAttachments:
            focus = nil
        default:
            break // the note editor takes focus itself
        }
    }

    private var picker: some View {
        QuadrantGrid(highlighted: flow.quadrant) { flow.choose($0) }
    }

    /// In an Overview tile, which may be low: the note takes the height left. When even its
    /// smallest height doesn't fit, the attachment strip goes first, then everything above the
    /// footer scrolls; the footer (Save, Done) stays pinned below. Worked out from measured
    /// heights (one copy of the fields, so the text views and their focus stay single).
    @ViewBuilder private var tileContent: some View {
        Group {
            if shownPhase == .pickingQuadrant {
                if tileSpace.available < Self.pickerHeight * scale {
                    ScrollView { picker }
                } else {
                    picker
                }
            } else if tileSpace.available < tileSpace.head + gap + noteMinHeight {
                ScrollView {
                    VStack(alignment: .leading, spacing: gap) { fields(fillsHeight: false, showsAttachments: false) }
                }
            } else {
                let full = tileSpace.head + gap + noteMinHeight + gap + tileSpace.attachments
                VStack(alignment: .leading, spacing: gap) {
                    fields(fillsHeight: true, showsAttachments: tileSpace.available >= full)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tileSpace.available = $0 }
    }

    /// The quadrant picker's lowest height at 100 %: two rows of 72 pt cards and the gap.
    private static let pickerHeight: CGFloat = 2 * 72 + 10
    /// The gap between the sections (12 pt at 100 %).
    private var gap: CGFloat { 12 * scale }
    private var noteMinHeight: CGFloat { MarkdownNoteEditor.minHeight * scale }

    /// `fillsHeight`: the note takes the height offered (in a tile). `showsAttachments`: the
    /// attachment divider and strip below the note.
    @ViewBuilder private func fields(fillsHeight: Bool = false, showsAttachments: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: gap) {
                Button { flow.focus(.pickingQuadrant) } label: {
                    QuadrantChip(quadrant: flow.quadrant)
                }
                .buttonStyle(.plain)
                .help("Change quadrant (⇧⇥)")
                Spacer(minLength: 0)
                TimelineView(.everyMinute) { _ in
                    DuePill(due: flow.due, now: flow.now) { flow.beginDueDate() }
                }
            }

            // Vertical: a single-line field swaps in AppKit's field editor on focus, which draws
            // the text a few points off, so the title jumped. A long title wraps (up to 3 lines);
            // a pasted line break becomes a space (↩ itself never reaches the field).
            TextField("Title", text: Binding(
                get: { flow.title },
                set: { flow.title = $0.replacingOccurrences(of: "\n", with: " ") }
            ), axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .panelFont(.title2)
                .focused($focus, equals: .title)

            Divider()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if inTile { tileSpace.head = $0 } }

        MarkdownNoteEditor(
            text: flow.note,
            isFocused: flow.phase == .editingNote && !flow.hasDialog,
            onChange: { flow.note = $0 },
            onFocus: { flow.focus(.editingNote) },
            attachmentNames: Set(flow.attachmentNames),
            highlightedName: model.highlightedName,
            ghostSelection: flow.ghostNoteSelection,
            onSelectionChange: { flow.noteSelectionChanged($0) },
            onAttach: { model.attach($0) },
            onPasteAttachment: { model.beginAddingAttachment($0, replacing: $1) },
            onDropAttachment: { model.dropAttachment(id: $0, replacing: $1) },
            onOpenAttachment: { model.openAttachment(named: $0, alternate: $1) },
            onEditAttachment: { chip in withAnimation(.snappy(duration: 0.15)) { flow.beginEditingAttachment(chip) } },
            onReferenceChange: { model.noteReferenceName = $0 },
            pendingEdit: flow.pendingNoteEdit,
            onEditApplied: { flow.noteEditApplied(id: $0) },
            onPasteURL: { flow.beginAddingLink(url: $0, replacing: $1) },
            onEditLink: { flow.beginEditingLink($0) },
            onOpenLink: { model.openLink($0) },
            onChipChange: { model.noteChip = $0 },
            fillsHeight: fillsHeight
        )
        .frame(maxHeight: fillsHeight ? .infinity : nil)
        .overlay(alignment: .topLeading) { chipPopover }
        .overlay(alignment: .topLeading) {
            if flow.note.isEmpty {
                Text("Note (Markdown)")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2 * scale)
                    .allowsHitTesting(false)
            }
        }

        if showsAttachments {
            VStack(alignment: .leading, spacing: gap) {
                AttachmentDivider(name: model.spotlightName)
                AttachmentStrip(model: model)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if inTile { tileSpace.attachments = $0 } }
        }
    }

    /// Under the chip at the caret: a link's URL, or an attachment's file name (and thumbnail),
    /// with Open and Edit.
    @ViewBuilder private var chipPopover: some View {
        if let anchor = model.noteChip, anchor.chip.isChip, let frame = anchor.frame,
           flow.phase == .editingNote, !flow.hasDialog {
            GeometryReader { editor in
                Group {
                    switch anchor.chip {
                    case .link(let link):
                        LinkPopover(
                            link: link,
                            onOpen: { model.openLink(link) },
                            onEdit: { flow.beginEditingLink(link) }
                        )
                    case .attachment(let chip):
                        AttachmentChipPopover(
                            chip: chip,
                            source: model.attachment(named: chip.name).flatMap(model.url(for:)).map { .file($0) },
                            onOpen: { model.openAttachment(named: chip.name, alternate: NSEvent.modifierFlags.contains(.option)) },
                            onEdit: { withAnimation(.snappy(duration: 0.15)) { flow.beginEditingAttachment(chip) } }
                        )
                    }
                }
                // Starts under the chip, but not so far right that it leaves the card.
                .offset(x: max(0, min(frame.minX, editor.size.width - Self.popoverRoom * scale)), y: frame.maxY + 4 * scale)
            }
        }
    }

    /// The width kept free for the popover at the editor's right edge, at 100 %.
    private static let popoverRoom: CGFloat = 330

    /// The due-date dialog over the whole card (`dueDialogOverlay` dims the rest and makes room).
    @ViewBuilder private var dueDialog: some View {
        if let dialog = flow.dueDialog {
            DueDateDialogView(dialog: dialog, now: flow.now, actions: DueDateDialogActions(
                setText: { flow.setDueText($0) },
                confirm: { flow.confirmDue() },
                cancel: { flow.cancelDue() },
                remove: { flow.removeDue() },
                toggleExamples: { flow.toggleDueExamples() },
                pickExample: { flow.pickDueExample($0) }
            ))
        }
    }

    /// The attachment dialog over the whole card, like the link dialog; a click beside it cancels.
    @ViewBuilder private var attachmentDialog: some View {
        if let dialog = flow.attachmentDialog {
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancelAttachment() }
                AttachmentDialogView(model: model, dialog: dialog)
                    .padding(.top, 40 * scale)
                    .padding(.horizontal, 16 * scale)
            }
            .transition(.opacity)
        }
    }

    /// The link dialog over the whole card; a click beside it cancels. Not dimmed, like the
    /// due-date dialog: a tint here covers only the screen inside the card's padding, a
    /// square-cornered block rather than the rounded card.
    @ViewBuilder private var linkDialog: some View {
        if let dialog = flow.linkDialog {
            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { flow.cancelLink() }
                LinkDialogView(flow: flow, dialog: dialog)
                    .padding(.top, 40 * scale)
                    .padding(.horizontal, 16 * scale)
            }
            .transition(.opacity)
        }
    }

    private var footer: some View {
        HStack(spacing: gap) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if flow.showsEmptyTitleHint {
                Label("Add a title to save", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            } else if flow.showsRestoredHint {
                Label(
                    flow.isEditing ? "Unsaved edit restored · esc discards" : "Draft restored",
                    systemImage: "arrow.uturn.backward"
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            KeyHints(hint, short: inTile ? shortHint : hintWithoutChecklist)
            // Real buttons for the mouse: the key hints alone were easy to miss.
            if shownPhase != .pickingQuadrant {
                if flow.isEditing {
                    Button("Done") { model.complete() }
                        .disabled(!flow.canSave)
                        .help("Save and mark done, moving it to the archive (⌘D)")
                }
                Button("Save") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!flow.canSave)
                    .help("Save (⌘↩)")
            }
        }
        .buttonStyle(.bordered)
        .panelControlSize(.small)
        .panelFont(.caption)
        .lineLimit(1)
    }

    /// The hints in a tile, when the full ones don't fit.
    private var shortHint: String {
        let esc = flow.isEditing ? "cancel" : closeWord
        return shownPhase == .pickingQuadrant ? "1–4 choose · esc \(esc)" : "⌘↩ save · esc \(esc)"
    }

    /// ⇧⌘L (checklist items) only while the note has focus; it is the first hint to go when the
    /// footer is too narrow.
    /// With the caret on a link or an attachment chip, its keys take the checklist's place.
    private var hint: String {
        guard shownPhase == .editingNote else { return baseHint }
        let chipHint = switch model.noteChip?.chip {
        case .link: Self.linkHint
        case .attachment: Self.attachmentHint
        case nil: Self.checklistHint
        }
        return baseHint + KeyHint.separator + chipHint
    }

    private var hintWithoutChecklist: String? {
        shownPhase == .editingNote ? baseHint : nil
    }

    private static let checklistHint = "⇧⌘L checklist"
    private static let linkHint = "⌘O open · ⌘E edit link"
    private static let attachmentHint = "⌘O open · ⌘E edit"

    private var baseHint: String {
        switch shownPhase {
        case .pickingQuadrant: "←↑↓→ or 1–4 · ↩ choose · esc " + (flow.isEditing ? "cancel" : closeWord)
        case .editingTitle: "↩ note · ⌥↩ files · ⌘T due · ⌘↩ save · esc " + (flow.isEditing ? "cancel · ⌘D done" : closeWord)
        case .browsingAttachments where flow.attachments.isEmpty: "↩ add files · ⇧⇥ note · ⌘↩ save · esc " + (flow.isEditing ? "cancel" : closeWord)
        case .browsingAttachments where flow.isAddSelected: "↩ add files · ← select · ⇧⇥ note · ⌘↩ save"
        case .browsingAttachments: "←→ select · space open · I insert · ⌥↩ other way · ⌫ remove · ⇧⇥ note"
        default: "⌘↩ save · ⌥↩ files · ⌘T due · ⇧⇥ title · esc " + (flow.isEditing ? "cancel · ⌘D done" : closeWord)
        }
    }

    /// What Esc does to a new todo: closes the panel, or goes back to where it was opened from
    /// (Browse's grid or list, an Overview tile's list). An edit says "cancel" either way:
    /// Esc discards it.
    private var closeWord: String { model.escapeReturns ? "back" : "close" }
}

/// `QuickEntryView`'s measured heights in an Overview tile.
private struct TileSpace {
    var available: CGFloat = .infinity
    var head: CGFloat = 0
    var attachments: CGFloat = 14 + 12 + 72
}

/// Holds the panel found by `WindowReader` without triggering view updates.
@MainActor
private final class PanelBox {
    weak var window: FloatingPanel?
}

/// Reports the hosting window once the view is in one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
    }
}
