import HowyCore
import SwiftUI

/// Browse's four quadrant tiles, in both of their layouts: the small 2×2 grid (each tile with its
/// big open count; ←↑↓→ highlight, ↩ or a click opens the quadrant's list) and the Overview
/// (the tiles fill the grown card, each listing its open todos, one focused). A thin view over
/// `BrowseFlow` and `BrowseModel.morph`; keys arrive through `BrowseModel.handle`.
///
/// Both layouts are this one view, so the grow and the shrink are a plain layout animation: the
/// four tiles are laid out by the same stacks inside the card whose frame animates, and move in
/// step. `OverviewMorph` keeps the content out of the way meanwhile: the counts fade out before
/// the tiles grow and the rows fade in only once they have their size (and the reverse), so no
/// list is laid out in a changing frame.
///
/// In the Overview the focused tile shows the todo editor instead of its rows while one is open.
/// Rows are dragged by their grip, within a tile or to another one (onto the header: to the
/// top), with an insertion line where they will land.
struct OverviewView: View {
    let model: BrowseModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelEffects) private var panelEffects
    @Environment(\.panelState) private var panelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelScale) private var scale

    @State private var drag: TileDrag?
    /// The small grid's card under the pointer.
    @State private var hoveredTile: Quadrant?
    @State private var pointer = PointerTracker()
    /// Tiles, headers and rows in the Overview's space (`space`), for drag targets and the move picker.
    @State private var tileFrames: [Quadrant: CGRect] = [:]
    @State private var headerFrames: [Quadrant: CGRect] = [:]
    @State private var listFrames: [Quadrant: CGRect] = [:]
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// Where each row is in window coordinates (where the done emoji rises).
    @State private var rowWindowFrames: [UUID: CGRect] = [:]
    @State private var movePickerSize = CGSize(width: MoveQuadrantPicker.width, height: 150)

    private var flow: BrowseFlow { model.flow }
    private var morph: OverviewMorph { model.morph }
    /// The Overview's layout (the tiles fill the card), also while it grows in and shrinks out.
    private var expanded: Bool { morph.isExpandedLayout }

    /// How far tiles start outside their grid position when the panel opens.
    private static let entranceOffset: CGFloat = 4

    // At 100 %; the panel zoom (`scale`) multiplies them. The Overview's outer size doesn't zoom
    // (a share of the screen, Settings), only what is inside the tiles.
    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 2
    private nonisolated static let space = "overview"

    private var rowHeight: CGFloat { Self.rowHeight * scale }
    private var rowSpacing: CGFloat { Self.rowSpacing * scale }
    private var rowPitch: CGFloat { rowHeight + rowSpacing }
    private var tileSpacing: CGFloat { TileNotch.spacing * scale }

    /// A row being dragged by its grip: where it started (Overview space) and how far it has moved.
    private struct TileDrag {
        let todo: TodoSnapshot
        let source: Quadrant
        let start: CGRect
        var translation = CGSize.zero
        var target: DropTarget?

        /// How far the grip's middle is in from the row's trailing end (17 pt at 100 %).
        var gripInset: CGFloat

        /// The pointer, on the grip at the row's trailing end.
        var point: CGPoint {
            CGPoint(x: start.maxX - gripInset + translation.width, y: start.midY + translation.height)
        }
    }

    /// Where a drag would land: insertion point `index` of `quadrant`, the line drawn at `lineY`
    /// (`nil` when the drop would leave the todo where it is).
    private struct DropTarget: Equatable {
        let quadrant: Quadrant
        let index: Int
        let lineY: CGFloat?
    }

    var body: some View {
        VStack(spacing: tileSpacing) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: tileSpacing) {
                    ForEach(0..<2, id: \.self) { column in
                        if let quadrant = Quadrant(gridPosition: GridPosition(row: row, column: column)) {
                            tile(quadrant)
                        }
                    }
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        // In the hole where the four tiles meet, in both layouts.
        .overlay {
            // Its icon follows the direction, which only changes in the fade stages, so it swaps in
            // place before the tiles move instead of flying along with them.
            OverviewToggleButton(isOverview: morph.isHeadingToOverview) { model.toggleOverview() }
        }
        .overlay(alignment: .topLeading) { movePickerLayer }
        .overlay(alignment: .topLeading) { dragLayer }
        // Reduce Motion: no growing tiles. They fade out, the card changes size in one step, and
        // they fade in again.
        .opacity(hidesTiles ? 0 : 1)
        .onChange(of: model.lastDone) { _, event in
            guard let event, let frame = rowWindowFrames.removeValue(forKey: event.id) else { return }
            panelEffects?.launch(event.emoji, atX: frame.midX)
        }
        .onAppear { pointer.reset() }
    }

    private var hidesTiles: Bool {
        guard reduceMotion else { return false }
        switch morph.stage {
        case .hidingCounts, .growing, .hidingRows, .shrinking: return true
        case .compact, .revealingRows, .expanded, .revealingCounts: return false
        }
    }

    /// The quadrant marked in its colour: the Overview's focused tile, or the small grid's
    /// highlighted card (none while Browse's Archive button has the highlight).
    private var highlighted: Quadrant? {
        flow.phase == .picking && flow.isArchiveHighlighted ? nil : flow.quadrant
    }

    // MARK: Tile

    private func tile(_ quadrant: Quadrant) -> some View {
        let isHighlighted = highlighted == quadrant
        let notch = TileNotch(quadrant, scale: scale)
        return VStack(alignment: .leading, spacing: (expanded ? 8 : 6) * scale) {
            header(quadrant)
                .modifier(notch.headerClearance)
            if expanded {
                if morph.showsRows {
                    if isHighlighted, let editor = model.tileEditor {
                        QuickEntryView(model: editor, inTile: true)
                            .id(editor.flow.todoID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .transition(.opacity)
                    } else {
                        list(quadrant)
                            .transition(.opacity)
                    }
                }
            } else {
                // Faded, not removed: the count keeps its space while hidden, so the shrink ends
                // at the small grid's final height instead of the card growing again (and the
                // grow starts from it) when the count comes back.
                openCount(quadrant)
                    .opacity(morph.showsCounts ? 1 : 0)
            }
        }
        .padding(12 * scale)
        .padding(.bottom, expanded ? notch.bottomClearance : 0)
        .frame(maxWidth: .infinity, minHeight: expanded ? nil : 96 * scale, maxHeight: expanded ? .infinity : nil, alignment: .topLeading)
        .modifier(QuadrantTileBackground(
            quadrant: quadrant, isHighlighted: isHighlighted, shape: notch.shape, style: expanded ? .outline : .glow,
            showsGlow: morph.showsCounts, // fades in with the counts, once the tiles have their size
            isHovered: morph.stage == .compact && hoveredTile == quadrant // a click only opens it there
        ))
        .onHover { inside in
            if inside { hoveredTile = quadrant } else if hoveredTile == quadrant { hoveredTile = nil }
        }
        // The small grid's highlighted card grows a little, from the corner at the middle, so the
        // gutter around the middle button stays even.
        .scaleEffect(!expanded && isHighlighted && !reduceMotion ? 1.015 : 1, anchor: notch.anchor)
        .animation(.snappy(duration: 0.22), value: isHighlighted)
        .offset(entranceOffset(for: quadrant))
        .contentShape(notch.shape)
        .onTapGesture { if morph.stage == .compact { model.choose(quadrant) } }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { tileFrames[quadrant] = $0 }
        .accessibilityElement(children: expanded ? .contain : .combine)
        .accessibilityLabel(quadrant.displayName)
        .accessibilityAddTraits(expanded ? (isHighlighted ? .isSelected : []) : (isHighlighted ? [.isButton, .isSelected] : .isButton))
    }

    /// The small grid's big "N open".
    private func openCount(_ quadrant: Quadrant) -> some View {
        let n = flow.count(in: quadrant)
        return HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
            Text("\(n)")
                .panelFont(size: 30, weight: .semibold, design: .rounded, monospacedDigit: true)
                .foregroundStyle(n == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(quadrant.color))
                .contentTransition(.numericText())
            Text("open")
                .panelFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Diagonally outward toward the tile's own corner while the panel is still hidden.
    private func entranceOffset(for quadrant: Quadrant) -> CGSize {
        guard panelState == .hidden, !reduceMotion, !expanded else { return .zero }
        let position = quadrant.gridPosition
        let d = Self.entranceOffset * scale
        return CGSize(width: position.column == 0 ? -d : d, height: position.row == 0 ? -d : d)
    }

    /// Name and number key; in the Overview also the quadrant's colour dot and "N open". A click
    /// focuses the tile (Overview) or opens the quadrant (small grid); in the Overview a drop on
    /// it puts a todo on top.
    private func header(_ quadrant: Quadrant) -> some View {
        let dotLift = 4 * scale // captured: the alignment guide's closure runs off the main actor
        return HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
            if expanded {
                // The quadrant's colour, like the move dots on the selected row.
                Circle()
                    .fill(quadrant.color)
                    .frame(width: QuadrantDots.dotSize * scale, height: QuadrantDots.dotSize * scale)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + dotLift }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            Text(quadrant.displayName)
                .panelFont(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if expanded {
                Text("\(flow.count(in: quadrant)) open")
                    .panelFont(.caption, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            KeyCap(text: "\(quadrant.shortcutNumber)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            switch morph.stage {
            case .compact: model.choose(quadrant)
            case .expanded, .revealingRows: model.focus(quadrant)
            default: break
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { headerFrames[quadrant] = $0 }
        .help(expanded ? "Focus \(quadrant.displayName) (\(quadrant.shortcutNumber) or ⌥\(quadrant.shortcutNumber))" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if expanded { model.focus(quadrant) } else { model.choose(quadrant) } }
    }

    @ViewBuilder private func list(_ quadrant: Quadrant) -> some View {
        let rows = flow.rows(in: quadrant)
        if rows.isEmpty {
            PanelEmptyState(title: "Nothing here", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { listFrames[quadrant] = $0 }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: rowSpacing) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, todo in
                            row(todo, in: quadrant, index: index)
                                .id(todo.id)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .top).combined(with: .opacity)
                                ))
                        }
                    }
                }
                // No indicators flashing up while the rows fade in.
                .scrollIndicators(morph.stage == .expanded ? .automatic : .hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { listFrames[quadrant] = $0 }
                .onChange(of: flow.quadrant == quadrant ? flow.selectedTodo?.id : nil) { _, id in
                    if drag == nil, let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    // MARK: Row

    /// Like a row of the single-quadrant list; only the focused tile has a selection.
    private func row(_ todo: TodoSnapshot, in quadrant: Quadrant, index: Int) -> some View {
        let isSelected = flow.quadrant == quadrant && flow.selectedTodo?.id == todo.id
        let isDragged = drag?.todo.id == todo.id
        return HStack(spacing: 10 * scale) {
            DoneButton(color: todo.quadrant.color) { model.complete(todo.id) }
            Text(todo.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            AttachmentBadge(count: todo.attachmentCount)
            QuadrantDots(current: todo.quadrant, isActive: isSelected && drag == nil) { model.move(todo.id, to: $0) }
            dragHandle(todo, in: quadrant, isActive: isSelected || isDragged)
        }
        .padding(.leading, 10 * scale)
        .padding(.trailing, 4 * scale)
        .frame(height: rowHeight)
        .background(
            Color.primary.opacity(isSelected ? (colorScheme == .dark ? 0.12 : 0.07) : 0),
            in: RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
        )
        .contentShape(Rectangle())
        .opacity(isDragged ? 0.35 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { rowFrames[todo.id] = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowWindowFrames[todo.id] = $0 }
        .onTapGesture { model.openInTile(todo.id) }
        .onHover { inside in
            // As in the list: only a real pointer move selects, and only in the focused tile.
            if inside, drag == nil, flow.movePicker == nil, flow.quadrant == quadrant, pointer.moved() {
                model.select(todo.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.openInTile(todo.id) }
        .accessibilityAction(named: "Move Up") { model.drop(todo.id, on: quadrant, at: index - 1) }
        .accessibilityAction(named: "Move Down") { model.drop(todo.id, on: quadrant, at: index + 2) }
        .accessibilityActions {
            ForEach(Quadrant.allCases.filter { $0 != todo.quadrant }) { target in
                Button("Move to \(target.displayName)") { model.drop(todo.id, on: target, at: 0) }
            }
        }
    }

    /// The grip: drag it to another place in the tile or to another tile (an AppKit view, so the
    /// drag never moves the panel).
    private func dragHandle(_ todo: TodoSnapshot, in quadrant: Quadrant, isActive: Bool) -> some View {
        Image(systemName: "line.3.horizontal")
            .panelFont(size: 12, weight: .medium)
            .foregroundStyle(isActive ? .secondary : .tertiary)
            .frame(width: 26 * scale, height: rowHeight)
            .overlay {
                DragHandleArea(
                    onBegan: {
                        guard let start = rowFrames[todo.id] else { return }
                        drag = TileDrag(todo: todo, source: quadrant, start: start, gripInset: 17 * scale)
                    },
                    onChanged: { translation in
                        guard var current = drag else { return }
                        current.translation = translation
                        current.target = dropTarget(for: current)
                        withAnimation(.snappy(duration: 0.12)) { drag = current }
                    },
                    onEnded: {
                        guard let ended = drag else { return }
                        drag = nil
                        if let target = ended.target {
                            model.drop(ended.todo.id, on: target.quadrant, at: target.index)
                        }
                        pointer.reset()
                    }
                )
            }
            .help("Drag to move, also to another quadrant")
            .accessibilityHidden(true)
    }

    // MARK: Drag and drop

    /// The tile under the pointer and the insertion point there: the header is the top; in the
    /// list it is the gap nearest the pointer. Rows have a fixed pitch, so one row in view places
    /// them all, also those scrolled out of view.
    private func dropTarget(for drag: TileDrag) -> DropTarget? {
        let point = drag.point
        guard let quadrant = Quadrant.allCases.first(where: { tileFrames[$0]?.contains(point) == true }) else { return nil }
        let rows = flow.rows(in: quadrant)
        guard let list = listFrames[quadrant] else { return nil }
        // Where row 0 is (it moves with scrolling), from a row that is in view.
        let anchor = rows.indices.first { index in rowFrames[rows[index].id].map { list.intersects($0) } ?? false }
        let top = anchor.flatMap { index in rowFrames[rows[index].id].map { $0.minY - CGFloat(index) * rowPitch } } ?? list.minY
        let index: Int
        if let header = headerFrames[quadrant], point.y <= header.maxY + 4 * scale {
            index = 0
        } else {
            let gap = Int(((point.y - top - rowHeight / 2) / rowPitch).rounded(.down)) + 1
            index = min(max(gap, 0), rows.count)
        }
        // Where it already is: no line, and the drop changes nothing.
        if quadrant == drag.source, let from = rows.firstIndex(where: { $0.id == drag.todo.id }), index == from || index == from + 1 {
            return DropTarget(quadrant: quadrant, index: index, lineY: nil)
        }
        let y = top + CGFloat(index) * rowPitch - rowSpacing / 2
        return DropTarget(quadrant: quadrant, index: index, lineY: min(max(y, list.minY + 1), list.maxY - 1))
    }

    /// The insertion line in the target tile and the dragged row's copy under the pointer.
    @ViewBuilder private var dragLayer: some View {
        if let drag, morph.showsRows {
            ZStack(alignment: .topLeading) {
                if let target = drag.target, let y = target.lineY, let tile = tileFrames[target.quadrant] {
                    Capsule()
                        .fill(target.quadrant.color)
                        .frame(width: tile.width - 24 * scale, height: 3 * scale)
                        .position(x: tile.midX, y: y)
                }
                HStack(spacing: 10 * scale) {
                    Image(systemName: "checkmark.circle")
                        .panelFont(size: 15)
                        .foregroundStyle(drag.todo.quadrant.color)
                    Text(drag.todo.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "line.3.horizontal")
                        .panelFont(size: 12, weight: .medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 26 * scale)
                }
                .padding(.leading, 10 * scale)
                .padding(.trailing, 4 * scale)
                .frame(width: drag.start.width, height: rowHeight)
                .background {
                    RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                }
                .position(x: drag.start.midX + drag.translation.width, y: drag.start.midY + drag.translation.height)
                .transaction { $0.animation = nil } // follows the pointer exactly
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Move picker

    /// `m` in the focused tile: the move picker next to the selected row, kept inside the tile.
    @ViewBuilder private var movePickerLayer: some View {
        if morph.showsRows, let picker = flow.movePicker, let row = rowFrames[picker.todo.id], let tile = tileFrames[flow.quadrant] {
            let height = movePickerSize.height
            let below = row.maxY + 4 * scale
            let y = below + height <= tile.maxY ? below : max(row.minY - 4 * scale - height, tile.minY)
            ZStack(alignment: .topLeading) {
                // A click anywhere else closes the picker (and does nothing else).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeMovePicker() }
                    .accessibilityHidden(true)
                MoveQuadrantPicker(picker: picker) { model.move(picker.todo.id, to: $0) }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { movePickerSize = $0 }
                    .offset(x: tile.maxX - (60 + MoveQuadrantPicker.width) * scale, y: y)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The small rounded-rect button in the hole where the four cards (or tiles) meet: opens the
/// Overview from the small grid and shrinks it back. Same surface as a resting tile.
struct OverviewToggleButton: View {
    let isOverview: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.panelScale) private var scale

    /// At 100 %; the panel zoom multiplies it (and the tiles' cut-out around it, `TileNotch`).
    nonisolated static let size: CGFloat = 30

    var body: some View {
        let shape = Circle()
        let isDark = colorScheme == .dark
        let isEmphasised = differentiateWithoutColor || contrast == .increased
        Button(action: action) {
            // Both icons are always laid out in the circle and only cross-fade, so neither can
            // lag behind or fly in while the circle moves (a symbol replace effect could).
            ZStack {
                Image(systemName: "arrow.up.left.and.arrow.down.right").opacity(isOverview ? 0 : 1)
                Image(systemName: "arrow.down.right.and.arrow.up.left").opacity(isOverview ? 1 : 0)
            }
                .panelFont(size: 11, weight: .semibold)
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: Self.size * scale, height: Self.size * scale)
                .background(QuadrantTileBackground<RoundedRectangle>.restingFill(isDark: isDark), in: shape)
                // A touch brighter under the pointer (no scale: the gap around it stays even).
                .background(Color.primary.opacity(isHovered ? (isDark ? 0.08 : 0.05) : 0), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(isEmphasised ? 0.3 : 0), lineWidth: 1))
                .animation(.snappy(duration: 0.15), value: isHovered)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isOverview ? "Back to quadrants (esc)" : "Overview (\(BrowseFlow.overviewKey.uppercased()))")
        .accessibilityLabel(isOverview ? "Close Overview" : "Open Overview")
    }
}
