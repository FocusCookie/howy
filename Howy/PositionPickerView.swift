import HowyCore
import SwiftUI

/// The position picker (⌘⇧P) over a panel's card: the card dimmed, and on it a 3×3 grid of
/// mini screens, one per `PanelSlot`, each with a little card where the panel would go. The slot
/// the panel is in is outlined; the selection is filled with the accent colour. It only renders
/// `PositionPickerFlow`: the panel feeds the keys to the flow. A click on a tile moves the panel
/// there; a click on the dimmed card closes the picker.
struct PositionPickerOverlay: View {
    let flow: PositionPickerFlow
    /// The card's frame on screen, and where the picker has to stay (screen coordinates, y up).
    let card: CGRect
    let bounds: CGRect
    /// A slot to move to, or `nil` to close the picker.
    let choose: (PanelSlot?) -> Void
    @Environment(\.panelScale) private var scale
    @State private var pickerSize = CGSize.zero

    var body: some View {
        PanelCard<EmptyView>.shape
            .fill(.black.opacity(0.28))
            .contentShape(PanelCard<EmptyView>.shape)
            .onTapGesture { choose(nil) }
            .overlay { // may reach past a small card's edges, but stays inside the window and the screen
                let shift = PanelPlacement.pickerOffset(pickerSize: pickerSize, cardFrame: card, bounds: bounds)
                picker.fixedSize()
                    .onGeometryChange(for: CGSize.self, of: \.size) { pickerSize = $0 }
                    .offset(x: shift.width, y: -shift.height) // screen y runs up, the view's down
                    .opacity(pickerSize == .zero ? 0 : 1) // until it is measured
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }

    private var picker: some View {
        VStack(spacing: 10 * scale) {
            Text("Move panel")
                .panelFont(.headline)
                .foregroundStyle(Color.primary)
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
            KeyHints("←↑↓→ / hjkl · ↩ move · esc cancel", prominent: true)
        }
        .padding(14 * scale)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    private let tileHeight: CGFloat = 80

    private func tile(_ slot: PanelSlot) -> some View {
        let selected = slot == flow.selected
        let current = slot == flow.current
        let shape = RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
        return shape
            .fill(selected ? Color.accentColor : Color.primary.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 2 * scale, style: .continuous)
                    .fill(selected ? Color.white : Color.primary.opacity(0.5))
                    .frame(width: 34 * scale, height: 20 * scale)
                    .padding(EdgeInsets(top: slot.topPadding(tileHeight: tileHeight) * scale, leading: 8 * scale, bottom: 8 * scale, trailing: 8 * scale))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slot.alignment)
            }
            .overlay {
                shape.strokeBorder(
                    current ? Color.accentColor : Color.primary.opacity(0.25),
                    lineWidth: current ? 2 : 1
                )
            }
            .frame(width: 120 * scale, height: tileHeight * scale)
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
    /// Space above the little card: the middle row's cards sit on the 22 % line (where those slots
    /// put the real card), not in the middle of their tile.
    func topPadding(tileHeight: CGFloat) -> CGFloat {
        row == 1 ? tileHeight * OverviewSize.compactPanelTopFraction : 8
    }

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
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
