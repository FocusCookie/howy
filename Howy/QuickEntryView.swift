import HowyCore
import SwiftUI

/// The quick-entry and edit modal: a thin view over `QuickEntryFlow`.
/// Keys arrive via `FloatingPanel.keyHandler`; this view only renders the flow and keeps focus in sync.
struct QuickEntryView: View {
    let model: QuickEntryModel

    /// Only the title is a SwiftUI focus target; the note editor (AppKit) focuses itself from the phase.
    private enum Field: Hashable { case title }
    @FocusState private var focus: Field?
    @State private var panel = PanelBox()
    /// The last unfinished phase, so the layout doesn't flip while the panel fades out after Esc/save.
    @State private var activePhase: QuickEntryFlow.Phase?

    private var flow: QuickEntryFlow { model.flow }

    private var shownPhase: QuickEntryFlow.Phase {
        flow.isFinished ? (activePhase ?? flow.phase) : flow.phase
    }

    var body: some View {
        Group { // the card is drawn once by the panel (PanelRoot)
            VStack(alignment: .leading, spacing: 12) {
                if shownPhase == .pickingQuadrant {
                    QuadrantGrid(highlighted: flow.quadrant) { flow.choose($0) }
                } else {
                    fields
                }
                if flow.isConfirmingDelete {
                    DeleteConfirmation(model: model)
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

    @ViewBuilder private var fields: some View {
        @Bindable var bindable = flow
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

        MarkdownNoteEditor(
            text: flow.note,
            isFocused: flow.phase == .editingNote,
            onChange: { flow.note = $0 },
            onFocus: { flow.focus(.editingNote) },
            attachmentNames: Set(flow.attachmentNames),
            highlightedName: model.highlightedName,
            onAttach: { model.attach($0) },
            onReferenceChange: { model.noteReferenceName = $0 }
        )
        .overlay(alignment: .topLeading) {
            if flow.note.isEmpty {
                Text("Note (Markdown)")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }

        AttachmentDivider(name: model.spotlightName)
        AttachmentStrip(model: model)
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
                    flow.isEditing ? "Unsaved edit restored · esc discards" : "Draft restored · ⌘⌫ clear",
                    systemImage: "arrow.uturn.backward"
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            KeyHints(hint)
            // Real buttons for the mouse: the key hints alone were easy to miss.
            if shownPhase != .pickingQuadrant, !flow.isConfirmingDelete {
                if flow.isEditing {
                    Button { model.requestDelete() } label: {
                        Text("Delete").foregroundStyle(.red)
                    }
                    .help("Delete this todo (⌘⌫)")
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

    private var hint: String {
        switch shownPhase {
        case .pickingQuadrant: "←↑↓→ or 1–4 · ↩ choose · esc " + (flow.isEditing ? "cancel" : "close")
        case _ where flow.isConfirmingDelete: "↩ delete · esc keep"
        case .editingTitle: "↩ note · ⌥↩ files · ⌘↩ save · esc " + (flow.isEditing ? "cancel · ⌘⌫ delete" : "close")
        case .browsingAttachments where flow.attachments.isEmpty: "↩ add files · ⇧⇥ note · ⌘↩ save · esc " + (flow.isEditing ? "cancel" : "close")
        case .browsingAttachments where flow.isAddSelected: "↩ add files · ← select · ⇧⇥ note · ⌘↩ save"
        case .browsingAttachments: "←→ select · space open · ⌥↩ other way · ⌫ remove · ⇧⇥ note"
        default: "⌘↩ save · ⌥↩ files · ⇧⇥ title · esc " + (flow.isEditing ? "cancel · ⌘⌫ delete" : "close")
        }
    }
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

private struct DeleteConfirmation: View {
    let model: QuickEntryModel

    var body: some View {
        HStack {
            Image(systemName: "trash").foregroundStyle(.red)
            Text("Delete this todo? It won't go to the archive.")
            Spacer()
            Button("Cancel") { model.cancelDelete() }
            Button("Delete", role: .destructive) { model.confirmDelete() }
        }
        .font(.callout)
        .padding(10)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
