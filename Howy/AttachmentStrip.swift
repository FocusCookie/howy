import AppKit
import HowyCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The divider between the note and the attachments; it shows the hovered, selected or
/// caret-referenced attachment's name in its middle (`──── attachment-1.png ────`).
struct AttachmentDivider: View {
    let name: String?

    var body: some View {
        HStack(spacing: 8) {
            line
            if let name {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .transition(.opacity)
                line
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.12), value: name)
    }

    private var line: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
    }
}

/// The drop area under the note: thumbnails in the order added, plus a field to add more.
/// Dropping here or clicking attaches without a note reference.
struct AttachmentStrip: View {
    let model: QuickEntryModel
    @State private var isTargeted = false

    private var flow: QuickEntryFlow { model.flow }
    private var isActive: Bool { flow.phase == .browsingAttachments }
    private var isAddSelected: Bool { flow.isAddSelected }
    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        WrapLayout(spacing: 8) {
            ForEach(flow.attachments) { attachment in
                AttachmentTile(
                    attachment: attachment,
                    url: model.url(for: attachment),
                    isSelected: flow.selectedAttachment?.id == attachment.id,
                    isLinked: model.noteReferenceName == attachment.name,
                    model: model
                )
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            addButton
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 56 + 16, alignment: .leading)
        .background(Color.accentColor.opacity(isTargeted ? 0.12 : 0), in: Self.shape)
        .overlay {
            Self.shape.strokeBorder(
                isTargeted || isActive ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.15),
                style: StrokeStyle(lineWidth: isTargeted || isActive ? 1.5 : 1, dash: isActive ? [] : [5, 4])
            )
        }
        .contentShape(Self.shape)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    @ViewBuilder private var addButton: some View {
        Button { model.chooseFiles() } label: {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                Text(flow.attachments.isEmpty ? "Drop files here or click to add" : "Add")
            }
            .font(.caption)
            .foregroundStyle(isAddSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 8)
            .frame(minHeight: flow.attachments.isEmpty ? 40 : 56)
            .background {
                // Selected with the keyboard (→ past the last file): ↩ opens the picker.
                // Not drawn when there are no files: the whole area already shows it's active.
                if isAddSelected, !flow.attachments.isEmpty {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .strokeBorder(Color.accentColor, lineWidth: 3.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Attach files (⌥↩, then ↩)")
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.attach([.file(url)]) }
            }
        }
    }
}

/// One thumbnail: click opens it (⌥-click the other way), hover shows ✕, a ring when selected or
/// when the note's caret is on its reference.
private struct AttachmentTile: View {
    let attachment: TodoAttachment
    let url: URL?
    let isSelected: Bool
    let isLinked: Bool
    let model: QuickEntryModel

    @State private var isHovered = false
    private static let size: CGFloat = 56
    private static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        AttachmentThumbnail(url: url, isImage: attachment.isImage, name: attachment.name)
            .frame(width: Self.size, height: Self.size)
            .clipShape(Self.shape)
            .overlay { Self.shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
            .overlay {
                if isSelected || isLinked {
                    Self.shape.strokeBorder(Color.accentColor, lineWidth: isSelected ? 3.5 : 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Button { model.remove(attachment) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(.black.opacity(0.65), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("Remove")
                    .transition(.opacity)
                }
            }
            .scaleEffect(isLinked && !isSelected ? 1.06 : 1)
            .animation(.snappy(duration: 0.15), value: isLinked)
            .contentShape(Self.shape)
            .onTapGesture {
                model.open(attachment, alternate: NSEvent.modifierFlags.contains(.option))
            }
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.1)) { isHovered = inside }
                if inside {
                    model.hoveredAttachmentID = attachment.id
                } else if model.hoveredAttachmentID == attachment.id {
                    model.hoveredAttachmentID = nil
                }
            }
            .contextMenu {
                Button("Quick Look") { model.presenterOpen(attachment, mode: .quickLook) }
                Button("Open in Default App") { model.presenterOpen(attachment, mode: .defaultApp) }
                Divider()
                Button("Remove", role: .destructive) { model.remove(attachment) }
            }
            .accessibilityElement()
            .accessibilityLabel(attachment.name)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Remove") { model.remove(attachment) }
    }
}

/// A Quick Look thumbnail of the file (the image itself, a PDF page, …), or its icon.
private struct AttachmentThumbnail: View {
    let url: URL?
    let isImage: Bool
    let name: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.05)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isImage ? .fill : .fit)
                    .padding(isImage ? 0 : 6)
            } else if url == nil {
                Image(systemName: "questionmark.square.dashed").foregroundStyle(.tertiary)
            }
        }
        .task(id: url) { image = await Self.thumbnail(for: url) }
    }

    private static func thumbnail(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 112, height: 112),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }
}

/// Lays children out left to right, wrapping into new rows (vertically centred per row).
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A paperclip with the count when above one (Browse and archive rows).
struct AttachmentBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 1) {
                Image(systemName: "paperclip")
                if count > 1 { Text("\(count)").monospacedDigit() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(count == 1 ? "1 attachment" : "\(count) attachments")
        }
    }
}
