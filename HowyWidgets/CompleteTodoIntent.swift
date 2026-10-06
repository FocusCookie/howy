import AppIntents
import Foundation
import HowyCore
import OSLog

/// The widget checkbox: marks a todo done (it moves to the archive) and reloads all timelines.
struct CompleteTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Todo"
    static let description = IntentDescription("Marks a Howy todo as done.")
    static let isDiscoverable = false

    @Parameter(title: "Todo ID")
    var todoID: String

    init() {}

    init(id: UUID) {
        self.todoID = id.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: todoID) else { return .result() }
        do {
            // The shared store's default `didWrite` reloads every widget timeline.
            try TodoStore.shared().complete(id: id)
        } catch TodoStoreError.notFound {
            // Already gone (e.g. deleted in the app); just refresh what the widget shows.
            TodoStore.reloadWidgetTimelines()
        } catch {
            Logger.widgets.error("Completing todo \(id, privacy: .public) failed: \(error, privacy: .public)")
            throw error
        }
        return .result()
    }
}
