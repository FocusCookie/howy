import HowyCore
import SwiftUI

/// The mini dialog over the note for a link (`QuickEntryFlow.linkDialog`): the title of a pasted
/// URL, or the title and URL of a link being edited. Keys come through the flow (↩, Esc, ⇥, ⌘⌫);
/// this only renders the dialog, keeps its focus in sync and offers buttons for the mouse.
struct LinkDialogView: View {
    let flow: QuickEntryFlow
    let dialog: QuickEntryFlow.LinkDialog
    @FocusState private var focused: QuickEntryFlow.LinkDialog.Field?
    @Environment(\.panelScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(dialog.isEditing ? "Edit Link" : "Add Link")
                    .panelFont(.headline)
                if !dialog.isEditing {
                    Text(dialog.url)
                        .panelFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            field("Title", text: Binding(get: { dialog.title }, set: { flow.setLinkTitle($0) }), as: .title)
            if dialog.isEditing {
                field("URL", text: Binding(get: { dialog.url }, set: { flow.setLinkURL($0) }), as: .url)
            }

            HStack(spacing: 8 * scale) {
                KeyHints(hint)
                Spacer(minLength: 8 * scale)
                if dialog.isEditing {
                    Button("Remove Link") { flow.removeLink() }
                        .help("Keep the title as plain text (⌘⌫)")
                }
                Button("Cancel") { flow.cancelLink() }
                Button(dialog.isEditing ? "Save" : "Add") { flow.confirmLink() }
                    .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)
            .panelControlSize(.small)
            .panelFont(.caption)
        }
        .padding(14 * scale)
        .frame(maxWidth: 420 * scale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).strokeBorder(.separator)
        }
        .shadow(color: .black.opacity(0.18), radius: 16 * scale, y: 6 * scale)
        .onAppear {
            // Next turn: the field must be in the window before it can take focus.
            DispatchQueue.main.async { focused = dialog.field }
        }
        .onChange(of: dialog.field) { _, field in focused = field }
        .onChange(of: focused) { _, field in
            if let field { flow.focusLinkField(field) }
        }
    }

    private var hint: String {
        dialog.isEditing ? "↩ save · ⇥ next · esc cancel" : "↩ add · esc cancel"
    }

    private func field(_ label: String, text: Binding<String>, as field: QuickEntryFlow.LinkDialog.Field) -> some View {
        HStack(spacing: 6 * scale) {
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .panelFont(.body)
                .focused($focused, equals: field)
            if field == .title, dialog.isLookingUpTitle {
                ProgressView()
                    .controlSize(.small)
                    .help("Looking up the page title")
            }
        }
    }
}

/// The small popover under a link chip at the caret: the URL, and Open and Edit with their keys.
struct LinkPopover: View {
    let link: NoteLink
    let onOpen: () -> Void
    let onEdit: () -> Void
    @Environment(\.panelScale) private var scale

    var body: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            Text(link.url)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220 * scale, alignment: .leading)
            Button(action: onOpen) { label("Open", key: "O") }
                .help("Open in the browser (⌘O)")
            Button(action: onEdit) { label("Edit", key: "E") }
                .help("Edit the title and URL (⌘E)")
        }
        .buttonStyle(.plain)
        .panelFont(.caption)
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 5 * scale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous).strokeBorder(.separator)
        }
        .shadow(color: .black.opacity(0.15), radius: 6 * scale, y: 2 * scale)
        .fixedSize()
    }

    private func label(_ title: String, key: String) -> some View {
        HStack(spacing: 3 * scale) {
            Text(title)
            KeyCap(text: "⌘")
            KeyCap(text: key)
        }
        .contentShape(Rectangle())
    }
}
