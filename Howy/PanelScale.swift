import SwiftUI

/// Panel zoom in the views: `PanelRoot` puts the current `PanelZoom.scale` into the environment,
/// and every panel view draws its fonts and lengths through it. Outside a panel (Settings, the
/// Import/Export window) the scale is 1, so shared views like `KeyCap` look as before there.
extension EnvironmentValues {
    /// How much bigger everything in the enclosing panel is drawn (`PanelZoom.scale`); 1 outside panels.
    @Entry var panelScale: CGFloat = 1
    /// The tallest the panel's card may get: the room from its top edge down to the bottom of the
    /// screen (less a small gap). Infinite outside panels.
    @Entry var panelHeightLimit: CGFloat = .infinity
}

/// The system text styles, as fixed sizes that can be scaled: macOS draws a text style at one
/// size (it has no Dynamic Type), so the panel zoom multiplies these defaults instead.
/// The sizes and weights are `NSFont.preferredFont(forTextStyle:)`'s on macOS.
enum PanelTextStyle {
    case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2

    var pointSize: CGFloat {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .headline: .bold
        case .caption2: .medium
        default: .regular
        }
    }
}

extension Font {
    /// A text style at `scale` times its macOS size; `weight` replaces the style's own.
    static func panel(_ style: PanelTextStyle, scale: CGFloat, weight: Font.Weight? = nil) -> Font {
        .system(size: style.pointSize * scale, weight: weight ?? style.weight)
    }

    /// A fixed size at `scale` times `size`.
    static func panel(size: CGFloat, scale: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * scale, weight: weight, design: design)
    }
}

extension View {
    /// Sets a text style, scaled by the panel zoom (`\.panelScale`).
    func panelFont(_ style: PanelTextStyle, weight: Font.Weight? = nil, monospacedDigit: Bool = false) -> some View {
        modifier(PanelFontModifier(font: .style(style, weight), monospacedDigit: monospacedDigit))
    }

    /// Sets a fixed font size, scaled by the panel zoom (`\.panelScale`).
    func panelFont(
        size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, monospacedDigit: Bool = false
    ) -> some View {
        modifier(PanelFontModifier(font: .fixed(size, weight, design), monospacedDigit: monospacedDigit))
    }

    /// A control size that grows with the panel zoom from `base` (the size at 100 %).
    func panelControlSize(_ base: ControlSize) -> some View {
        modifier(PanelControlSizeModifier(base: base))
    }
}

private struct PanelFontModifier: ViewModifier {
    enum Spec {
        case style(PanelTextStyle, Font.Weight?)
        case fixed(CGFloat, Font.Weight, Font.Design)
    }

    let font: Spec
    let monospacedDigit: Bool
    @Environment(\.panelScale) private var scale

    func body(content: Content) -> some View {
        let font: Font = switch self.font {
        case .style(let style, let weight): .panel(style, scale: scale, weight: weight)
        case .fixed(let size, let weight, let design): .panel(size: size, scale: scale, weight: weight, design: design)
        }
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

private struct PanelControlSizeModifier: ViewModifier {
    let base: ControlSize
    @Environment(\.panelScale) private var scale

    func body(content: Content) -> some View {
        content.controlSize(size)
    }

    /// One size up from 130 %, two from 150 % (the steps between are the closest fit for the text).
    private var size: ControlSize {
        let order: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
        let steps = scale >= 1.45 ? 2 : scale >= 1.25 ? 1 : 0
        guard let index = order.firstIndex(of: base) else { return base }
        return order[min(index + steps, order.count - 1)]
    }
}

/// A panel's "nothing here" message: a symbol, a title and an optional line below, centred.
/// Like `ContentUnavailableView`, but drawn with the panel zoom's sizes (the system view keeps its
/// own fixed fonts).
struct PanelEmptyState: View {
    let title: String
    let systemImage: String
    var description: String?
    @Environment(\.panelScale) private var scale

    var body: some View {
        VStack(spacing: 6 * scale) {
            Image(systemName: systemImage)
                .panelFont(size: 34, weight: .light)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4 * scale)
            Text(title)
                .panelFont(.title3, weight: .semibold)
            if let description {
                Text(description)
                    .panelFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(8 * scale)
        .accessibilityElement(children: .combine)
    }
}
