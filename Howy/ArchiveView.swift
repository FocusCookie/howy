import HowyCore
import SwiftUI

/// Archived todos, newest-completed first, with Restore and Delete per row.
struct ArchiveView: View {
    let model: ArchiveModel

    private static let rowHeight: CGFloat = 50
    private static let maxListHeight: CGFloat = 420

    var body: some View {
        Group { // the card is drawn once by the panel (PanelRoot)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Archive").font(.headline)
                    Spacer()
                    Text("Kept for 7 days · esc to close")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if model.items.isEmpty {
                    ContentUnavailableView(
                        "Archive is empty",
                        systemImage: "archivebox",
                        description: Text("Completed todos show up here for 7 days.")
                    )
                    .frame(height: 160)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.items) { item in
                                row(item)
                                if item.id != model.items.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(model.items.count) * Self.rowHeight, Self.maxListHeight))
                }
            }
        }
    }

    private func row(_ item: ArchiveModel.Item) -> some View {
        HStack(spacing: 10) {
            Circle().fill(item.quadrant.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
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
            Button(role: .destructive) { model.delete(item) } label: {
                Image(systemName: "trash")
            }
            .help("Delete now")
        }
        .buttonStyle(.borderless)
        .frame(height: Self.rowHeight)
    }
}
