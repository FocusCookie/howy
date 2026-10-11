import AppKit
import SwiftUI

/// The **?** examples of the due-date dialog, in their own small floating panel beside the Howy
/// panel, attached to it as a child window so they move and close together.
///
/// It never becomes key (nor main) and doesn't activate the app: Howy's panel closes when it
/// loses key status, so a click on an example must leave the keyboard where it is, in the
/// dialog's field. Clicks still reach the buttons (`acceptsFirstMouse`).
final class DueExamplesPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that takes the first click, so an example works without the panel being key.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows and places `DueExamplesPanel` beside a `FloatingPanel`'s card: to the right, or to the
/// left when the screen has no room there.
@MainActor
final class DueExamplesPanelController {
    private var panel: DueExamplesPanel?
    private var host: FirstClickHostingView?
    private weak var parent: NSWindow?

    private static let gap: CGFloat = 12
    private static let screenInset: CGFloat = 8

    func show<Content: View>(beside parent: FloatingPanel, scale: CGFloat, @ViewBuilder content: () -> Content) {
        let root = AnyView(content().environment(\.panelScale, scale))
        let panel = self.panel ?? DueExamplesPanel()
        if let host {
            host.rootView = root
        } else {
            let host = FirstClickHostingView(rootView: root)
            panel.contentView = host
            self.host = host
        }
        self.panel = panel
        guard let host else { return }
        let size = host.fittingSize
        let card = parent.cardFrame
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? card
        var x = card.maxX + Self.gap
        if x + size.width > visible.maxX - Self.screenInset {
            x = card.minX - Self.gap - size.width
        }
        x = max(x, visible.minX + Self.screenInset)
        let y = max(card.maxY - size.height, visible.minY + Self.screenInset)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height).integral, display: true)
        if self.parent !== parent {
            self.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
            self.parent = parent
        }
        panel.orderFront(nil) // never key: the dialog's field keeps the keyboard
    }

    func hide() {
        guard let panel else { return }
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
    }
}
