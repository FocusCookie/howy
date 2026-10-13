import AppKit
import HowyCore
import SwiftUI

/// The mini dialog over the note for an attachment chip (`QuickEntryFlow.attachmentDialog`), in the
/// style of `LinkDialogView`: "Add Attachment" for a pasted or dropped file, **I** or a thumbnail
/// dragged onto the note, "Edit Attachment" for ⌘E on a chip. Only the chip's title is edited, the
/// file name is the subtitle; images show a thumbnail. Keys come through the flow (↩, Esc, ⌘⌫,
/// and Y / N while it asks "Also delete the attachment?"); this only renders the dialog, keeps
/// the field focused and offers buttons for the mouse.
struct AttachmentDialogView: View {
    let model: QuickEntryModel
    let dialog: QuickEntryFlow.AttachmentDialog
    @FocusState private var isTitleFocused: Bool
    @Environment(\.panelScale) private var scale

    private var flow: QuickEntryFlow { model.flow }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(alignment: .top, spacing: 10 * scale) {
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(dialog.isEditing ? "Edit Attachment" : "Add Attachment")
                        .panelFont(.headline)
                    Text(dialog.fileName)
                        .panelFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if dialog.isImage {
                    AttachmentPreviewImage(source: model.preview(for: dialog), name: dialog.fileName)
                        .frame(width: 44 * scale, height: 44 * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6 * scale, style: .continuous).strokeBorder(Color.primary.opacity(0.12))
                        }
                }
            }

            if dialog.isAskingToDeleteAttachment {
                Text("Also delete the attachment “\(dialog.fileName)”?")
                    .panelFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8 * scale) {
                    KeyHints("Y yes · N no · esc back")
                    Spacer(minLength: 8 * scale)
                    Button("No") { model.answerDeleteAttachment(false) }
                        .help("Remove only the chip; keep the attachment (N)")
                    Button("Yes", role: .destructive) { model.answerDeleteAttachment(true) }
                        .buttonStyle(.borderedProminent)
                        .help("Remove the chip and delete the attachment (Y)")
                }
                .buttonStyle(.bordered)
                .panelControlSize(.small)
                .panelFont(.caption)
            } else {
                TextField(dialog.placeholder, text: Binding(get: { dialog.title }, set: { flow.setAttachmentTitle($0) }))
                    .textFieldStyle(.roundedBorder)
                    .panelFont(.body)
                    .focused($isTitleFocused)
                HStack(spacing: 8 * scale) {
                    KeyHints(dialog.isEditing ? "↩ save · esc cancel" : "↩ add · esc cancel")
                    Spacer(minLength: 8 * scale)
                    if dialog.isEditing {
                        Button("Remove") { model.removeAttachmentReference() }
                            .help("Remove the chip from the note (⌘⌫)")
                    }
                    Button("Cancel") { model.cancelAttachment() }
                    Button(dialog.isEditing ? "Save" : "Add") { model.confirmAttachment() }
                        .buttonStyle(.borderedProminent)
                }
                .buttonStyle(.bordered)
                .panelControlSize(.small)
                .panelFont(.caption)
            }
        }
        .padding(14 * scale)
        .frame(maxWidth: 420 * scale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).strokeBorder(.separator)
        }
        .shadow(color: .black.opacity(0.18), radius: 16 * scale, y: 6 * scale)
        .onAppear {
            // Next turn: the field must be in the window before it can take focus (which selects
            // its text, so typing replaces the default title).
            DispatchQueue.main.async { isTitleFocused = true }
        }
        .onChange(of: dialog.isAskingToDeleteAttachment) { _, asking in
            // Back from the question (Esc): the field returns and takes the keyboard again.
            if !asking { DispatchQueue.main.async { isTitleFocused = true } }
        }
    }
}

/// The small popover under an attachment chip at the caret: the file's name with its extension,
/// a thumbnail for an image, and Open and Edit with their keys.
struct AttachmentChipPopover: View {
    let chip: AttachmentChip
    let source: QuickEntryModel.AttachmentSource?
    let onOpen: () -> Void
    let onEdit: () -> Void
    @Environment(\.panelScale) private var scale

    var body: some View {
        HStack(spacing: 8 * scale) {
            if chip.isImage {
                AttachmentPreviewImage(source: source, name: chip.name)
                    .frame(width: 22 * scale, height: 22 * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 4 * scale, style: .continuous))
            } else {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
            }
            Text(chip.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200 * scale, alignment: .leading)
            Button(action: onOpen) { label("Open", key: "O") }
                .help("Open it as set in Settings (⌘O); ⌥⌘O the other way")
            Button(action: onEdit) { label("Edit", key: "E") }
                .help("Edit the chip's title (⌘E)")
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

/// A thumbnail of a file (Quick Look) or of pasted image data.
private struct AttachmentPreviewImage: View {
    let source: QuickEntryModel.AttachmentSource?
    let name: String

    var body: some View {
        switch source {
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.05)
            }
        case .file(let url):
            AttachmentThumbnail(url: url, isImage: true, name: name)
        case nil:
            AttachmentThumbnail(url: nil, isImage: true, name: name)
        }
    }
}
