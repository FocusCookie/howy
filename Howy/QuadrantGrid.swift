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
                KeyCap(text: "\(quadrant.shortcutNumber)")
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
        .modifier(QuadrantTileBackground(quadrant: quadrant, isHighlighted: isHighlighted, shape: shape))
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

/// A quadrant tile's surface, shared by the big picker and the move picker: neutral grey at rest
/// (Raycast-like); tinted, outlined and softly glowing in the quadrant colour when highlighted.
struct QuadrantTileBackground: ViewModifier {
    let quadrant: Quadrant
    let isHighlighted: Bool
    let shape: RoundedRectangle
    var glowRadius: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    private var fill: Color {
        if isHighlighted { return quadrant.color.opacity(isDark ? 0.24 : 0.12) }
        return isDark ? .white.opacity(0.06) : .black.opacity(0.04)
    }

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(quadrant.color.opacity(isHighlighted ? 0.75 : 0), lineWidth: 1.5))
            .background {
                // Soft glow: a blurred tile in the quadrant colour behind the highlighted one. Kept
                // faint in light mode, where a strong coloured blur on a pale card looks muddy.
                shape
                    .fill(quadrant.color)
                    .blur(radius: isDark ? glowRadius : glowRadius * 0.8)
                    .opacity(isHighlighted ? (isDark ? 0.45 : 0.22) : 0)
                    .allowsHitTesting(false)
            }
    }
}

/// Browse's compact "Move “title” to…" picker, shown next to a row (`m` or the row's move
/// button): the four quadrants as small tiles, the todo's own one dimmed and marked "current",
/// the highlighted one glowing like the big picker's. A click on another tile moves the todo.
struct MoveQuadrantPicker: View {
    let picker: BrowseFlow.MovePicker
    let onChoose: (Quadrant) -> Void

    @Environment(\.colorScheme) private var colorScheme

    static let width: CGFloat = 270

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text("Move “\(picker.todo.title)” to…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
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
        .padding(8)
        .frame(width: Self.width)
        .background {
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(colorScheme == .dark ? Color(white: 0.16).opacity(0.6) : .white.opacity(0.6))
            }
        }
        .overlay(shape.strokeBorder(colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.2), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Move “\(picker.todo.title)” to")
    }

    private func tile(_ quadrant: Quadrant) -> some View {
        let isCurrent = quadrant == picker.todo.quadrant
        let isHighlighted = quadrant == picker.highlighted && !isCurrent
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(quadrant.color).frame(width: 8, height: 8)
                KeyCap(text: "\(quadrant.shortcutNumber)", minSize: 16)
                Spacer(minLength: 0)
                if isCurrent {
                    Text("current")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(quadrant.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .modifier(QuadrantTileBackground(quadrant: quadrant, isHighlighted: isHighlighted, shape: shape, glowRadius: 6))
        // The current quadrant is the one the highlight can rest on without a move; a neutral ring shows it.
        .overlay(shape.strokeBorder(Color.primary.opacity(isCurrent && quadrant == picker.highlighted ? 0.35 : 0), lineWidth: 1.5))
        .opacity(isCurrent ? 0.45 : 1)
        .animation(.snappy(duration: 0.18), value: isHighlighted)
        .contentShape(Rectangle())
        .onTapGesture { if !isCurrent { onChoose(quadrant) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCurrent ? "\(quadrant.displayName), current" : quadrant.displayName)
        .accessibilityAddTraits(isCurrent ? [] : (isHighlighted ? [.isButton, .isSelected] : .isButton))
        .accessibilityAction { if !isCurrent { onChoose(quadrant) } }
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
