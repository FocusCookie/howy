import HowyCore
import SwiftUI

/// The single-shortcut launcher: "New Todo" and "Browse" side by side. A thin view over
/// `LauncherFlow`; keys arrive via `FloatingPanel.keyHandler`.
struct LauncherView: View {
    let flow: LauncherFlow
    let onOpen: (LauncherChoice) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(LauncherChoice.allCases, id: \.self) { tile($0) }
            }
            HStack {
                Spacer()
                Text("←→ or 1–2 · ↩ open · esc close")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    private func tile(_ choice: LauncherChoice) -> some View {
        let isHighlighted = flow.highlighted == choice
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: choice.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title).font(.headline)
                Text(choice.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("\(choice.shortcutNumber)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(fill(isHighlighted), in: shape)
        .overlay(shape.strokeBorder(Color.accentColor.opacity(isHighlighted ? 0.7 : 0), lineWidth: 1.5))
        .scaleEffect(isHighlighted && !reduceMotion ? 1.015 : 1)
        .animation(.snappy(duration: 0.22), value: isHighlighted)
        .contentShape(shape)
        .onTapGesture { onOpen(choice) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    private func fill(_ isHighlighted: Bool) -> Color {
        if isHighlighted { return Color.accentColor.opacity(isDark ? 0.22 : 0.12) }
        return isDark ? .white.opacity(0.06) : .black.opacity(0.04)
    }
}

private extension LauncherChoice {
    var title: String {
        switch self {
        case .create: "New Todo"
        case .browse: "Browse"
        }
    }

    var subtitle: String {
        switch self {
        case .create: "Add a todo to a quadrant"
        case .browse: "See and tick off open todos"
        }
    }

    var symbol: String {
        switch self {
        case .create: "square.and.pencil"
        case .browse: "square.grid.2x2"
        }
    }
}
