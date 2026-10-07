import AppKit
import Carbon.HIToolbox
import HowyCore
import KeyboardShortcuts
import SwiftUI

/// Records a global shortcut for Settings. Replaces `KeyboardShortcuts.Recorder`, whose search
/// field refuses focus right after its window becomes key (so clicks were often lost) and which
/// records fn as a modifier (shown as 🌐, and such hotkeys don't fire).
///
/// Click a field to listen; held modifiers show live; the first key with ⌘, ⌃ or ⌥ (or an F-key)
/// is stored. Esc cancels, Delete clears, clicking anywhere else stops. All global shortcuts are
/// paused while listening, so pressing the current one records it instead of opening a panel.
/// Quick Add and Browse must differ; the launcher is alone in its mode, so it may reuse either.
@MainActor
@Observable
final class ShortcutRecorderModel {
    static let names: [KeyboardShortcuts.Name] = [.quickAdd, .browse, .launcher]

    /// The shortcuts active alongside `name` (in the same shortcut mode), which it must not equal.
    static func peers(of name: KeyboardShortcuts.Name) -> [KeyboardShortcuts.Name] {
        switch name {
        case .quickAdd: [.browse]
        case .browse: [.quickAdd]
        default: []
        }
    }

    private(set) var recording: KeyboardShortcuts.Name?
    private(set) var liveModifiers: QuickEntryModifiers = []
    private(set) var message: String?
    /// Bumped whenever a stored shortcut changes, so the fields re-read them.
    private(set) var revision = 0

    @ObservationIgnored private var monitor: Any?

    func shortcut(for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? {
        _ = revision
        return KeyboardShortcuts.getShortcut(for: name)
    }

    func toggle(_ name: KeyboardShortcuts.Name) {
        if recording == name { stop() } else { start(name) }
    }

    func start(_ name: KeyboardShortcuts.Name) {
        stop()
        recording = name
        message = nil
        liveModifiers = Self.modifiers(NSEvent.modifierFlags)
        KeyboardShortcuts.disable(Self.names)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        liveModifiers = []
        KeyboardShortcuts.enable(Self.names)
    }

    func clear(_ name: KeyboardShortcuts.Name) {
        stop()
        KeyboardShortcuts.setShortcut(nil, for: name)
        message = nil
        revision += 1
    }

    func restoreDefaults() {
        stop()
        KeyboardShortcuts.reset(Self.names)
        message = nil
        revision += 1
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let name = recording else { return event }
        switch event.type {
        case .flagsChanged:
            liveModifiers = Self.modifiers(event.modifierFlags)
            return event
        case .keyDown:
            record(event, for: name)
            return nil // never let the key reach the window (⌘H would hide the app, ⌘W close it)
        default:
            // A click ends listening; if it is on a recorder, that recorder's action runs next.
            stop()
            return event
        }
    }

    private func record(_ event: NSEvent, for name: KeyboardShortcuts.Name) {
        let modifiers = Self.modifiers(event.modifierFlags)
        switch ShortcutRecording.outcome(keyCode: event.keyCode, modifiers: modifiers) {
        case .cancel:
            stop()
        case .clear:
            clear(name)
        case .needsModifier:
            message = "Use at least one of ⌘, ⌃ or ⌥."
            NSSound.beep()
        case .accept:
            let shortcut = KeyboardShortcuts.Shortcut(
                carbonKeyCode: Int(event.keyCode),
                carbonModifiers: Self.carbonModifiers(modifiers)
            )
            if let other = Self.peers(of: name).first(where: { KeyboardShortcuts.getShortcut(for: $0) == shortcut }) {
                message = "\(shortcut) is already used for \(Self.title(other))."
                NSSound.beep()
                return
            }
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            message = nil
            revision += 1
            stop()
        }
    }

    static func title(_ name: KeyboardShortcuts.Name) -> String {
        switch name {
        case .quickAdd: "Quick Add"
        case .browse: "Browse"
        default: "Howy"
        }
    }

    /// ⌃⌥⇧⌘ only: fn, Caps Lock and the numeric-pad flag are dropped.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> QuickEntryModifiers {
        var result: QuickEntryModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    static func carbonModifiers(_ modifiers: QuickEntryModifiers) -> Int {
        var result = 0
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        if modifiers.contains(.command) { result |= cmdKey }
        return result
    }

    /// Drops fn from a stored shortcut (recorded by the old recorder): such hotkeys don't fire.
    static func removeFunctionModifier() {
        for name in names {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: name), shortcut.modifiers.contains(.function) else { continue }
            KeyboardShortcuts.setShortcut(
                .init(carbonKeyCode: shortcut.carbonKeyCode, carbonModifiers: carbonModifiers(modifiers(shortcut.modifiers))),
                for: name
            )
        }
    }
}

/// One shortcut field: key caps for the stored shortcut, or the live modifiers while listening.
struct ShortcutField: View {
    let name: KeyboardShortcuts.Name
    let model: ShortcutRecorderModel

    private var isRecording: Bool { model.recording == name }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    var body: some View {
        HStack(spacing: 6) {
            Button { model.toggle(name) } label: {
                HStack(spacing: 4) {
                    content
                }
                .frame(minWidth: 150, minHeight: 26)
                .padding(.horizontal, 6)
                .background(Color.primary.opacity(isRecording ? 0.02 : 0.05), in: shape)
                .overlay(shape.strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isRecording ? 2 : 1))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Type a shortcut · esc cancel · delete clear" : "Click to record a new shortcut")

            Button { model.clear(name) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(model.shortcut(for: name) == nil || isRecording ? 0 : 1)
            .help("Remove shortcut")
            .accessibilityLabel("Remove \(ShortcutRecorderModel.title(name)) shortcut")
        }
        .animation(.snappy(duration: 0.15), value: isRecording)
    }

    @ViewBuilder private var content: some View {
        if isRecording {
            let symbols = ShortcutRecording.symbols(for: model.liveModifiers)
            if symbols.isEmpty {
                Text("Type shortcut…").foregroundStyle(.secondary)
            } else {
                ForEach(Array(symbols), id: \.self) { cap(String($0)) }
                Text("…").foregroundStyle(.secondary)
            }
        } else if let shortcut = model.shortcut(for: name) {
            ForEach(Array(Self.caps(for: shortcut).enumerated()), id: \.offset) { cap($0.element) }
        } else {
            Text("Record Shortcut").foregroundStyle(.secondary)
        }
    }

    /// "⌃⌥⇧⌘Space" → ["⌃", "⌥", "⇧", "⌘", "Space"].
    static func caps(for shortcut: KeyboardShortcuts.Shortcut) -> [String] {
        let modifiers = ShortcutRecording.symbols(for: ShortcutRecorderModel.modifiers(shortcut.modifiers))
        let key = String("\(shortcut)".drop { "⌃⌥⇧⌘🌐\u{FE0E}".contains($0) })
        return modifiers.map(String.init) + [key]
    }

    /// The panels' keycap, a size up for the settings window.
    private func cap(_ text: String) -> some View {
        KeyCap(text: text, font: .system(size: 12, weight: .medium), minSize: 20)
    }
}
