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
    /// Where each row currently is, in window coordinates (where the done emoji starts).
    @State private var rowFrames: [UUID: CGRect] = [:]
    @Environment(\.panelEffects) private var panelEffects

    private var flow: BrowseFlow { model.flow }

    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 2
    private static var rowPitch: CGFloat { rowHeight + rowSpacing }
    private static let maxListHeight: CGFloat = 380

    private struct RowDrag {
        let id: UUID
        let startIndex: Int
        var translation: CGFloat = 0
    }

    var body: some View {
        Group { // the card is drawn once by the panel (PanelRoot)
            VStack(alignment: .leading, spacing: 12) {
                if flow.phase == .listing {
                    list
                } else {
                    QuadrantGrid(highlighted: flow.isArchiveHighlighted ? nil : flow.quadrant, count: { flow.count(in: $0) }) {
                        model.choose($0)
                    }
                }
                footer
            }
        }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.25)) { flow.backToPicker() } } label: {
                QuadrantChip(quadrant: flow.quadrant)
            }
            .buttonStyle(.plain)
            .help("Back to quadrants (esc)")
            Text("\(flow.rows.count) open")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
        }

        if flow.rows.isEmpty {
            ContentUnavailableView(
                "Nothing here",
                systemImage: "checkmark.circle",
                description: Text("No open todos in \(flow.quadrant.displayName).")
            )
            .frame(maxWidth: .infinity) // the column is leading-aligned; centre it in the card
            .frame(height: 160)
            .transition(.opacity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.rowSpacing) {
                        ForEach(Array(flow.rows.enumerated()), id: \.element.id) { index, todo in
                            row(todo, index: index, isSelected: index == flow.selectedIndex)
                                .id(todo.id)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(CGFloat(flow.rows.count) * Self.rowPitch, Self.maxListHeight))
                .onChange(of: flow.selectedIndex) { _, _ in
                    if drag == nil, let id = flow.selectedTodo?.id { proxy.scrollTo(id) }
                }
                .onChange(of: model.lastDone) { _, event in
                    guard let event else { return }
                    fire(event)
                }
                .onAppear { pointer.reset() }
            }
        }
    }

    private func row(_ todo: TodoSnapshot, index: Int, isSelected: Bool) -> some View {
        let isDragged = drag?.id == todo.id
        return HStack(spacing: 10) {
            Button { model.complete(todo.id) } label: {
                Image(systemName: "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(todo.quadrant.color)
            }
            .buttonStyle(.plain)
            .help("Mark done (space)")
            Text(todo.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            AttachmentBadge(count: todo.attachmentCount)
            dragHandle(todo, index: index, isActive: isSelected || isDragged)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: Self.rowHeight)
        .background(
            // Neutral selection like Raycast's list; the quadrant colour stays on the circle.
            Color.primary.opacity(isSelected || isDragged ? (colorScheme == .dark ? 0.12 : 0.07) : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[todo.id] = $0 }
        .onTapGesture { model.open(todo.id) }
        .onHover { inside in
            // Only a real pointer move selects: rows sliding under a resting pointer (keyboard
            // moves, scrolling, the panel opening) must not steal the selection.
            if inside, drag == nil, pointer.moved() { model.select(todo.id) }
        }
        .offset(y: isDragged ? draggedOffset(index: index) : 0)
        .zIndex(isDragged ? 1 : 0)
        // The dragged row follows the pointer exactly; only the others animate into place.
        .transaction { if isDragged { $0.animation = nil } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Move Up") { reorder(todo.id, to: index - 1) }
        .accessibilityAction(named: "Move Down") { reorder(todo.id, to: index + 1) }
    }

    /// The grip on the right: drag it to move the row (an AppKit view, so the drag never moves the panel).
    private func dragHandle(_ todo: TodoSnapshot, index: Int, isActive: Bool) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isActive ? .secondary : .tertiary)
            .frame(width: 26, height: Self.rowHeight)
            .overlay {
                DragHandleArea(
                    onBegan: {
                        model.select(todo.id)
                        drag = RowDrag(id: todo.id, startIndex: flow.rows.firstIndex { $0.id == todo.id } ?? index)
                    },
                    onChanged: { translation in
                        guard var current = drag else { return }
                        current.translation = translation
                        drag = current
                        let target = current.startIndex + Int((translation / Self.rowPitch).rounded())
                        model.drag(todo.id, to: target)
                    },
                    onEnded: {
                        guard let ended = drag else { return }
                        withAnimation(.snappy(duration: 0.2)) { drag = nil }
                        if flow.rows.firstIndex(where: { $0.id == ended.id }) != ended.startIndex {
                            model.persistOrder()
                        }
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
        return drag.translation - CGFloat(index - drag.startIndex) * Self.rowPitch
    }

    private func reorder(_ id: UUID, to index: Int) {
        model.drag(id, to: index)
        model.persistOrder()
    }

    // MARK: Done emoji

    /// Launches `event`'s emoji from the done circle of the row that was just marked done
    /// (measured before it left); it flies out of the card to the right (`PanelEffects`).
    private func fire(_ event: BrowseModel.DoneEvent) {
        guard let frame = rowFrames.removeValue(forKey: event.id) else { return }
        panelEffects?.launch(event.emoji, from: CGPoint(x: frame.minX + 18, y: frame.midY))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if flow.phase == .picking { archiveButton }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Spacer()
            if flow.phase == .listing {
                KeyHints(
                    "↑↓ select · ⌘J ⌘K move · ↩ edit · space done · ⌫ archive · 1–4 switch · esc back",
                    short: "↑↓ select · ↩ edit · space done · ⌫ archive · esc back"
                )
            } else {
                KeyHints("←↑↓→ or 1–4 · ↩ open · esc close")
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    /// Tertiary entry to the archive at the bottom of the picker; ↓ from the bottom row or `a`
    /// reach it from the keyboard.
    private var archiveButton: some View {
        let isHighlighted = flow.isArchiveHighlighted
        return Button { model.openArchive() } label: {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                Text("Archive")
                KeyCap(text: String(BrowseFlow.archiveKey).uppercased())
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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

/// A transparent AppKit area that reports vertical drags (downwards positive). Being an NSView
/// that can't move the window, dragging it reorders instead of moving the floating panel.
private struct DragHandleArea: NSViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    final class HandleView: NSView {
        var onBegan: () -> Void = {}
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: () -> Void = {}
        private var startY: CGFloat?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: startY == nil ? .openHand : .closedHand)
        }

        override func mouseDown(with event: NSEvent) {
            startY = event.locationInWindow.y
            NSCursor.closedHand.set()
            onBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startY else { return }
            NSCursor.closedHand.set()
            onChanged(startY - event.locationInWindow.y) // window y grows upwards
        }

        override func mouseUp(with event: NSEvent) {
            guard startY != nil else { return }
            startY = nil
            window?.invalidateCursorRects(for: self)
            onEnded()
        }
    }
}
