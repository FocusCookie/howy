import AppKit
import SwiftUI

/// Spotlight-style panel: borderless, non-activating, floating, on all spaces, centred on the
/// screen under the mouse. Closes itself when it loses key status for good.
///
/// The window is clear and shadowless; `PanelCard` draws the blurred card and its shadow.
/// A transparent margin around the card leaves room for that shadow and for the opening
/// scale-down (`PanelRoot`), so neither is clipped by the window frame.
///
/// Losing key status is not always the user clicking away: activating the app, a menu closing or
/// a widget host handing over focus all take it away briefly. So resigns shortly after `present()`
/// are undone, and later ones only close the panel if it is still not key after a short delay.
final class FloatingPanel: NSPanel {
    /// Called for every key-down before the focused control sees it. Return `true` to consume it.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Called once when the panel goes away (Esc, save, resign key, or replaced by another panel).
    var onClose: (() -> Void)?
    /// Called once just before `onClose`, while the content's model is still current
    /// (e.g. to stash an unsaved draft).
    var willClose: (() -> Void)?

    /// True when the panel closed because focus went elsewhere (not Esc / save / replaced).
    private(set) var closedByFocusLoss = false

    private var didClose = false
    private var presentedAt: Date?

    /// Resigns this soon after `present()` are treated as activation noise and undone.
    private static let graceInterval: TimeInterval = 0.6
    /// How long a resign must persist before the panel closes.
    private static let resignRecheckDelay: TimeInterval = 0.15
    /// Transparent space around the card for its shadow and the opening scale.
    static let margin: CGFloat = 56
    private static let fadeOutDuration: TimeInterval = 0.12

    private let presentation = PanelPresentation()

    init<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // the card draws its own, matching its rounded glass shape
        animationBehavior = .none // PanelRoot animates in and out

