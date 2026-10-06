import AppIntents
import HowyCore
import SwiftUI
import WidgetKit

/// Shared spacing/typography so every widget size renders the builder's line capacity without clipping.
enum WidgetMetrics {
    static let rowSpacing: CGFloat = 3
    static let labelSpacing: CGFloat = 5
    static let checkboxWidth: CGFloat = 14
    static let rowFont: Font = .system(size: 12)
    static let labelFont: Font = .system(size: 10, weight: .semibold)
}

/// One quadrant: coloured label (→ quick add), rows (checkbox + title → edit), "+N more", or a quiet empty state.
struct QuadrantSectionView: View {
    let content: QuadrantContent

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.labelSpacing) {
            QuadrantLabel(quadrant: content.quadrant, openCount: content.openCount)

            if content.isEmpty {
                EmptyQuadrantView()
            } else {
                VStack(alignment: .leading, spacing: WidgetMetrics.rowSpacing) {
                    ForEach(content.visible) { todo in
                        TodoRow(todo: todo)
                    }
                    if content.overflowCount > 0 {
                        Text("+\(content.overflowCount) more")
                            .font(WidgetMetrics.rowFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, WidgetMetrics.checkboxWidth + 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct QuadrantLabel: View {
    let quadrant: Quadrant
    let openCount: Int

    var body: some View {
        Link(destination: DeepLink.quickAdd(quadrant).url) {
            HStack(spacing: 4) {
                Text(quadrant.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.85)
                Text("\(openCount)")
                    .monospacedDigit()
                    .opacity(openCount > 0 ? 0.75 : 0.4)
            }
            .font(WidgetMetrics.labelFont)
            .foregroundStyle(quadrant.color)
            .textCase(.uppercase)
        }
        .widgetAccentable()
    }
}

struct TodoRow: View {
    let todo: TodoSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Button(intent: CompleteTodoIntent(id: todo.id)) {
                Image(systemName: "circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(todo.quadrant.color)
                    .frame(width: WidgetMetrics.checkboxWidth, height: WidgetMetrics.checkboxWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .widgetAccentable()
            .accessibilityLabel("Complete \(todo.title)")

            Link(destination: DeepLink.edit(todo.id).url) {
                HStack(spacing: 3) {
                    Text(todo.title)
                        .font(WidgetMetrics.rowFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if todo.attachmentCount > 0 {
                        HStack(spacing: 1) {
                            Image(systemName: "paperclip")
                            if todo.attachmentCount > 1 { Text("\(todo.attachmentCount)").monospacedDigit() }
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                        .accessibilityLabel("with attachments")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
    }
}

/// Shown instead of the todos when the shared store can't be read (not the same as "nothing here").
struct WidgetErrorView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
            Text("Can't read Howy data")
                .multilineTextAlignment(.center)
        }
        .font(WidgetMetrics.rowFont)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyQuadrantView: View {
    var body: some View {
        Text("Nothing here")
            .font(WidgetMetrics.rowFont)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.leading, WidgetMetrics.checkboxWidth + 6)
    }
}

/// The translucent "glass" surface a quadrant sits on: a see-through neutral base for legibility,
/// a faint quadrant tint and a hairline edge.
///
/// Plain SwiftUI colours only, no materials or `glassEffect`: widget views are archived and drawn by
/// the system, which gives no guarantee that backdrop effects render (and can't be checked without a
/// device test), whereas flat colours with opacity always do. In accented/vibrant modes the system
/// re-tints every colour, so only the opacity matters there: a faint neutral fill keeps tiles visible.
/// `concentric` gives a Matrix tile corners that follow the widget's rounded mask where they meet
/// it (so they never poke past it) and a fixed small radius where tiles face each other; otherwise
/// the surface is the widget's own shape (the Quadrant widget, where the tile is the widget).
struct QuadrantSurface: View {
    let quadrant: Quadrant
    var concentric = false
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if concentric {
            surface(in: ConcentricRectangle(corners: .concentric(minimum: .fixed(QuadrantTile.innerCornerRadius))))
        } else {
            surface(in: ContainerRelativeShape())
        }
    }

    private func surface(in shape: some Shape) -> some View {
        ZStack {
            shape.fill(base)
            shape.fill(tint)
            // A 1pt centred stroke clipped to the shape: a 0.5pt hairline inside the edge.
            shape.stroke(edge, lineWidth: 1)
        }
        .clipShape(shape)
    }

    private var isFullColor: Bool { renderingMode == .fullColor }

    /// See-through neutral layer that keeps text legible on any wallpaper.
    private var base: Color {
        guard isFullColor else { return Color.primary.opacity(0.08) }
        return colorScheme == .dark ? Color.black.opacity(0.32) : Color.white.opacity(0.45)
    }

    private var tint: Color {
        guard isFullColor else { return .clear }
        return quadrant.color.opacity(colorScheme == .dark ? 0.16 : 0.10)
    }

    private var edge: Color {
        isFullColor ? quadrant.color.opacity(0.28) : Color.primary.opacity(0.14)
    }
}

/// A Matrix quadrant drawn as its own floating tile.
struct QuadrantTile: ViewModifier {
    let quadrant: Quadrant

    /// Radius of the corners that face the other tiles.
    static let innerCornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(9)
            .background { QuadrantSurface(quadrant: quadrant, concentric: true) }
    }
}

extension View {
    func quadrantTile(_ quadrant: Quadrant) -> some View {
        modifier(QuadrantTile(quadrant: quadrant))
    }
}
