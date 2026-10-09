import HowyCore
import SwiftUI

/// Short-lived decorations drawn over the whole panel window, outside the card: the emoji that
/// rises out of the card's top edge when a todo is marked done, the confetti that sprays
/// up from that edge in a V around it, and the glass badge that rises the same way when a todo
/// moves to another quadrant ("↗ Moved to ● Urgent & Important"). Screens reach it through the environment (`\.panelEffects`);
/// `PanelRoot` draws `PanelEffectsLayer` above the card, masked to the space around it, so a
/// flight starts hidden "behind" the card and shows as it leaves.
@MainActor
@Observable
final class PanelEffects {
    struct Flight: Identifiable {
        let id = UUID()
        let emoji: String
        /// Where it rises, horizontally, in the window's SwiftUI coordinates (origin top-left).
        let x: CGFloat
        /// Whether it pops a confetti burst as it clears the card (the Settings choice).
        let confetti: Bool
    }

    /// A "moved to another quadrant" badge on its way up.
    struct Badge: Identifiable {
        let id = UUID()
        /// "Moved to" or "Back to".
        let verb: String
        let quadrant: Quadrant
    }

    private(set) var flights: [Flight] = []
    private(set) var badges: [Badge] = []

    /// Launches `emoji` up out of the card's top edge at `x` (window coordinates); it removes
    /// itself when the flight ends. Does nothing when the done animation is switched off.
    func launch(_ emoji: String, atX x: CGFloat) {
        let style = DoneAnimation.load()
        guard style.showsEmoji else { return }
        let flight = Flight(emoji: emoji, x: x, confetti: style.showsConfetti)
        flights.append(flight)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DoneEmojiView.duration + 0.15))
            self?.flights.removeAll { $0.id == flight.id }
        }
    }

    /// Sends a "`verb` ● quadrant" badge up out of the card's top edge, centred over it; it
    /// removes itself when it has faded. Feedback rather than decoration, so the done-animation
    /// setting doesn't switch it off.
    func launchBadge(_ verb: String, quadrant: Quadrant) {
        let badge = Badge(verb: verb, quadrant: quadrant)
        badges.append(badge)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(MoveBadgeView.duration + 0.15))
            self?.badges.removeAll { $0.id == badge.id }
        }
    }
}

extension EnvironmentValues {
    /// The enclosing panel's effects layer; `nil` outside a panel.
    @Entry var panelEffects: PanelEffects?
}

