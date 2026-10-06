import AppIntents
import HowyCore

/// The App Intents face of `Quadrant`, used by the Quadrant widget's configuration.
enum QuadrantOption: Int, AppEnum {
    case urgentImportant = 1
    case notUrgentImportant = 2
    case urgentUnimportant = 3
    case notUrgentUnimportant = 4

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quadrant"

    static let caseDisplayRepresentations: [QuadrantOption: DisplayRepresentation] = [
        .urgentImportant: "Urgent & Important",
        .notUrgentImportant: "Not Urgent & Important",
        .urgentUnimportant: "Urgent & Unimportant",
        .notUrgentUnimportant: "Not Urgent & Unimportant",
    ]

    var quadrant: Quadrant { Quadrant(rawValue: rawValue) ?? .urgentImportant }

    init(_ quadrant: Quadrant) {
        self = QuadrantOption(rawValue: quadrant.rawValue) ?? .urgentImportant
    }
}

/// Configuration for one Quadrant widget instance: which quadrant it shows.
struct SelectQuadrantIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Quadrant"
    static let description = IntentDescription("Pick the quadrant this widget shows.")

    @Parameter(title: "Quadrant", default: .urgentImportant)
    var quadrant: QuadrantOption

    init() {}

    init(quadrant: QuadrantOption) {
        self.quadrant = quadrant
    }
}
