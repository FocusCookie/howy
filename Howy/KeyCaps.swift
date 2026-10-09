import HowyCore
import SwiftUI

/// A key drawn as a keycap: neutral grey in every panel and both appearances (a coloured cap on a
/// coloured tile was hard to read), like the `A` on Browse's Archive button.
struct KeyCap: View {
    let text: String
    var font: Font = .caption2.weight(.semibold)
    var minSize: CGFloat = 18

    var body: some View {
        Text(text)
            .font(font.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: minSize, minHeight: minSize)
            .padding(.horizontal, text.count > 1 ? 4 : 0)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A footer line of keyboard hints with the keys as keycaps: "⌘↩ save · esc close" becomes
/// [⌘][↩] save  [esc] close (`KeyHint` says what counts as a key). With `short`, that variant is
/// shown when the full one doesn't fit the footer.
struct KeyHints: View {
    let hint: String
    var short: String?

    init(_ hint: String, short: String? = nil) {
        self.hint = hint
        self.short = short
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(hint)
            if let short { line(short) }
        }
        .font(.caption)
        .lineLimit(1)
        // A different hint is a new line, not the old keycaps sliding to new places.
        .id(short.map { hint + $0 } ?? hint)
    }

    private func line(_ hint: String) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(KeyHint.items(in: hint).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    ForEach(Array(item.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .key(let text): KeyCap(text: text)
                        case .text(let text): Text(text).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }
}
