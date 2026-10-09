import AppKit
import HowyCore
import SwiftUI

/// Archived todos, newest-completed first, with Restore and Delete per row.
/// A thin view over `ArchiveFlow` (via `ArchiveModel`); keys arrive via `FloatingPanel.keyHandler`.
struct ArchiveView: View {
    let model: ArchiveModel
    /// What Esc does here: closes the panel, or goes back to Browse when opened from there.
    var escapeHint = "esc close"
    @Environment(\.colorScheme) private var colorScheme
    @State private var pointer = PointerTracker()
    @Environment(\.panelScale) private var scale
    @Environment(\.panelHeightLimit) private var heightLimit
    private let retention = ArchiveRetention.load()

    private var flow: ArchiveFlow { model.flow }

    // At 100 %; the panel zoom (`scale`) multiplies them.
    private static let rowHeight: CGFloat = 50
    private static let rowSpacing: CGFloat = 2
    private static let maxListHeight: CGFloat = 420
    /// The card's height around the list: its padding, the header, the footer and the gaps.
    private static let chromeHeight: CGFloat = 90

    private var rowHeight: CGFloat { Self.rowHeight * scale }
    private var rowSpacing: CGFloat { Self.rowSpacing * scale }
    private var rowPitch: CGFloat { rowHeight + rowSpacing }
    /// The list's cap: about the same number of rows at every zoom, but never past the screen.
    private var maxListHeight: CGFloat {
        max(min(Self.maxListHeight * scale, heightLimit - Self.chromeHeight * scale), rowPitch)
    }

    var body: some View {
        Group { // the card is drawn once by the panel (PanelRoot)
            VStack(alignment: .leading, spacing: 10 * scale) {
                HStack {
                    Text("Archive").panelFont(.headline)
                    Spacer()
                    Text("Kept for \(retention.displayName)")
                        .panelFont(.caption)
                        .foregroundStyle(.tertiary)
                }
                if model.items.isEmpty {
                    PanelEmptyState(
                        title: "Archive is empty",
                        systemImage: "archivebox",
                        description: "Completed todos show up here for \(retention.displayName)."
                    )
                    .frame(maxWidth: .infinity) // the column is leading-aligned; centre it in the card
                    .frame(height: 160 * scale)
                } else {
                    list
                }
                footer
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: rowSpacing) {
                    ForEach(model.items) { item in
                        row(item, isSelected: item.id == flow.selectedID)
                            .id(item.id)
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(CGFloat(model.items.count) * rowPitch, maxListHeight))
            .onChange(of: flow.selectedIndex) { _, _ in
                if let id = flow.selectedID { proxy.scrollTo(id) }
            }
            .onAppear { pointer.reset() }
        }
    }

    private func row(_ item: ArchiveModel.Item, isSelected: Bool) -> some View {
        HStack(spacing: 10 * scale) {
            Circle().fill(item.quadrant.color).frame(width: 8 * scale, height: 8 * scale)
            VStack(alignment: .leading, spacing: 2 * scale) {
                HStack(spacing: 6 * scale) {
                    Text(item.title).lineLimit(1)
                    AttachmentBadge(count: item.attachmentCount)
                }
                HStack(spacing: 4 * scale) {
                    Text(item.quadrant.displayName).foregroundStyle(item.quadrant.color)
                    Text("·")
                    Text(item.completedAt, format: .relative(presentation: .named))
                }
                .panelFont(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") { model.restore(item) }
                .help("Restore (\(ArchiveFlow.restoreKey))")
            Button(role: .destructive) { model.delete(item) } label: {
                Image(systemName: "trash")
            }
            .help("Delete now (⌫)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10 * scale)
        .frame(height: rowHeight)
        .background(
            // Neutral selection like the Browse list; the quadrant colour stays on the dot.
            Color.primary.opacity(isSelected ? (colorScheme == .dark ? 0.12 : 0.07) : 0),
            in: RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            // Only a real pointer move selects: rows sliding under a resting pointer (keyboard
            // moves, scrolling, the panel opening) must not steal the selection.
            if inside, pointer.moved() { model.select(item.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Restore") { model.restore(item) }
        .accessibilityAction(named: "Delete") { model.delete(item) }
    }

    private var footer: some View {
        HStack {
            Spacer()
            KeyHints(model.items.isEmpty
                     ? escapeHint
                     : "↑↓ select · \(ArchiveFlow.restoreKey) restore · ⌫ delete · \(escapeHint)")
        }
    }
}
