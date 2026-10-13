import HowyCore
import SwiftUI

/// The position picker (⌘⇧P) over a panel's card: the card dimmed, and on it a 3×3 grid of
/// mini screens, one per `PanelSlot`, each with a little card where the panel would go. The slot
/// the panel is in is outlined; the selection is filled with the accent colour. It only renders
/// `PositionPickerFlow`: the panel feeds the keys to the flow. A click on a tile moves the panel
/// there; a click on the dimmed card closes the picker.
struct PositionPickerOverlay: View {
    let flow: PositionPickerFlow
    /// A slot to move to, or `nil` to close the picker.
    let choose: (PanelSlot?) -> Void
    @Environment(\.panelScale) private var scale

    var body: some View {
        PanelCard<EmptyView>.shape
            .fill(.black.opacity(0.28))
            .contentShape(PanelCard<EmptyView>.shape)
            .onTapGesture { choose(nil) }
            .overlay { picker.fixedSize() } // may reach past a small card's edges
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }

    private var picker: some View {
        VStack(spacing: 10 * scale) {
            Text("Move panel")
                .panelFont(.headline)
            Grid(horizontalSpacing: 8 * scale, verticalSpacing: 8 * scale) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            if let slot = PanelSlot.at(row: row, column: column) {
                                tile(slot)
                            }
                        }
                    }
                }
            }
            KeyHints("←↑↓→ / hjkl · ↩ move · esc cancel")
        }
        .padding(14 * scale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    private func tile(_ slot: PanelSlot) -> some View {
        let selected = slot == flow.selected
        let current = slot == flow.current
        let shape = RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
        return shape
            .fill(selected ? Color.accentColor : Color.primary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 2 * scale, style: .continuous)
                    .fill(selected ? Color.white : Color.primary.opacity(0.35))
                    .frame(width: 34 * scale, height: 20 * scale)
                    .padding(8 * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slot.alignment)
            }
            .overlay {
                shape.strokeBorder(
                    current ? Color.accentColor : Color.primary.opacity(0.18),
                    lineWidth: current ? 2 : 1
                )
            }
            .frame(width: 120 * scale, height: 80 * scale)
            .contentShape(shape)
            .onTapGesture { choose(slot) }
            .accessibilityElement()
            .accessibilityLabel(slot.name)
            .accessibilityValue(current ? "Current position" : "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { choose(slot) }
    }
}

private extension PanelSlot {
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        case .bottomLeading: .bottomLeading
        case .bottom: .bottom
        case .bottomTrailing: .bottomTrailing
        }
    }

    var name: String {
        switch self {
        case .topLeading: "Top left"
        case .top: "Top centre"
        case .topTrailing: "Top right"
        case .leading: "Middle left"
        case .center: "Middle centre"
        case .trailing: "Middle right"
        case .bottomLeading: "Bottom left"
        case .bottom: "Bottom centre"
        case .bottomTrailing: "Bottom right"
        }
    }
}
