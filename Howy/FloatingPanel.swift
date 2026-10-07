import AppKit
import Quartz
import SwiftUI

/// Spotlight-style panel: borderless, non-activating, floating, on all spaces, centred on the
/// screen under the mouse. Closes itself when it loses key status for good.
///
/// The window is clear and shadowless; `PanelCard` draws the blurred card and its shadow.
/// A transparent margin around the card leaves room for that shadow and for the opening
/// scale-down (`PanelRoot`), so neither is clipped by the window frame.
///
/// The window has a fixed size: as wide as the card plus margin, and reaching from above the
/// card's top edge down to the bottom of the screen. The card sits at the top (`PanelRoot`) and
/// only *it* changes height when a screen is swapped or grows. Letting the SwiftUI content size
/// the window instead made the window's frame animation and the card's own animation run out of
/// step, which re-centred the card in the window every frame and made its top edge jump; see
/// `init` for why the hosting view sits behind a container view to keep SwiftUI from doing that.
/// Clicks on the transparent part fall through to whatever is beneath, as on any clear window.
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
    /// While above zero, losing key status doesn't close the panel (Quick Look, a file picker).
    private var holds = 0
    /// Feeds the Quick Look panel while this panel controls it.
    var previewSource: (any QLPreviewPanelDataSource & QLPreviewPanelDelegate)?
    /// Called when Quick Look stops being controlled by this panel (it closed).
    var onPreviewEnd: (() -> Void)?

    /// Resigns this soon after `present()` are treated as activation noise and undone.
    private static let graceInterval: TimeInterval = 0.6
    /// How long a resign must persist before the panel closes.
    private static let resignRecheckDelay: TimeInterval = 0.15
    /// Transparent space around the card for its shadow, the opening scale, and the done emoji's
    /// flight out past the right edge (`PanelEffects`).
    static let margin: CGFloat = 96
    private static let fadeOutDuration: TimeInterval = 0.12

    private let presentation = PanelPresentation()

    /// `width` is the card's width; the window is that plus the margin on both sides.
    init<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width + 2 * Self.margin, height: 200),
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
        host.sizingOptions = [] // the window keeps its frame; the card inside changes height
        // The hosting view must not be the window's content view. In an app that runs the SwiftUI
        // `App` lifecycle, an `NSHostingView` that *is* the content view animates the window's
        // frame along with its root view's size, whatever `sizingOptions` says (SwiftUI's
        // `animatesWindowRootSize`). Every card height change then resized the window from inside
        // AppKit's layout pass, and on macOS 26+ that feedback loop ends in an uncaught
        // "needs another Update Constraints pass" exception. Behind a plain container view the
        // hosting view sizes nothing but itself.
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizesSubviews = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Shows the panel centred horizontally, the card's top edge in the upper third of the
    /// active screen; the window extends to the bottom of that screen.
    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let width = frame.width
            let cardTop = visible.maxY - visible.height * 0.22
            let windowTop = cardTop + Self.margin
            let rect = NSRect(x: visible.midX - width / 2, y: visible.minY, width: width, height: windowTop - visible.minY)
            setFrame(rect.integral, display: false)
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

    /// The card's current frame on screen (the visible part of this mostly transparent window).
    var cardFrame: NSRect {
        guard let content = contentView else { return frame }
        let card = presentation.cardFrame // SwiftUI window coordinates: origin top-left
        let inWindow = NSRect(x: card.minX, y: content.bounds.height - card.maxY, width: card.width, height: card.height)
        return convertToScreen(inWindow)
    }

    override func sendEvent(_ event: NSEvent) {
        if didClose { return } // fading out: nothing may change behind the fade
        if event.type == .keyDown, !isComposingText, keyHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }

    /// Keeps the panel open while another window (Quick Look, a file picker) has key status.
    func holdOpen() {
        holds += 1
    }

    /// Ends a `holdOpen()`. The last one takes key status back, or closes the panel when focus
    /// has gone elsewhere in the meantime (like any focus loss).
    func releaseHold() {
        guard holds > 0 else { return }
        holds -= 1
        guard holds == 0, !didClose else { return }
        makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resignRecheckDelay) { [weak self] in
            guard let self, !self.didClose, self.holds == 0, !self.isKeyWindow else { return }
            self.closeForFocusLoss()
        }
    }

    // MARK: Focus loss

    /// Watches the mouse after a click in another app: that may be the start of dragging a file
    /// onto the panel (from Finder, a screenshot thumbnail, …).
    private var mouseMonitor: Any?
    private var mouseDragged = false

    /// Closes the panel because focus went elsewhere, unless the mouse button is down in another
    /// app: then it waits for the release. A drag that ends over the panel keeps it open (the drop
    /// lands there) and takes key status back; a plain click elsewhere closes it on release.
    private func closeForFocusLoss() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            closedByFocusLoss = true
            dismiss()
            return
        }
        guard mouseMonitor == nil else { return }
        mouseDragged = false
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.watchedMouse(event) }
        }
    }

    private func watchedMouse(_ event: NSEvent) {
        if event.type == .leftMouseDragged {
            mouseDragged = true
            return
        }
        stopWatchingMouse()
        guard !didClose, !isKeyWindow, holds == 0 else { return }
        if mouseDragged, NSMouseInRect(NSEvent.mouseLocation, cardFrame, false) {
            // Dropped on the panel: let the drop finish, then take the keyboard back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, !self.didClose, !self.isKeyWindow else { return }
                self.makeKey()
            }
        } else {
            closedByFocusLoss = true
            dismiss()
        }
    }

    private func stopWatchingMouse() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        previewSource != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = previewSource
        panel.delegate = previewSource
        panel.currentPreviewItemIndex = 0 // the source lists the chosen file first
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        previewSource = nil
        let end = onPreviewEnd
        onPreviewEnd = nil
        end?()
    }

    override func becomeKey() {
        super.becomeKey()
        stopWatchingMouse()
    }

    override func resignKey() {
        super.resignKey()
        guard !didClose, holds == 0 else { return }
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
            self.closeForFocusLoss()
        }
    }

    /// True while the panel is on screen and not closing, so new content can move into it.
    var canReplaceContent: Bool { isVisible && !didClose && presentation.state == .shown }

    /// Swaps in another screen (e.g. Browse → edit → Browse) inside the same card: the card resizes
    /// and the contents cross-fade, instead of one panel fading out and a new one zooming in.
    /// The height change uses a bounce-free curve: a spring with bounce would overshoot by an amount
    /// that grows with the height difference, so big swaps (edit → list) would settle visibly.
    /// The previous screen's `willClose` runs first; `keyHandler` is cleared for the caller to set.
    func replaceContent<Content: View>(@ViewBuilder _ content: () -> Content) {
        willClose?()
        willClose = nil
        keyHandler = nil
        let view = AnyView(content())
        withAnimation(Self.reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.26)) {
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
        stopWatchingMouse()
        if previewSource != nil, QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
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
    /// Where the card is inside the window (SwiftUI's window space), kept up to date by `PanelRoot`.
    var cardFrame = CGRect.zero
    /// Decorations drawn over the window, outside the card (the done emoji).
    let effects = PanelEffects()
}

