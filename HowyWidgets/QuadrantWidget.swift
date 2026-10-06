import HowyCore
import SwiftUI
import WidgetKit

struct QuadrantProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HowyEntry {
        SampleData.entry(family: context.family, quadrant: .urgentImportant)
    }

    func snapshot(for configuration: SelectQuadrantIntent, in context: Context) async -> HowyEntry {
        let quadrant = configuration.quadrant.quadrant
        if context.isPreview {
            return SampleData.entry(family: context.family, quadrant: quadrant)
        }
        return WidgetData.entry(from: await WidgetData.openTodos(), family: context.family, quadrant: quadrant)
    }

    func timeline(for configuration: SelectQuadrantIntent, in context: Context) async -> Timeline<HowyEntry> {
        await WidgetData.timeline(family: context.family, quadrant: configuration.quadrant.quadrant)
    }
}

/// One quadrant per widget instance; the quadrant is chosen in the widget's configuration.
struct QuadrantWidget: Widget {
    static let kind = "HowyQuadrant"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectQuadrantIntent.self, provider: QuadrantProvider()) { entry in
            QuadrantWidgetView(entry: entry)
        }
        .configurationDisplayName("Quadrant")
        .description("One Eisenhower quadrant. Choose which in the widget's settings.")
        .supportedFamilies([.systemSmall, .systemMedium])
        // The translucent tile *is* the widget: keep it instead of the system's glass platter.
        .containerBackgroundRemovable(false)
    }
}

struct QuadrantWidgetView: View {
    let entry: HowyEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let section = entry.content.quadrants.first {
            Group {
                if entry.readFailed {
                    WidgetErrorView()
                } else {
                    QuadrantSectionView(content: section)
                }
            }
                // In the small family the whole widget is one tap target and Links inside are
                // ignored, so a widgetURL there would hide the edit links. Medium keeps its Links.
                .widgetURL(family == .systemSmall && !entry.readFailed ? DeepLink.quickAdd(section.quadrant).url : nil)
                .containerBackground(for: .widget) {
                    QuadrantSurface(quadrant: section.quadrant)
                }
        }
    }
}

#Preview("Small", as: .systemSmall) {
    QuadrantWidget()
} timeline: {
    SampleData.entry(family: HowyWidgetFamily.small, quadrant: .urgentImportant)
    SampleData.entry(family: HowyWidgetFamily.small, quadrant: .notUrgentImportant)
    SampleData.entry(family: HowyWidgetFamily.small, quadrant: .notUrgentUnimportant)
}

#Preview("Medium", as: .systemMedium) {
    QuadrantWidget()
} timeline: {
    SampleData.entry(family: HowyWidgetFamily.medium, quadrant: .urgentImportant)
    SampleData.entry(family: HowyWidgetFamily.medium, quadrant: .urgentUnimportant)
}