/// Draws the flights over the window, everywhere but over the card: a flight starts just inside
/// the card's top edge, so it is hidden until it rises past it. Never in the way of the pointer
/// or accessibility.
struct PanelEffectsLayer: View {
    let effects: PanelEffects
    /// The card, in the window's SwiftUI coordinates.
    let card: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(effects.flights) { flight in
                // Fired from the card's top edge, where the emoji comes out; the flecks fan up
                // and outwards on both sides of it.
                if flight.confetti, !reduceMotion {
                    ConfettiBurstView()
                        .position(x: flight.x, y: card.minY)
                }
                // With Reduce Motion it only pops and fades, so it sits above the card from the start.
                DoneEmojiView(emoji: flight.emoji, travel: reduceMotion ? 0 : DoneEmojiView.travel)
                    .position(x: flight.x, y: reduceMotion ? card.minY - DoneEmojiView.size * 0.6 : card.minY + DoneEmojiView.hideDepth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask {
            Rectangle()
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: FloatingPanel.cardCornerRadius, style: .continuous)
                        .frame(width: card.width, height: card.height)
                        .offset(x: card.minX, y: card.minY)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
        .overlay(alignment: .top) { badgeLayer }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The move badges, clipped to the window above the card's top edge: a badge starts below
    /// that edge, so it is hidden until it rises out. (A plain clip instead of the flights' mask:
    /// the badge's material is a platform view, which a compositing mask may not render. The
    /// card's top edge is straight where the badge comes out, so a rectangle is exact there.)
    private var badgeLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(effects.badges) { badge in
                MoveBadgeView(verb: badge.verb, quadrant: badge.quadrant, travel: reduceMotion ? 0 : MoveBadgeView.travel)
                    .position(x: card.midX, y: reduceMotion ? card.minY - MoveBadgeView.restingHeight : card.minY + MoveBadgeView.hideDepth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: max(card.minY, 0), alignment: .top)
        .clipped()
    }
}

/// A small glass badge saying where a todo just went ("↗ Moved to ● Not Urgent & Important",
/// "↗ Back to ● …" on ⌘Z), with a dot and a faint glow in that quadrant's colour. It rises out
/// of the card's top edge like the done emoji: growing from 0.7 to full size as it clears the
/// edge, then drifting on up and fading. With `travel` 0 (Reduce Motion) it only fades in and
/// out where it is. Plays once, on appear.
struct MoveBadgeView: View {
    let verb: String
    let quadrant: Quadrant
    /// How far it rises; 0 fades in and out in place.
    let travel: CGFloat

    static let duration: TimeInterval = 0.95
    /// How far it rises in all (from `hideDepth` below the edge to about 60 pt above it).
    static let travel: CGFloat = 78
    /// How far below the card's top edge its centre starts: just hidden.
    static let hideDepth: CGFloat = 16
    /// Where it sits above the edge with Reduce Motion (its centre, above the edge).
    static let restingHeight: CGFloat = 30

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.panelScale) private var panelScale
    @State private var launched = false

    private struct Motion {
        var y: CGFloat = 0
        var scale: CGFloat = 0.7
        var opacity: Double = 1
    }

    var body: some View {
        if travel == 0 {
            badge.keyframeAnimator(initialValue: 0.0, trigger: launched) { view, opacity in
                view.opacity(opacity)
            } keyframes: { _ in
                LinearKeyframe(1, duration: Self.duration * 0.2)
                LinearKeyframe(1, duration: Self.duration * 0.35)
                LinearKeyframe(0, duration: Self.duration * 0.45)
            }
            .onAppear { launched = true }
        } else {
            badge.keyframeAnimator(initialValue: Motion(), trigger: launched) { view, motion in
                view
                    .scaleEffect(motion.scale)
                    .opacity(motion.opacity)
                    .offset(y: motion.y)
            } keyframes: { _ in
                // Out of the card fast, then drift the rest of the way (like the done emoji).
                KeyframeTrack(\.y) {
                    CubicKeyframe(-travel * 0.6, duration: Self.duration * 0.35)
                    CubicKeyframe(-travel, duration: Self.duration * 0.65)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1, duration: Self.duration * 0.35, spring: .snappy)
                    CubicKeyframe(1, duration: Self.duration * 0.65)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: Self.duration * 0.55)
                    LinearKeyframe(0.9, duration: Self.duration * 0.15)
                    LinearKeyframe(0, duration: Self.duration * 0.3)
                }
            }
            .onAppear { launched = true }
        }
    }

    private var isDark: Bool { colorScheme == .dark }

    /// The badge is text, so it follows the panel zoom (unlike the done emoji, an effect that
    /// keeps its size); its flight path stays the same.
    private var badge: some View {
        let shape = RoundedRectangle(cornerRadius: 8 * panelScale, style: .continuous)
        return HStack(spacing: 6 * panelScale) {
            Text("↗").foregroundStyle(.secondary)
            Text(verb)
            Circle().fill(quadrant.color).frame(width: 8 * panelScale, height: 8 * panelScale)
            Text(quadrant.displayName)
        }
        .panelFont(size: 12, weight: .medium)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10 * panelScale)
        .padding(.vertical, 5 * panelScale)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                // A veil so it still reads as glass where there is little behind it to blur.
                shape.fill(isDark ? Color(white: 0.2).opacity(0.55) : .white.opacity(0.55))
                shape.fill(quadrant.color.opacity(isDark ? 0.22 : 0.14))
            }
        }
        .overlay {
            // Hairline edge with a brighter top, like light catching the glass.
            shape.strokeBorder(
                LinearGradient(
                    colors: isDark ? [.white.opacity(0.28), .white.opacity(0.10)] : [.white.opacity(0.9), .black.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .shadow(color: quadrant.color.opacity(isDark ? 0.45 : 0.3), radius: 8) // soft glow
        .shadow(color: .black.opacity(isDark ? 0.3 : 0.14), radius: 9, y: 5)
    }
}

/// One emoji rising out of the top of the card when a todo is marked done, in step with the row
/// flying up: small at first, it grows to `size` as it clears the edge, slows and fades out
/// above the card. Plays once, on appear.
struct DoneEmojiView: View {
    let emoji: String
    /// How far it rises; 0 just pops and fades in place (reduce motion).
    let travel: CGFloat

    static let duration: TimeInterval = 0.8
    /// Its full size, reached as it clears the card.
    static let size: CGFloat = 64
    /// How far it rises out of the card (`FloatingPanel.margin` leaves room for it).
    static let travel: CGFloat = 108
    /// How far below the card's top edge it starts, hidden by the layer's mask.
    static let hideDepth: CGFloat = 20

    @State private var launched = false

    private struct Flight {
        var y: CGFloat = 0
        var scale: CGFloat = 0.3
        var opacity: Double = 1
    }

    var body: some View {
        Text(emoji)
            .font(.system(size: Self.size))
            .keyframeAnimator(initialValue: Flight(), trigger: launched) { view, flight in
                view
                    .scaleEffect(flight.scale)
                    .opacity(flight.opacity)
                    .offset(y: flight.y)
            } keyframes: { _ in
                // Shoot up with the row, then drift the rest of the way.
                KeyframeTrack(\.y) {
                    CubicKeyframe(-travel * 0.75, duration: 0.3)
                    CubicKeyframe(-travel, duration: 0.5)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                    CubicKeyframe(1, duration: 0.4)
                }
                KeyframeTrack(\.opacity) {
                    // Fully visible while leaving the card; gone before it reaches the window's edge.
                    LinearKeyframe(1, duration: 0.45)
                    LinearKeyframe(0, duration: 0.35)
                }
            }
            .onAppear { launched = true }
    }
}

/// A confetti burst fired from the card's top edge as the done emoji comes out of it: the flecks
/// shoot up and outwards in two arms, a V with the emoji rising in the gap, then arc down and
/// fade. Deliberately modest — a wink, not a parade — so it never fights the emoji for attention.
/// Plays once, on appear; `lead` holds it until the emoji's top has reached the edge.
struct ConfettiBurstView: View {
    /// How long the flecks wait for the emoji to reach the edge.
    static let lead: TimeInterval = 0.08
    /// How long a fleck flies once it is out.
    static let fly: TimeInterval = 0.62
    private static let count = 18
    /// The V's arms: this far off straight up, on either side, give or take `armSpread`.
    private static let armAngle: Double = 42
    private static let armSpread: Double = 16
    private static let palette: [Color] = [.red, .orange, .blue, .green, .pink, .yellow, .purple, .mint]

    /// One fleck's shape and path, drawn once so it stays put across view updates.
    private struct Fleck: Identifiable {
        let id = UUID()
        /// Where it flies, as a unit vector (SwiftUI's y grows downwards).
        let direction: CGVector
        /// How far along that direction it gets.
        let distance: CGFloat
        /// How far gravity pulls it down by the end.
        let drop: CGFloat
        let size: CGSize
        let color: Color
        /// Degrees it tumbles through.
        let spin: Double
        /// A touch of stagger, so they don't all leave at once.
        let jitter: TimeInterval

        static func burst() -> [Fleck] {
            (0..<ConfettiBurstView.count).map { i in
                // Alternate sides so both arms of the V get the same number of flecks.
                let side: Double = i.isMultiple(of: 2) ? 1 : -1
                let degrees = -90 + side * (ConfettiBurstView.armAngle + .random(in: -ConfettiBurstView.armSpread...ConfettiBurstView.armSpread))
                let angle = degrees * .pi / 180
                return Fleck(
                    direction: CGVector(dx: cos(angle), dy: sin(angle)),
                    distance: .random(in: 70...130),
                    drop: .random(in: 36...64),
                    size: CGSize(width: .random(in: 3...5), height: .random(in: 6...10)),
                    color: ConfettiBurstView.palette.randomElement() ?? .orange,
                    spin: .random(in: 180...540) * (Bool.random() ? 1 : -1),
                    jitter: .random(in: 0...0.06)
                )
            }
        }
    }

    @State private var flecks = Fleck.burst()
    @State private var fired = false

    private struct Motion {
        /// How far along its direction the fleck has travelled, 0...1 (a little past 1 as it drifts).
        var spread: CGFloat = 0
        var fall: CGFloat = 0
        var scale: CGFloat = 0.4
        var opacity: Double = 0
        var rotation: Double = 0
    }

    var body: some View {
        ZStack {
            ForEach(flecks) { fleck in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(fleck.color)
                    .frame(width: fleck.size.width, height: fleck.size.height)
                    .keyframeAnimator(initialValue: Motion(), trigger: fired) { view, motion in
                        view
                            .scaleEffect(motion.scale)
                            .opacity(motion.opacity)
                            .rotationEffect(.degrees(motion.rotation))
                            .offset(
                                x: fleck.direction.dx * fleck.distance * motion.spread,
                                y: fleck.direction.dy * fleck.distance * motion.spread + motion.fall
                            )
                    } keyframes: { _ in
                        let lead = Self.lead + fleck.jitter
                        KeyframeTrack(\.spread) {
                            LinearKeyframe(0, duration: lead) // waiting behind the card's edge
                            CubicKeyframe(0.85, duration: 0.3) // out of the cannon, fast
                            CubicKeyframe(1.05, duration: 0.32) // easing out
                        }
                        KeyframeTrack(\.fall) {
                            LinearKeyframe(0, duration: lead)
                            CubicKeyframe(fleck.drop * 0.1, duration: 0.3)
                            CubicKeyframe(fleck.drop, duration: 0.32) // gravity catches up
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.4, duration: lead)
                            SpringKeyframe(1, duration: 0.2, spring: .bouncy)
                            CubicKeyframe(0.85, duration: 0.42)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: lead)
                            LinearKeyframe(1, duration: 0.02)
                            LinearKeyframe(1, duration: 0.34)
                            LinearKeyframe(0, duration: 0.26)
                        }
                        KeyframeTrack(\.rotation) {
                            LinearKeyframe(0, duration: lead)
                            LinearKeyframe(fleck.spin, duration: Self.fly)
                        }
                    }
            }
        }
        .onAppear { fired = true }
    }
}