extension EnvironmentValues {
    /// Where the enclosing panel is in its open/close animation (`.shown` outside panels).
    @Entry var panelState: PanelPresentation.State = .shown
}

/// The panel's root: one card for every screen the panel shows, pinned to the top of the (taller,
/// transparent) window, with a Spotlight-style entrance (fade in while settling from a slight
/// zoom; fade only with Reduce Motion) and a quick fade out. Screens swapped by `replaceContent`
/// cross-fade, top-aligned, while the card animates to the new height; the window stays put.
private struct PanelRoot: View {
    let presentation: PanelPresentation
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PanelCard {
            ZStack(alignment: .top) {
                presentation.content
                    .id(presentation.contentID)
                    // A plain cross-fade, like changes within a screen (quadrants → list). Zooming the
                    // incoming screen re-rasterised its text at sub-pixel offsets every frame, which
                    // made it shimmer by a pixel until the animation settled.
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
            .frame(width: width)
            .environment(\.panelState, presentation.state)
            .environment(\.panelEffects, presentation.effects)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { presentation.cardFrame = $0 }
            .scaleEffect(scale)
            .opacity(presentation.state == .shown ? 1 : 0)
            .padding(FloatingPanel.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay { PanelEffectsLayer(effects: presentation.effects) } // window space, unclipped
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
            // While the card grows to a taller screen, the new screen is laid out at its full height
            // already; without this it would show below the card's edge until the card catches up.
            .clipShape(Self.shape)
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
