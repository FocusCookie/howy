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

    private var flow: ArchiveFlow { model.flow }

    private static let rowHeight: CGFloat = 50
    private static let rowSpacing: CGFloat = 2
    private static var rowPitch: CGFloat { rowHeight + rowSpacing }
    private static let maxListHeight: CGFloat = 420

    var body: some View {
        Group { // the card is drawn once by the panel (PanelRoot)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Archive").font(.headline)
                    Spacer()
                    Text("Kept for 7 days")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if model.items.isEmpty {
                    ContentUnavailableView(
                        "Archive is empty",
                        systemImage: "archivebox",
                        description: Text("Completed todos show up here for 7 days.")
                    )
                    .frame(maxWidth: .infinity) // the column is leading-aligned; centre it in the card
                    .frame(height: 160)
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
                LazyVStack(spacing: Self.rowSpacing) {
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
            .frame(height: min(CGFloat(model.items.count) * Self.rowPitch, Self.maxListHeight))
            .onChange(of: flow.selectedIndex) { _, _ in
                if let id = flow.selectedID { proxy.scrollTo(id) }
            }
            .onAppear { pointer.reset() }
        }
    }

    private func row(_ item: ArchiveModel.Item, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(item.quadrant.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1)
                    AttachmentBadge(count: item.attachmentCount)
                }
                HStack(spacing: 4) {
                    Text(item.quadrant.displayName).foregroundStyle(item.quadrant.color)
                    Text("·")
                    Text(item.completedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
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
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(
            // Neutral selection like the Browse list; the quadrant colour stays on the dot.
            Color.primary.opacity(isSelected ? (colorScheme == .dark ? 0.12 : 0.07) : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
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
