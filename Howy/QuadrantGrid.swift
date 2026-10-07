import HowyCore
import SwiftUI

/// The 2×2 quadrant picker shared by quick entry and browse. The highlighted tile glows in its
/// quadrant colour; on panel open the tiles slide in from slightly outside their corners.
/// With `count`, each tile shows its open-todo count prominently (browse).
struct QuadrantGrid: View {
    /// `nil` when something outside the grid has the highlight (Browse's Archive button).
    let highlighted: Quadrant?
    var count: ((Quadrant) -> Int)?
    let onChoose: (Quadrant) -> Void

    @Environment(\.panelState) private var panelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    /// Neutral grey for resting tiles (Raycast-like), a quadrant tint for the highlighted one.
    private func tileFill(_ quadrant: Quadrant, isHighlighted: Bool) -> Color {
        if isHighlighted { return quadrant.color.opacity(isDark ? 0.24 : 0.12) }
        return isDark ? .white.opacity(0.06) : .black.opacity(0.04)
    }

    /// How far tiles start outside their grid position when the panel opens.
    private static let entranceOffset: CGFloat = 4

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { column in
                        if let quadrant = Quadrant(gridPosition: GridPosition(row: row, column: column)) {
                            tile(quadrant)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ quadrant: Quadrant) -> some View {
        let isHighlighted = highlighted == quadrant
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(quadrant.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(quadrant.shortcutNumber)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(quadrant.color)
                    .frame(width: 20, height: 20)
                    .background(quadrant.color.opacity(0.15), in: Circle())
            }
            if let count {
                let n = count(quadrant)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(n)")
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(n == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(quadrant.color))
                        .contentTransition(.numericText())
                    Text("open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: count == nil ? 72 : 96, alignment: .topLeading)
        .background(tileFill(quadrant, isHighlighted: isHighlighted), in: shape)
        .overlay(shape.strokeBorder(quadrant.color.opacity(isHighlighted ? 0.75 : 0), lineWidth: 1.5))
        .background {
            // Soft glow: a blurred tile in the quadrant colour behind the highlighted one. Kept
            // faint in light mode, where a strong coloured blur on a pale card looks muddy.
            shape
                .fill(quadrant.color)
                .blur(radius: isDark ? 10 : 8)
                .opacity(isHighlighted ? (isDark ? 0.45 : 0.22) : 0)
                .allowsHitTesting(false)
        }
        .scaleEffect(isHighlighted && !reduceMotion ? 1.015 : 1)
        .animation(.snappy(duration: 0.22), value: isHighlighted)
        .offset(entranceOffset(for: quadrant))
        .contentShape(Rectangle())
        .onTapGesture { onChoose(quadrant) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    /// Diagonally outward toward the tile's own corner while the panel is still hidden.
    private func entranceOffset(for quadrant: Quadrant) -> CGSize {
        guard panelState == .hidden, !reduceMotion else { return .zero }
        let position = quadrant.gridPosition
        let d = Self.entranceOffset
        return CGSize(width: position.column == 0 ? -d : d, height: position.row == 0 ? -d : d)
    }
}

struct QuadrantChip: View {
    let quadrant: Quadrant

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(quadrant.color).frame(width: 8, height: 8)
            Text(quadrant.displayName)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(quadrant.color.opacity(0.15), in: Capsule())
    }
}
