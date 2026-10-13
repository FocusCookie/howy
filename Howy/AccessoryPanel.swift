import AppKit
import SwiftUI

/// A small floating panel attached to the Howy panel as a child window, so they move and close
/// together: the due-date dialog's **?** examples beside the card, and the popover under a chip
/// at the caret, which may reach past the card's edge.
///
/// It never becomes key (nor main) and doesn't activate the app: Howy's panel closes when it
/// loses key status, so a click in it must leave the keyboard where it is (the dialog's field,
/// the note). Clicks still reach the buttons (`acceptsFirstMouse`).
final class AccessoryPanel: NSPanel {
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
final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows and places an `AccessoryPanel` with the examples beside a `FloatingPanel`'s card: to the right, or to the
/// left when the screen has no room there.
@MainActor
final class DueExamplesPanelController {
    private var panel: AccessoryPanel?
    private var host: FirstClickHostingView?
    private weak var parent: NSWindow?

    private static let gap: CGFloat = 12
    private static let screenInset: CGFloat = 8

    func show<Content: View>(beside parent: FloatingPanel, scale: CGFloat, @ViewBuilder content: () -> Content) {
        let root = AnyView(content().environment(\.panelScale, scale))
        let panel = self.panel ?? AccessoryPanel()
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

/// Shows the popover of the chip at the caret in an `AccessoryPanel` just under the chip, so it
/// can reach past the card's edge and sits above everything in it (the attachment strip).
/// Kept on screen; above the chip when there is no room under it.
@MainActor
final class ChipPopoverController {
    private var panel: AccessoryPanel?
    private var host: FirstClickHostingView?
    private weak var parent: NSWindow?

    private static let gap: CGFloat = 4
    private static let screenInset: CGFloat = 8
    /// Room for the popover's shadow inside its panel, at 100 %.
    private static let shadowRoom: CGFloat = 10

    /// `chip` is the chip's frame on screen.
    func show<Content: View>(under chip: CGRect, in parent: NSWindow, scale: CGFloat, @ViewBuilder content: () -> Content) {
        let inset = Self.shadowRoom * scale
        let root = AnyView(content().padding(inset).environment(\.panelScale, scale))
        let panel = self.panel ?? AccessoryPanel()
        panel.hasShadow = false // the popover draws its own
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
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        var x = chip.minX - inset
        x = min(x, visible.maxX - Self.screenInset - size.width)
        x = max(x, visible.minX + Self.screenInset)
        var y = chip.minY - Self.gap * scale - size.height + inset // under the chip (screen y points up)
        if y < visible.minY + Self.screenInset { y = chip.maxY + Self.gap * scale - inset }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height).integral, display: true)
        if self.parent !== parent {
            self.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
            self.parent = parent
        }
        panel.orderFront(nil) // never key: the note keeps the keyboard
    }

    func hide() {
        guard let panel else { return }
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
    }
}
