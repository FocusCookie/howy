import HowyCore
import SwiftUI
import WidgetKit

struct MatrixProvider: TimelineProvider {
    func placeholder(in context: Context) -> HowyEntry {
        SampleData.entry(family: context.family)
    }

    func getSnapshot(in context: Context, completion: @escaping (HowyEntry) -> Void) {
        if context.isPreview {
            completion(SampleData.entry(family: context.family))
            return
        }
        let family = context.family
        let completion = UncheckedSendable(completion)
        Task {
            completion.value(WidgetData.entry(from: await WidgetData.openTodos(), family: family, quadrant: nil))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HowyEntry>) -> Void) {
        let family = context.family
        let completion = UncheckedSendable(completion)
        Task {
            completion.value(await WidgetData.timeline(family: family, quadrant: nil))
        }
    }
}

/// WidgetKit's completion handlers may be called from any thread; this lets them cross into a `Task`.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// All four quadrants in a 2×2 grid of separate floating tiles, no header. Archive icon in the
/// bottom-right corner.
struct MatrixWidget: Widget {
    static let kind = "HowyMatrix"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: MatrixProvider()) { entry in
            MatrixWidgetView(entry: entry)
        }
        .configurationDisplayName("Matrix")
        .description("All four Eisenhower quadrants at a glance.")
        .supportedFamilies([.systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
        // Our (clear) background is the look, not decoration: ask the system to keep it instead of
        // swapping in its own glass platter in tinted/clear modes. See `MatrixWidgetView`.
        .containerBackgroundRemovable(false)
    }
}

struct MatrixWidgetView: View {
    let entry: HowyEntry

    /// Gap between tiles; the wallpaper shows through it.
    private let spacing: CGFloat = 8
    /// Inset of the tiles from the widget's edge; their outer corners are concentric with the mask.
    private let outerPadding: CGFloat = 12

    var body: some View {
        Group {
            if entry.readFailed {
                WidgetErrorView()
                    .background { QuadrantSurface(quadrant: .urgentImportant) }
            } else {
                grid
            }
        }
        .padding(outerPadding)
        .overlay(alignment: .bottomTrailing) {
            Link(destination: DeepLink.archive.url) {
                Image(systemName: "archivebox")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .padding(outerPadding + 3) // inside the bottom-right tile
            .accessibilityLabel("Archive")
        }
        // No outer panel: only the four tiles are drawn. With `containerBackgroundRemovable(false)` this
        // is as transparent as WidgetKit allows; macOS may still add its own platter in some widget styles.
        .containerBackground(for: .widget) { Color.clear }
    }

    private var grid: some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.quadrant) { section in
                        QuadrantSectionView(content: section)
                            .quadrantTile(section.quadrant)
                    }
                }
            }
        }
    }

    /// Quadrants arranged by their grid position (reading order: 1 2 / 3 4).
    private var rows: [[QuadrantContent]] {
        let sections = entry.content.quadrants
        return [0, 1].map { row in
            sections.filter { $0.quadrant.gridPosition.row == row }
                .sorted { $0.quadrant.gridPosition.column < $1.quadrant.gridPosition.column }
        }
    }
}

#Preview("Large", as: .systemLarge) {
    MatrixWidget()
} timeline: {
    SampleData.entry(family: HowyWidgetFamily.large)
    HowyEntry(date: .now, content: WidgetContentBuilder.build(openTodos: [:], family: .large, selectedQuadrant: nil))
}

#Preview("Extra Large", as: .systemExtraLarge) {
    MatrixWidget()
} timeline: {
    SampleData.entry(family: HowyWidgetFamily.extraLarge)
}
