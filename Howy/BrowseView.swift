import AppKit
import HowyCore
import SwiftUI

/// Browse: the quadrant picker with open counts, then one quadrant's open todos.
/// A thin view over `BrowseFlow`; keys arrive via `FloatingPanel.keyHandler`.
struct BrowseView: View {
    let model: BrowseModel
    @Environment(\.colorScheme) private var colorScheme
    /// The row being dragged by its handle: where it started and how far the pointer has moved.
    @State private var drag: RowDrag?
    @State private var pointer = PointerTracker()
    /// Where each row currently is, in window coordinates (where the done emoji rises).
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// Where each row is in the list section (`listSpace`), to put the move picker next to it.
    @State private var rowListFrames: [UUID: CGRect] = [:]
    /// The list section's and the move picker's sizes, to keep the picker inside the card.
    @State private var listSize = CGSize.zero
    @State private var movePickerSize = CGSize(width: MoveQuadrantPicker.width, height: 150)
    @Environment(\.panelEffects) private var panelEffects
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelScale) private var scale
    @Environment(\.panelHeightLimit) private var heightLimit

    private var flow: BrowseFlow { model.flow }

    // At 100 %; the panel zoom (`scale`) multiplies them.
    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 2
    private static let maxListHeight: CGFloat = 380
    /// The card's height around the list: its padding, the quadrant chip, the footer and the gaps.
    private static let chromeHeight: CGFloat = 100
    private nonisolated static let listSpace = "browseList"
    /// How far the move picker sits in from the trailing edge, leaving the row's grip in view.
    private static let movePickerTrailing: CGFloat = 60

    private var rowHeight: CGFloat { Self.rowHeight * scale }
    private var rowSpacing: CGFloat { Self.rowSpacing * scale }
    private var rowPitch: CGFloat { rowHeight + rowSpacing }
    /// The list's cap: about the same number of rows at every zoom, but never past the screen.
    private var maxListHeight: CGFloat {
        max(min(Self.maxListHeight * scale, heightLimit - Self.chromeHeight * scale), rowPitch)
    }

    private struct RowDrag {
        let id: UUID
        let startIndex: Int
        var translation: CGFloat = 0
    }

    var body: some View {
        Group { // the card is drawn once by the panel (PanelRoot)
            VStack(alignment: .leading, spacing: 12 * scale) {
                if flow.phase == .listing {
                    list
                } else {
                    // The small grid and the Overview: one layout, so the tiles grow in step.
                    OverviewView(model: model)
                }
                footer
            }
            .frame(maxHeight: model.morph.isExpandedLayout ? .infinity : nil, alignment: .top)
            .onChange(of: model.lastMove) { _, event in
                guard let event else { return }
                panelEffects?.launchBadge(event.isUndo ? "Back to" : "Moved to", quadrant: event.quadrant)
            }
        }
    }

    // MARK: List

    private var list: some View {
        let placement = movePickerPlacement
        return VStack(alignment: .leading, spacing: 12 * scale) {
            listContent
        }
        .coordinateSpace(.named(Self.listSpace))
        // Measured before the picker's extra room is added, so that room doesn't feed back.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { listSize = $0 }
        .frame(minHeight: placement?.minHeight, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if let picker = flow.movePicker, let placement {
                // A click anywhere else in the list closes the picker (and does nothing else).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeMovePicker() }
                    .accessibilityHidden(true)
                MoveQuadrantPicker(picker: picker) { model.move(picker.todo.id, to: $0) }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { movePickerSize = $0 }
                    .padding(.trailing, Self.movePickerTrailing * scale)
                    .offset(y: placement.y)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
    }

    /// Where the move picker goes: just below its row, or above it when there is no room below;
    /// `minHeight` grows the list section (and the card) when it fits neither way. `listSize` is
    /// the list's own height, without that extra room.
    private var movePickerPlacement: (y: CGFloat, minHeight: CGFloat?)? {
        guard let picker = flow.movePicker, let row = rowListFrames[picker.todo.id] else { return nil }
        let height = movePickerSize.height
        let below = row.maxY + 4 * scale
        let above = row.minY - 4 * scale - height
        if below + height <= listSize.height { return (below, nil) }
        if above >= 0 { return (above, nil) }
        return (below, below + height)
    }

    @ViewBuilder private var listContent: some View {
        HStack(spacing: 8 * scale) {
            Button { withAnimation(.snappy(duration: 0.25)) { flow.backToPicker() } } label: {
                QuadrantChip(quadrant: flow.quadrant)
            }
            .buttonStyle(.plain)
            .help("Back to quadrants (esc)")
            Text("\(flow.rows.count) open")
                .panelFont(.caption, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
        }

        if flow.rows.isEmpty {
            PanelEmptyState(
                title: "Nothing here",
                systemImage: "checkmark.circle",
                description: "No open todos in \(flow.quadrant.displayName)."
            )
            .frame(maxWidth: .infinity) // the column is leading-aligned; centre it in the card
            .frame(height: 160 * scale)
            .transition(.opacity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: rowSpacing) {
                        ForEach(Array(flow.rows.enumerated()), id: \.element.id) { index, todo in
                            row(todo, index: index, isSelected: index == flow.selectedIndex)
                                .id(todo.id)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
                                ))
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(CGFloat(flow.rows.count) * rowPitch, maxListHeight))
                .onChange(of: flow.selectedIndex) { _, _ in
                    if drag == nil, let id = flow.selectedTodo?.id { proxy.scrollTo(id) }
                }
                .onChange(of: model.lastDone) { _, event in
                    guard let event else { return }
                    fire(event)
                }
                .onChange(of: flow.movePicker?.todo.id) { _, id in
                    if let id { withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) } }
                }
                .onAppear { pointer.reset() }
            }
        }
    }

    private func row(_ todo: TodoSnapshot, index: Int, isSelected: Bool) -> some View {
        let isDragged = drag?.id == todo.id
        return HStack(spacing: 10 * scale) {
            DoneButton(color: todo.quadrant.color) { model.complete(todo.id) }
            Text(todo.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            AttachmentBadge(count: todo.attachmentCount)
            QuadrantDots(current: todo.quadrant, isActive: isSelected && !isDragged) { model.move(todo.id, to: $0) }
            dragHandle(todo, index: index, isActive: isSelected || isDragged)
        }
        .padding(.leading, 10 * scale)
        .padding(.trailing, 4 * scale)
        .frame(height: rowHeight)
        .background(
            // Neutral selection like Raycast's list; the quadrant colour stays on the circle.
            Color.primary.opacity(isSelected || isDragged ? (colorScheme == .dark ? 0.12 : 0.07) : 0),
            in: RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
        )
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[todo.id] = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.listSpace)) } action: { rowListFrames[todo.id] = $0 }
        .onTapGesture { model.open(todo.id) }
        .onHover { inside in
            // Only a real pointer move selects: rows sliding under a resting pointer (keyboard
            // moves, scrolling, the panel opening) must not steal the selection.
            if inside, drag == nil, flow.movePicker == nil, pointer.moved() { model.select(todo.id) }
        }
        .offset(y: isDragged ? draggedOffset(index: index) : 0)
        .zIndex(isDragged ? 1 : 0)
        // The dragged row follows the pointer exactly; only the others animate into place.
        .transaction { if isDragged { $0.animation = nil } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Mark done") { model.complete(todo.id) }
        .accessibilityAction(named: "Move Up") { model.nudge(todo.id, by: -1) }
        .accessibilityAction(named: "Move Down") { model.nudge(todo.id, by: 1) }
        .accessibilityActions {
            ForEach(Quadrant.allCases.filter { $0 != todo.quadrant }) { quadrant in
                Button("Move to \(quadrant.displayName)") { model.move(todo.id, to: quadrant) }
            }
        }
    }

    /// The grip on the right: drag it to move the row (an AppKit view, so the drag never moves the panel).
    private func dragHandle(_ todo: TodoSnapshot, index: Int, isActive: Bool) -> some View {
        Image(systemName: "line.3.horizontal")
            .panelFont(size: 12, weight: .medium)
            .foregroundStyle(isActive ? .secondary : .tertiary)
            .frame(width: 26 * scale, height: rowHeight)
            .overlay {
                DragHandleArea(
                    onBegan: {
                        model.beginReorderDrag(todo.id)
                        drag = RowDrag(id: todo.id, startIndex: flow.rows.firstIndex { $0.id == todo.id } ?? index)
                    },
                    onChanged: { translation in
                        guard var current = drag else { return }
                        current.translation = translation.height
                        drag = current
                        let target = current.startIndex + Int((translation.height / rowPitch).rounded())
                        model.drag(todo.id, to: target)
                    },
                    onEnded: {
                        guard drag != nil else { return }
                        withAnimation(.snappy(duration: 0.2)) { drag = nil }
                        model.endReorderDrag() // one reorder, ⌘Z takes it back
                        pointer.reset()
                    }
                )
            }
            .help("Drag to reorder (⌘J / ⌘K)")
            .accessibilityHidden(true)
    }

    /// Keeps the dragged row under the pointer while its slot in the list changes.
    private func draggedOffset(index: Int) -> CGFloat {
        guard let drag else { return 0 }
        return drag.translation - CGFloat(index - drag.startIndex) * rowPitch
    }

    // MARK: Done emoji

    /// Launches `event`'s emoji up out of the card's top edge, above the row that was just marked
    /// done (measured before it left), while that row flies up and fades (`PanelEffects`).
    private func fire(_ event: BrowseModel.DoneEvent) {
        guard let frame = rowFrames.removeValue(forKey: event.id) else { return }
        panelEffects?.launch(event.emoji, atX: frame.midX)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12 * scale) {
            if flow.phase == .picking, !model.morph.isExpandedLayout { archiveButton }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Spacer()
            // "⌘Z undo" is shown once there is something to undo, so a wrong D is caught right away.
            let undo = flow.canUndo ? " · ⌘Z undo" : ""
            if flow.movePicker != nil {
                KeyHints("1–4 move · ←↑↓→ select · ↩ move · esc cancel")
            } else if model.morph.isExpandedLayout, model.tileEditor != nil {
                KeyHints("⌥1–4 focus quadrant (keeps the edit as a draft)")
            } else if model.morph.isExpandedLayout {
                KeyHints(
                    "1–4 focus · ⇥ next · ↑↓ select · ↩ edit · D done · ⌫ archive · M ⌘1–4 move · ⌘J ⌘K reorder\(undo) · esc back",
                    short: "1–4 focus · ↑↓ select · ↩ edit · D done · M move\(undo) · esc back"
                )
            } else if flow.phase == .listing {
                KeyHints(
                    "↑↓ select · ⌘J ⌘K reorder · ↩ edit · D done · ⌫ archive · M ⌘1–4 move\(undo) · 1–4 switch · esc back",
                    short: "↑↓ select · ↩ edit · D done · M ⌘1–4 move\(undo) · esc back"
                )
            } else {
                KeyHints("←↑↓→ or 1–4 · ↩ open · O overview\(undo) · esc close", short: "←↑↓→ or 1–4 · ↩ open\(undo) · esc close")
            }
        }
        .panelFont(.caption)
        .lineLimit(1)
        // Out of view while the tiles grow or shrink: the grid's and the Overview's hints swap
        // unseen, instead of sliding through the tiles.
        .opacity(model.morph.showsFooter ? 1 : 0)
        .allowsHitTesting(model.morph.showsFooter)
    }

    /// Tertiary entry to the archive at the bottom of the picker; ↓ from the bottom row or `a`
    /// reach it from the keyboard.
    private var archiveButton: some View {
        let isHighlighted = flow.isArchiveHighlighted
        return Button { model.openArchive() } label: {
            HStack(spacing: 6 * scale) {
                Image(systemName: "archivebox")
                Text("Archive")
                KeyCap(text: String(BrowseFlow.archiveKey).uppercased())
            }
            .panelFont(.caption, weight: .medium)
            .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 4 * scale)
            .background(
                Color.accentColor.opacity(isHighlighted ? (colorScheme == .dark ? 0.22 : 0.12) : 0),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(isHighlighted ? 0.7 : 0), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Archive (\(BrowseFlow.archiveKey))")
        .animation(.snappy(duration: 0.22), value: isHighlighted)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

/// Remembers where the pointer was, to tell a real move from content sliding under it.
@MainActor
final class PointerTracker {
    private var last = NSEvent.mouseLocation

    func reset() { last = NSEvent.mouseLocation }

    /// True (once) when the pointer has moved since the last call or reset.
    func moved() -> Bool {
        let now = NSEvent.mouseLocation
        defer { last = now }
        return now != last
    }
}

/// A transparent AppKit area that reports drags (how far the pointer moved; downwards positive). Being an NSView
/// that can't move the window, dragging it reorders instead of moving the floating panel.
struct DragHandleArea: NSViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    final class HandleView: NSView {
        var onBegan: () -> Void = {}
        var onChanged: (CGSize) -> Void = { _ in }
        var onEnded: () -> Void = {}
        private var start: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: start == nil ? .openHand : .closedHand)
        }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            NSCursor.closedHand.set()
            onBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            NSCursor.closedHand.set()
            let now = event.locationInWindow
            onChanged(CGSize(width: now.x - start.x, height: start.y - now.y)) // window y grows upwards
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            window?.invalidateCursorRects(for: self)
            onEnded()
        }
    }
}

