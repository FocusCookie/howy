import SwiftUI

/// A short message panel, e.g. when the shared store can't be opened.
struct ErrorView: View {
    let title: String
    let message: String
    @Environment(\.panelScale) private var scale

    var body: some View {
        Group { // the card is drawn once by the panel (PanelRoot)
            VStack(alignment: .leading, spacing: 8 * scale) {
                Label(title, systemImage: "exclamationmark.triangle")
                    .panelFont(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                Text("esc to close")
                    .panelFont(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
