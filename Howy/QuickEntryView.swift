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

    private var flow: QuickEntryFlow { model.flow }

    private var shownPhase: QuickEntryFlow.Phase {
        flow.isFinished ? (activePhase ?? flow.phase) : flow.phase
    }

    var body: some View {
        Group { // the card is drawn once by the panel (PanelRoot)
            VStack(alignment: .leading, spacing: 12) {
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
        .background(WindowReader { panel.window = $0 as? FloatingPanel })
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
                if tileSpace.available < Self.pickerHeight {
                    ScrollView { picker }
                } else {
                    picker
                }
            } else if tileSpace.available < tileSpace.head + 12 + MarkdownNoteEditor.minHeight {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) { fields(fillsHeight: false, showsAttachments: false) }
                }
            } else {
                let full = tileSpace.head + 12 + MarkdownNoteEditor.minHeight + 12 + tileSpace.attachments
                VStack(alignment: .leading, spacing: 12) {
                    fields(fillsHeight: true, showsAttachments: tileSpace.available >= full)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tileSpace.available = $0 }
    }

    /// The quadrant picker's lowest height: two rows of 72 pt cards and the gap.
    private static let pickerHeight: CGFloat = 2 * 72 + 10

    /// `fillsHeight`: the note takes the height offered (in a tile). `showsAttachments`: the
    /// attachment divider and strip below the note.
    @ViewBuilder private func fields(fillsHeight: Bool = false, showsAttachments: Bool = true) -> some View {
        @Bindable var bindable = flow
        VStack(alignment: .leading, spacing: 12) {
            Button { flow.focus(.pickingQuadrant) } label: {
                QuadrantChip(quadrant: flow.quadrant)
            }
            .buttonStyle(.plain)
            .help("Change quadrant (⇧⇥)")

            TextField("Title", text: $bindable.title)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($focus, equals: .title)

            Divider()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if inTile { tileSpace.head = $0 } }

        MarkdownNoteEditor(
            text: flow.note,
            isFocused: flow.phase == .editingNote,
            onChange: { flow.note = $0 },
            onFocus: { flow.focus(.editingNote) },
            attachmentNames: Set(flow.attachmentNames),
            highlightedName: model.highlightedName,
            onAttach: { model.attach($0) },
            onReferenceChange: { model.noteReferenceName = $0 },
            fillsHeight: fillsHeight
        )
        .frame(maxHeight: fillsHeight ? .infinity : nil)
        .overlay(alignment: .topLeading) {
            if flow.note.isEmpty {
                Text("Note (Markdown)")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }

        if showsAttachments {
            VStack(alignment: .leading, spacing: 12) {
                AttachmentDivider(name: model.spotlightName)
                AttachmentStrip(model: model)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if inTile { tileSpace.attachments = $0 } }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
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
            KeyHints(hint, short: inTile ? shortHint : nil)
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
        .controlSize(.small)
        .font(.caption)
        .lineLimit(1)
    }

    /// The hints in a tile, when the full ones don't fit.
    private var shortHint: String {
        shownPhase == .pickingQuadrant ? "1–4 choose · esc cancel" : "⌘↩ save · esc cancel"
    }

    private var hint: String {
        switch shownPhase {
        case .pickingQuadrant: "←↑↓→ or 1–4 · ↩ choose · esc " + (flow.isEditing ? "cancel" : "close")
        case .editingTitle: "↩ note · ⌥↩ files · ⌘↩ save · esc " + (flow.isEditing ? "cancel · ⌘D done" : "close")
        case .browsingAttachments where flow.attachments.isEmpty: "↩ add files · ⇧⇥ note · ⌘↩ save · esc " + (flow.isEditing ? "cancel" : "close")
        case .browsingAttachments where flow.isAddSelected: "↩ add files · ← select · ⇧⇥ note · ⌘↩ save"
        case .browsingAttachments: "←→ select · space open · ⌥↩ other way · ⌫ remove · ⇧⇥ note"
        default: "⌘↩ save · ⌥↩ files · ⇧⇥ title · esc " + (flow.isEditing ? "cancel · ⌘D done" : "close")
        }
    }
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
