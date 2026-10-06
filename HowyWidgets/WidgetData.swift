import Foundation
import HowyCore
import OSLog
import WidgetKit

extension Logger {
    static let widgets = Logger(subsystem: "io.lichtwart.howy.widgets", category: "widgets")
}

/// One timeline entry: everything a Howy widget renders, already laid out by `WidgetContentBuilder`.
struct HowyEntry: TimelineEntry {
    let date: Date
    let content: WidgetContent
    /// The shared store couldn't be read: show an error instead of an (misleading) empty matrix.
    var readFailed = false
}

extension WidgetFamily {
    var howyFamily: HowyWidgetFamily {
        switch self {
        case .systemSmall: .small
        case .systemMedium: .medium
        case .systemLarge: .large
        case .systemExtraLarge: .extraLarge
        default: .medium
        }
    }
}

enum WidgetData {
    /// How long a timeline stays valid. The app reloads timelines after every write; this is only a safety net.
    static let refreshInterval: TimeInterval = 60 * 60

    /// Open todos from the shared App Group store, or `nil` when it can't be read.
    static func openTodos() async -> [Quadrant: [TodoSnapshot]]? {
        await MainActor.run {
            do {
                return try TodoStore.shared(didWrite: nil).openSnapshots()
            } catch {
                Logger.widgets.error("Reading the shared store failed: \(error, privacy: .public)")
                return nil
            }
        }
    }

    /// `todos == nil` means the read failed; the entry then carries an error state.
    static func entry(
        from todos: [Quadrant: [TodoSnapshot]]?,
        family: WidgetFamily,
        quadrant: Quadrant?,
        date: Date = .now
    ) -> HowyEntry {
        HowyEntry(
            date: date,
            content: WidgetContentBuilder.build(openTodos: todos ?? [:], family: family.howyFamily, selectedQuadrant: quadrant),
            readFailed: todos == nil
        )
    }

    static func timeline(family: WidgetFamily, quadrant: Quadrant?) async -> Timeline<HowyEntry> {
        let now = Date.now
        let entry = entry(from: await openTodos(), family: family, quadrant: quadrant, date: now)
        // Retry sooner after a failure.
        let next = entry.readFailed ? 5 * 60 : refreshInterval
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(next)))
    }
}

/// Sample todos for placeholders, the widget gallery and previews.
enum SampleData {
    static let todos: [Quadrant: [TodoSnapshot]] = [
        .urgentImportant: make(.urgentImportant, [
            "Send invoice to client", "Fix login bug in production", "Call the landlord",
            "Renew passport", "Prepare board slides", "Pay electricity bill", "Book dentist",
        ]),
        .notUrgentImportant: make(.notUrgentImportant, [
            "Plan Q4 roadmap", "Read “Deep Work”", "Weekly review",
        ]),
        .urgentUnimportant: make(.urgentUnimportant, [
            "Reply to Slack thread about the offsite", "Order printer toner",
        ]),
        .notUrgentUnimportant: [],
    ]

    static func entry(family: WidgetFamily, quadrant: Quadrant? = nil) -> HowyEntry {
        WidgetData.entry(from: todos, family: family, quadrant: quadrant)
    }

    static func entry(family: HowyWidgetFamily, quadrant: Quadrant? = nil) -> HowyEntry {
        HowyEntry(
            date: .now,
            content: WidgetContentBuilder.build(openTodos: todos, family: family, selectedQuadrant: quadrant)
        )
    }

    private static func make(_ quadrant: Quadrant, _ titles: [String]) -> [TodoSnapshot] {
        titles.map { TodoSnapshot(id: UUID(), title: $0, quadrant: quadrant) }
    }
}
