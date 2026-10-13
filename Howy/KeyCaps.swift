import HowyCore
import SwiftUI

/// A key drawn as a keycap: neutral grey in every panel and both appearances (a coloured cap on a
/// coloured tile was hard to read), like the `A` on Browse's Archive button.
/// In a panel the cap, its text and `minSize` grow with the panel zoom (`\.panelScale`); `font`
/// (Settings' shortcut fields) is used as given, at 100 %.
/// `prominent` (on a material, like the position picker) draws the cap with plain colours that
/// stay readable there: the hierarchical `.secondary` turns faint on a material in dark mode.
struct KeyCap: View {
    let text: String
    var font: Font?
    var minSize: CGFloat = 18
    var prominent = false
    @Environment(\.panelScale) private var scale

    var body: some View {
        Text(text)
            .font((font ?? .panel(.caption2, scale: scale, weight: .semibold)).monospacedDigit())
            .foregroundStyle(prominent ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
            .frame(minWidth: minSize * scale, minHeight: minSize * scale)
            .padding(.horizontal, text.count > 1 ? 4 * scale : 0)
            .background(Color.primary.opacity(prominent ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 4 * scale, style: .continuous))
    }
}

/// A footer line of keyboard hints with the keys as keycaps: "⌘↩ save · esc close" becomes
/// [⌘][↩] save  [esc] close (`KeyHint` says what counts as a key). With `short`, that variant is
/// shown when the full one doesn't fit the footer. When neither fits, hints are dropped from the
/// end until the line fits: a line wider than the footer would widen the whole panel.
/// `prominent` draws the keys and labels with plain colours that stay readable on a material
/// (the position picker); the default's `.tertiary` labels are meant for the card's footer.
struct KeyHints: View {
    let hint: String
    var short: String?
    var prominent: Bool
    @Environment(\.panelScale) private var scale

    init(_ hint: String, short: String? = nil, prominent: Bool = false) {
        self.hint = hint
        self.short = short
        self.prominent = prominent
    }

    var body: some View {
        let full = KeyHint.items(in: hint)
        let last = short.map(KeyHint.items(in:)) ?? full
        ViewThatFits(in: .horizontal) {
            line(full)
            if short != nil { line(last) }
            ForEach((0..<last.count).reversed(), id: \.self) { count in
                line(Array(last.prefix(count)))
            }
        }
        .panelFont(.caption)
        .lineLimit(1)
        // A different hint is a new line, not the old keycaps sliding to new places.
        .id(short.map { hint + $0 } ?? hint)
    }

    private func line(_ items: [[KeyHint.Part]]) -> some View {
        HStack(spacing: 10 * scale) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4 * scale) {
                    ForEach(Array(item.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .key(let text): KeyCap(text: text, prominent: prominent)
                        case .text(let text):
                            Text(text).foregroundStyle(prominent ? AnyShapeStyle(Color.primary.opacity(0.85)) : AnyShapeStyle(.tertiary))
                        }
                    }
                }
            }
        }
        .fixedSize()
    }
}
