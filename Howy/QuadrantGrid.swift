import HowyCore
import SwiftUI

/// Quick entry's 2×2 quadrant picker. The highlighted tile glows in its quadrant colour; on panel
/// open the tiles slide in from slightly outside their corners. (Browse's grid with open counts,
/// which grows into the Overview, is `OverviewView`. Its tiles are notched around the middle
/// button; quick entry has no such button, so these are plain.)
struct QuadrantGrid: View {
    let highlighted: Quadrant?
    let onChoose: (Quadrant) -> Void

    @Environment(\.panelState) private var panelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelScale) private var scale
    @State private var hovered: Quadrant?

    /// How far tiles start outside their grid position when the panel opens.
    private static let entranceOffset: CGFloat = 4

    var body: some View {
        Grid(horizontalSpacing: TileNotch.spacing * scale, verticalSpacing: TileNotch.spacing * scale) {
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
        let shape = RoundedRectangle(cornerRadius: TileNotch.cornerRadius * scale, style: .continuous)
        return VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(alignment: .top) {
                Text(quadrant.displayName)
                    .panelFont(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                KeyCap(text: "\(quadrant.shortcutNumber)")
            }
        }
        .padding(12 * scale)
        .frame(maxWidth: .infinity, minHeight: 72 * scale, alignment: .topLeading)
        .modifier(QuadrantTileBackground(
            quadrant: quadrant, isHighlighted: isHighlighted, shape: shape, isHovered: hovered == quadrant
        ))
        .onHover { inside in
            if inside { hovered = quadrant } else if hovered == quadrant { hovered = nil }
        }
        .scaleEffect(isHighlighted && !reduceMotion ? 1.015 : 1)
        .animation(.snappy(duration: 0.22), value: isHighlighted)
        .offset(entranceOffset(for: quadrant))
        .contentShape(shape)
        .onTapGesture { onChoose(quadrant) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    /// Diagonally outward toward the tile's own corner while the panel is still hidden.
    private func entranceOffset(for quadrant: Quadrant) -> CGSize {
        guard panelState == .hidden, !reduceMotion else { return .zero }
        let position = quadrant.gridPosition
        let d = Self.entranceOffset * scale
        return CGSize(width: position.column == 0 ? -d : d, height: position.row == 0 ? -d : d)
    }
}

/// A quadrant tile's surface, shared by the big picker, the Overview's tiles and the move picker:
/// neutral grey at rest (Raycast-like). Highlighted, `.glow` (the small grid, the move picker)
/// tints, outlines and softly glows the tile in the quadrant colour; `.outline` (the Overview's
/// focused tile) keeps the resting fill and draws a thick translucent border in the quadrant
/// colour. With Differentiate Without Color or Increase Contrast the highlighted tile gets an
/// opaque outline and the others a visible neutral one.
struct QuadrantTileBackground<S: InsettableShape>: ViewModifier {
    enum Style { case glow, outline }

    let quadrant: Quadrant
    let isHighlighted: Bool
    let shape: S
    var style: Style = .glow
    /// The glow behind a highlighted `.glow` tile is shown. The Overview turns it off while the
    /// tiles change size: a layer inserted mid-animation takes its final frame at once, so it
    /// would show at the small tile's size inside the still big one.
    var showsGlow = true
    /// Under the pointer: a touch brighter, like the middle button, so a clickable card shows it.
    var isHovered = false
    var glowRadius: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast

    private var isDark: Bool { colorScheme == .dark }
    private var isEmphasised: Bool { differentiateWithoutColor || contrast == .increased }

    /// The fill of a tile at rest (also the middle button's).
    static func restingFill(isDark: Bool) -> Color {
        isDark ? .white.opacity(0.06) : .black.opacity(0.04)
    }

    private var fill: Color {
        if isHighlighted, style == .glow { return quadrant.color.opacity(isDark ? 0.24 : 0.12) }
        return Self.restingFill(isDark: isDark)
    }

    private var stroke: Color {
        if isHighlighted {
            switch style {
            case .glow: return quadrant.color.opacity(isEmphasised ? 1 : 0.75)
            case .outline: return quadrant.color.opacity(isEmphasised ? 1 : 0.55)
            }
        }
        return isEmphasised ? Color.primary.opacity(0.3) : .clear
    }

    private var lineWidth: CGFloat {
        if isHighlighted, style == .outline { return 4 }
        if isHighlighted, isEmphasised { return 2.5 }
        return isEmphasised ? 1 : 1.5
    }

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(Color.primary.opacity(isHovered ? (isDark ? 0.08 : 0.05) : 0))
                    .animation(.snappy(duration: 0.15), value: isHovered)
            }
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(stroke, lineWidth: lineWidth))
            .background {
                // Soft glow: a blurred tile in the quadrant colour behind the highlighted one. Kept
                // faint in light mode, where a strong coloured blur on a pale card looks muddy. Only
                // there while highlighted (it fades in and out as a transition), so resting tiles
                // carry no blur layer at all. Not for `.outline`: blurring a tile-sized layer every
                // frame of the morph and of a focus change is expensive.
                if style == .glow, isHighlighted, showsGlow {
                    shape
                        .fill(quadrant.color)
                        .blur(radius: isDark ? glowRadius : glowRadius * 0.8)
                        .opacity(isDark ? 0.45 : 0.22)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }
}

/// The corner of a tile that touches the middle of the 2×2 grid, cut out (`NotchedTileShape`) so
/// the four tiles leave a round hole for the middle button (`OverviewToggleButton`), with the
/// same gap around it as between the tiles. Shared by the small grid's cards and the Overview's
/// tiles, which use the same spacing, so the cut-outs line up while they morph.
struct TileNotch {
    /// The gap between tiles, in both the small grid and the Overview, at 100 % (`scale` multiplies it).
    nonisolated static let spacing: CGFloat = 10
    /// The tiles' corner radius at 100 %.
    nonisolated static let cornerRadius: CGFloat = 12

    let corner: NotchedTileShape.Corner
    /// The panel zoom's factor: the gap, the corners and the middle button all grow with it.
    let scale: CGFloat

    /// The gap between tiles at this zoom.
    var spacing: CGFloat { Self.spacing * scale }
    var cornerRadius: CGFloat { Self.cornerRadius * scale }
    /// The cut-out's radius around the middle: the button's radius plus the gap around it.
    var radius: CGFloat { OverviewToggleButton.size * scale / 2 + spacing }
    /// How far the cut-out reaches into the tile along each edge from its inner corner (the tile
    /// sits half a gap away from the middle in both directions).
    var size: CGFloat { (radius * radius - spacing * spacing / 4).squareRoot() - spacing / 2 }

    init(_ quadrant: Quadrant, scale: CGFloat = 1) {
        self.scale = scale
        let position = quadrant.gridPosition
        corner = switch (position.row, position.column) {
        case (0, 0): .bottomTrailing
        case (0, _): .bottomLeading
        case (_, 0): .topTrailing
        default: .topLeading
        }
    }

    var shape: NotchedTileShape {
        NotchedTileShape(
            cornerRadius: cornerRadius,
            notch: corner,
            notchRadius: radius,
            notchCenterOffset: spacing / 2
        )
    }

    /// The inner corner as a unit point (to scale a tile without narrowing the gutter).
    var anchor: UnitPoint {
        switch corner {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    /// Keeps a tile's header (top row) clear of a cut-out at the top: extra room on that side,
    /// beyond the tile's 12 pt padding.
    var headerClearance: HeaderClearance { HeaderClearance(corner: corner, extra: size - cornerRadius + 4 * scale) }

    /// Keeps a tile's bottom content (the Overview's list) clear of a cut-out at the bottom.
    var bottomClearance: CGFloat {
        corner == .bottomLeading || corner == .bottomTrailing ? max(size - cornerRadius, 0) : 0
    }

    struct HeaderClearance: ViewModifier {
        let corner: NotchedTileShape.Corner
        let extra: CGFloat

        func body(content: Content) -> some View {
            switch corner {
            case .topLeading: content.padding(.leading, extra)
            case .topTrailing: content.padding(.trailing, extra)
            case .bottomLeading, .bottomTrailing: content
            }
        }
    }
}

/// A rounded rectangle with one corner cut out by a circle of `notchRadius`, centred
/// `notchCenterOffset` outside that corner on both axes (the middle of the grid). Insettable, so
/// `strokeBorder` outlines follow the cut-out: the circle keeps its centre and grows by the inset.
struct NotchedTileShape: InsettableShape {
    enum Corner: Hashable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    var cornerRadius: CGFloat
    var notch: Corner?
    var notchRadius: CGFloat = 0
    var notchCenterOffset: CGFloat = 0
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> NotchedTileShape {
        var shape = self
        shape.inset += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let maxRadius = min(r.width, r.height) / 2
        let outer = min(max(cornerRadius - inset, 0), maxRadius)
        // The circle's centre stays put while the edges move in, so measured from the inset
        // corner it sits `offset` away on both axes.
        let offset = notchCenterOffset + inset
        let radius = notchRadius + inset
        // Where the circle crosses the two edges, measured from the corner along each edge.
        let reach = radius > offset ? (radius * radius - offset * offset).squareRoot() - offset : 0
        let cut = min(reach, min(r.width, r.height) - outer)

        // Corners clockwise (y down), each with the edge direction arriving at it and leaving it.
        let corners: [(Corner, CGPoint, CGVector, CGVector)] = [
            (.topLeading, CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
            (.topTrailing, CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (.bottomTrailing, CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
            (.bottomLeading, CGPoint(x: r.minX, y: r.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        ]
        enum Vertex { case corner(CGPoint, CGFloat), cutOut(from: CGPoint, to: CGPoint, center: CGPoint) }
        var vertices: [Vertex] = []
        for (corner, point, arriving, leaving) in corners {
            if corner == notch, cut > 0 {
                let center = CGPoint(
                    x: point.x + (arriving.dx - leaving.dx) * offset,
                    y: point.y + (arriving.dy - leaving.dy) * offset
                )
                let from = CGPoint(x: point.x - arriving.dx * cut, y: point.y - arriving.dy * cut)
                let to = CGPoint(x: point.x + leaving.dx * cut, y: point.y + leaving.dy * cut)
                vertices.append(.cutOut(from: from, to: to, center: center))
            } else {
                vertices.append(.corner(point, outer))
            }
        }

        func start(of vertex: Vertex) -> CGPoint {
            switch vertex {
            case .corner(let point, _): point
            case .cutOut(let from, _, _): from
            }
        }
        func end(of vertex: Vertex) -> CGPoint {
            switch vertex {
            case .corner(let point, _): point
            case .cutOut(_, let to, _): to
            }
        }

        var path = Path()
        let last = end(of: vertices[vertices.count - 1])
        let first = start(of: vertices[0])
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for index in vertices.indices {
            let next = start(of: vertices[(index + 1) % vertices.count])
            switch vertices[index] {
            case .corner(let point, let radius):
                path.addArc(tangent1End: point, tangent2End: next, radius: radius)
            case .cutOut(let from, let to, let center):
                path.addLine(to: from)
                let startAngle = atan2(from.y - center.y, from.x - center.x)
                let endAngle = atan2(to.y - center.y, to.x - center.x)
                var delta = endAngle - startAngle
                if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
                path.addArc(
                    center: center, radius: radius,
                    startAngle: .radians(startAngle), endAngle: .radians(startAngle + delta),
                    clockwise: delta < 0
                )
            }
        }
        path.closeSubpath()
        return path
    }
}

/// Browse's compact "Move “title” to…" picker, shown next to a row (`m` or the row's move
/// button): the four quadrants as small tiles, the todo's own one dimmed and marked "current",
/// the highlighted one glowing like the big picker's. A click on another tile moves the todo.
struct MoveQuadrantPicker: View {
    let picker: BrowseFlow.MovePicker
    let onChoose: (Quadrant) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelScale) private var scale

    /// At 100 %; the panel zoom multiplies it.
    static let width: CGFloat = 270

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
        VStack(alignment: .leading, spacing: 6 * scale) {
            Text("Move “\(picker.todo.title)” to…")
                .panelFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2 * scale)
            Grid(horizontalSpacing: 6 * scale, verticalSpacing: 6 * scale) {
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
        .padding(8 * scale)
        .frame(width: Self.width * scale)
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
        let shape = RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
        return VStack(alignment: .leading, spacing: 3 * scale) {
            HStack(spacing: 6 * scale) {
                Circle().fill(quadrant.color).frame(width: 8 * scale, height: 8 * scale)
                KeyCap(text: "\(quadrant.shortcutNumber)", minSize: 16)
                Spacer(minLength: 0)
                if isCurrent {
                    Text("current")
                        .panelFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(quadrant.displayName)
                .panelFont(.caption2, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(7 * scale)
        .frame(maxWidth: .infinity, minHeight: 48 * scale, alignment: .topLeading)
        .modifier(QuadrantTileBackground(quadrant: quadrant, isHighlighted: isHighlighted, shape: shape, glowRadius: 6 * scale))
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
    @Environment(\.panelScale) private var scale

    var body: some View {
        HStack(spacing: 6 * scale) {
            Circle().fill(quadrant.color).frame(width: 8 * scale, height: 8 * scale)
            Text(quadrant.displayName)
        }
        .panelFont(.caption, weight: .medium)
        .padding(.horizontal, 8 * scale)
        .padding(.vertical, 3 * scale)
        .background(quadrant.color.opacity(0.15), in: Capsule())
    }
}