/// The selected row's mouse path to another quadrant: four small dots in quadrant order 1–4,
/// rings in the quadrant colours, the todo's own one filled (and not clickable). A click on
/// another dot moves the todo. Always laid out, so titles don't jump, but only shown (and only
/// clickable) on the selected row. Each dot is a plain Button with a 20 pt hit area, so a click
/// never opens the row. Hidden from VoiceOver: the row has "Move to …"
/// actions instead.
struct QuadrantDots: View {
    let current: Quadrant
    let isActive: Bool
    let onMove: (Quadrant) -> Void

    // At 100 %; the panel zoom multiplies them.
    static let hitSize: CGFloat = 20
    static let dotSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Quadrant.allCases) { quadrant in
                QuadrantDot(quadrant: quadrant, isCurrent: quadrant == current, isActive: isActive) { onMove(quadrant) }
            }
        }
        .opacity(isActive ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .accessibilityHidden(true)
    }
}

private struct QuadrantDot: View {
    let quadrant: Quadrant
    let isCurrent: Bool
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.panelScale) private var scale

    private var isClickable: Bool { isActive && !isCurrent }

    var body: some View {
        // A SwiftUI Button (like DoneButton), so the click is the button's and never reaches the
        // row's tap gesture, which would open the todo.
        Button(action: action) {
            ZStack {
                if isCurrent {
                    Circle().fill(quadrant.color)
                } else {
                    Circle().strokeBorder(quadrant.color, lineWidth: 1.5 * scale)
                }
            }
            .frame(width: QuadrantDots.dotSize * scale, height: QuadrantDots.dotSize * scale)
            .scaleEffect(isHovered && isClickable ? 1.3 : 1)
            .animation(.snappy(duration: 0.12), value: isHovered)
            .frame(width: QuadrantDots.hitSize * scale, height: QuadrantDots.hitSize * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isClickable)
        // Hidden or current dots let clicks through to the row.
        .allowsHitTesting(isClickable)
        .pointerStyle(isClickable ? .link : nil)
        .onHover { isHovered = $0 }
        .help(isClickable ? "Move to \(quadrant.displayName) (⌘\(quadrant.shortcutNumber))" : "")
        .onChange(of: isClickable) { _, clickable in if !clickable { isHovered = false } }
    }
}

/// Marks a row's todo done. Shows a checkmark from the start (the row leaves the list on click, so
/// an empty circle would never get its tick) and fills in under the pointer.
struct DoneButton: View {
    let color: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isHovered ? "checkmark.circle.fill" : "checkmark.circle")
                .panelFont(size: 15)
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Mark done (\(BrowseFlow.doneKey))")
        .accessibilityLabel("Mark done")
    }
}