        presentation.content = AnyView(content())
        let host = NSHostingView(rootView: PanelRoot(presentation: presentation, width: width))
        host.sizingOptions = [.preferredContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Shows the panel centred horizontally, its top edge in the upper third of the active screen.
    func present() {
        layoutIfNeeded()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = frame.size
            let top = visible.maxY - visible.height * 0.22 + Self.margin // the card's top edge
            setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: top - size.height))
        }
        presentedAt = Date()
        makeKeyAndOrderFront(nil)
        // Next turn, so the first frame is drawn in the hidden state and the change animates.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didClose else { return }
            withAnimation(Self.reduceMotion ? .easeOut(duration: 0.18) : .snappy(duration: 0.24)) {
                self.presentation.state = .shown
            }
        }
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Keeps the top edge fixed when the SwiftUI content changes height.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, rect.size.height != frame.size.height {
            rect.origin.y = frame.maxY - rect.size.height
        }
        super.setFrame(rect, display: flag)
    }

    override func sendEvent(_ event: NSEvent) {
        if didClose { return } // fading out: nothing may change behind the fade
        if event.type == .keyDown, !isComposingText, keyHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        guard !didClose else { return }
        let sincePresent = presentedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        log.notice("""
            Panel resigned key after \(sincePresent, format: .fixed(precision: 3), privacy: .public)s; \
            appActive=\(NSApp.isActive, privacy: .public) \
            keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none", privacy: .public) \
            frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none", privacy: .public)
            """)
        if sincePresent < Self.graceInterval {
            // Activation noise: take key status back instead of closing.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didClose, !self.isKeyWindow else { return }
                self.makeKey()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resignRecheckDelay) { [weak self] in
            guard let self, !self.didClose, !self.isKeyWindow else { return }
            self.closedByFocusLoss = true
            self.dismiss()
        }
    }

    /// True while the panel is on screen and not closing, so new content can move into it.
    var canReplaceContent: Bool { isVisible && !didClose && presentation.state == .shown }

    /// Swaps in another screen (e.g. Browse → edit → Browse) inside the same card: the card resizes
    /// and the contents cross-fade, instead of one panel fading out and a new one zooming in.
    /// The previous screen's `willClose` runs first; `keyHandler` is cleared for the caller to set.
    func replaceContent<Content: View>(@ViewBuilder _ content: () -> Content) {
        willClose?()
        willClose = nil
        keyHandler = nil
        let view = AnyView(content())
        withAnimation(Self.reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.26)) {
            presentation.content = view
            presentation.contentID += 1
        }
    }

    /// Collapses a select-all in the focused text field to a caret at the end (edit mode keeps the text).
    func moveCaretToEnd() {
        guard let editor = firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    /// Closes the panel: callbacks run now, the window fades out quickly and is then removed.
    func dismiss() {
        guard !didClose else { return }
        didClose = true
        keyHandler = nil
        ignoresMouseEvents = true
        willClose?()
        willClose = nil
        onClose?()
        onClose = nil
        guard isVisible else {
            orderOut(nil)
            close()
            return
        }
        withAnimation(.easeIn(duration: Self.fadeOutDuration)) {
            presentation.state = .closing
        }
        // Strong capture: nothing else may hold the panel any more, and it must live until it's off screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutDuration) {
            self.orderOut(nil)
            self.close()
        }
    }

    /// True while an input method has uncommitted (marked) text, so Enter/Esc belong to the IME.
    private var isComposingText: Bool {
        (firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
}

/// Drives the open/close animation of a panel's content.
@MainActor
@Observable
final class PanelPresentation {
    enum State { case hidden, shown, closing }
    var state: State = .hidden
    /// The current screen; `contentID` changes with it so the swap is a transition.
    var content = AnyView(EmptyView())
    var contentID = 0
}

extension EnvironmentValues {
    /// Where the enclosing panel is in its open/close animation (`.shown` outside panels).
    @Entry var panelState: PanelPresentation.State = .shown
}

/// The panel's root: one card for every screen the panel shows, Spotlight-style entrance (fade in
/// while settling from a slight zoom; fade only with Reduce Motion) and a quick fade out, inside
/// the transparent window margin. Screens swapped by `replaceContent` cross-fade, top-aligned,
/// while the card animates to the new height.
private struct PanelRoot: View {
    let presentation: PanelPresentation
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PanelCard {
            ZStack(alignment: .top) {
                presentation.content
                    .id(presentation.contentID)
                    .transition(screenTransition)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
            .frame(width: width)
            .environment(\.panelState, presentation.state)
            .scaleEffect(scale)
            .opacity(presentation.state == .shown ? 1 : 0)
            .padding(FloatingPanel.margin)
    }

    /// The incoming screen settles from a hair larger, the outgoing one fades on its own.
    private var screenTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 1.01, anchor: .top)),
            removal: .opacity
        )
    }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        switch presentation.state {
        case .hidden: return 1.05
        case .shown: return 1
        case .closing: return 0.98
        }
    }
}

/// The rounded card every panel's screens sit on (drawn once by `PanelRoot`), with a soft shadow.
///
/// Raycast-style rather than Liquid Glass: Liquid Glass lets the desktop show through and refracts
/// it, which washes out in light mode over busy windows. Here the backdrop is blurred heavily and
/// mostly covered by a near-opaque fill, so only a hint of colour comes through in either mode.
struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content

    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        content
            .padding(16)
            .background { PanelBackground(shape: Self.shape) }
            .background { PanelShadow(shape: Self.shape) }
    }
}

/// Blurred backdrop + near-opaque fill + hairline edge (a light inner highlight in dark mode).
private struct PanelBackground: View {
    let shape: RoundedRectangle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            BackdropBlur()
            shape.fill(fill)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(edge, lineWidth: 1) }
    }

    private var isDark: Bool { colorScheme == .dark }
    private var fill: Color { isDark ? Color(white: 0.11).opacity(0.80) : Color(white: 0.985).opacity(0.84) }
    private var edge: Color { isDark ? .white.opacity(0.12) : .black.opacity(0.10) }
}

/// Behind-window blur of whatever is under the panel.
private struct BackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A drop shadow drawn only *outside* the shape, so it doesn't darken the translucent glass.
private struct PanelShadow: View {
    let shape: RoundedRectangle

    var body: some View {
        shape
            .fill(.black)
            .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
            .mask {
                Rectangle()
                    .padding(-FloatingPanel.margin)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}
