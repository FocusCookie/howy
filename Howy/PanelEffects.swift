import HowyCore
import SwiftUI

/// Short-lived decorations drawn over the whole panel window, outside the card's clip: the emoji
/// that flies off to the right when a todo is marked done. Screens reach it through the
/// environment (`\.panelEffects`); `PanelRoot` draws `PanelEffectsLayer` above the card.
@MainActor
@Observable
final class PanelEffects {
    struct Flight: Identifiable {
        let id = UUID()
        let emoji: String
        /// Where it starts, in the window's SwiftUI coordinates (origin top-left).
        let start: CGPoint
    }

    private(set) var flights: [Flight] = []

    /// Launches `emoji` from `start` (window coordinates); it removes itself when the flight ends.
    func launch(_ emoji: String, from start: CGPoint) {
        let flight = Flight(emoji: emoji, start: start)
        flights.append(flight)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DoneEmojiView.duration + 0.15))
            self?.flights.removeAll { $0.id == flight.id }
        }
    }
}

extension EnvironmentValues {
    /// The enclosing panel's effects layer; `nil` outside a panel.
    @Entry var panelEffects: PanelEffects?
}

/// Draws the flights over the window. Never in the way of the pointer or accessibility.
struct PanelEffectsLayer: View {
    let effects: PanelEffects
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ForEach(effects.flights) { flight in
                // Fly to just inside the window's right edge: the card ends `margin` before it, so
                // the emoji leaves the card and fades in the transparent space beside it.
                DoneEmojiView(emoji: flight.emoji, travel: reduceMotion ? 0 : geometry.size.width - 16 - flight.start.x)
                    .position(flight.start)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One emoji shooting out to the right when a todo is marked done: it pops, flies off with the
/// row and keeps going past the card's edge, fading out there. Plays once, on appear.
struct DoneEmojiView: View {
    let emoji: String
    /// How far it flies to the right; 0 just pops and fades in place (reduce motion).
    let travel: CGFloat

    static let duration: TimeInterval = 0.85

    @State private var launched = false

    private struct Flight {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var scale: CGFloat = 0.3
        var opacity: Double = 1
        var rotation: Angle = .zero
    }

    var body: some View {
        Text(emoji)
            .font(.system(size: 28))
            .keyframeAnimator(initialValue: Flight(), trigger: launched) { view, flight in
                view
                    .scaleEffect(flight.scale)
                    .rotationEffect(flight.rotation)
                    .opacity(flight.opacity)
                    .offset(x: flight.x, y: flight.y)
            } keyframes: { _ in
                // Pop in place first, then accelerate out to the right.
                KeyframeTrack(\.x) {
                    CubicKeyframe(travel * 0.08, duration: 0.2)
                    CubicKeyframe(travel, duration: 0.65)
                }
                KeyframeTrack(\.y) {
                    CubicKeyframe(-14, duration: 0.3)
                    CubicKeyframe(16, duration: 0.55)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.5, duration: 0.25, spring: .bouncy)
                    CubicKeyframe(1.1, duration: 0.6)
                }
                KeyframeTrack(\.opacity) {
                    // Fully visible while crossing the card; gone by the window's edge.
                    LinearKeyframe(1, duration: 0.6)
                    LinearKeyframe(0, duration: 0.25)
                }
                KeyframeTrack(\.rotation) {
                    CubicKeyframe(.degrees(travel == 0 ? 0 : 40), duration: 0.85)
                }
            }
            .onAppear { launched = true }
    }
}
