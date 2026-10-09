import AppKit
import HowyCore
import SwiftUI

/// What the due-date dialog's controls do (the editor's flow or Browse's model behind them).
struct DueDateDialogActions {
    var setText: (String) -> Void
    var confirm: () -> Void
    var cancel: () -> Void
    var remove: () -> Void
    var toggleExamples: () -> Void
    var pickExample: (String) -> Void
}

/// The due-date dialog (`DueDateDialog`): one field, the live preview under it, and buttons for
/// the mouse. Keys come through the flows (↩, Esc, ⌘⌫); this renders the state, keeps the field
/// focused and shows the **?** examples beside the panel (`DueExamplesPanel`).
struct DueDateDialogView: View {
    let dialog: DueDateDialog
    let now: Date
    let actions: DueDateDialogActions
    @FocusState private var fieldFocused: Bool
    @State private var examples = DueExamplesPanelController()
    @State private var host = HostWindowBox()
    @Environment(\.panelScale) private var scale

    private var format: DueFormat { DueFormat() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(spacing: 8 * scale) {
                Text("Due Date")
                    .panelFont(.headline)
                if let current = dialog.current {
                    Text("now: \(format.long(current))")
                        .panelFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8 * scale)
                Button(action: actions.toggleExamples) {
                    Text("?")
                        .panelFont(.callout, weight: .semibold)
                        .frame(width: 20 * scale, height: 20 * scale)
                        .background(
                            Circle().fill(dialog.showsExamples ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Examples of what you can type (⇥)")
                .accessibilityLabel("Examples")
            }

            TextField(
                "tomorrow 10am · fri · 10.10. · in 2 h",
                text: Binding(get: { dialog.text }, set: { actions.setText($0) })
            )
            .textFieldStyle(.roundedBorder)
            .panelFont(.body)
            .focused($fieldFocused)

            preview
                .panelFont(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 8 * scale) {
                KeyHints(hint)
                Spacer(minLength: 8 * scale)
                if dialog.canRemove {
                    Button("Remove", action: actions.remove)
                        .help("Remove the due date (⌘⌫)")
                }
                Button("Cancel", action: actions.cancel)
                Button("Set", action: actions.confirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!dialog.canConfirm)
            }
            .buttonStyle(.bordered)
            .panelControlSize(.small)
            .panelFont(.caption)
        }
        .padding(14 * scale)
        .frame(maxWidth: 440 * scale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).strokeBorder(.separator)
        }
        .shadow(color: .black.opacity(0.18), radius: 16 * scale, y: 6 * scale)
        .background(HostWindowReader { host.window = $0 as? FloatingPanel })
        .onAppear {
            // Next turn: the field must be in the window before it can take focus.
            DispatchQueue.main.async { fieldFocused = true }
            syncExamples()
        }
        .onChange(of: dialog.showsExamples) { _, _ in syncExamples() }
        .onChange(of: dialog.highlightedExample) { _, _ in syncExamples() }
        .onChange(of: scale) { _, _ in syncExamples() }
        .onDisappear { examples.hide() }
    }

    /// With the examples open: how to pick one; otherwise the dialog's own keys.
    private var hint: String {
        if dialog.showsExamples {
            return dialog.highlightedExample == nil ? "↑↓ examples · ↩ set · ⇥ hide · esc hide" : "↑↓ examples · ↩ pick · ⇥ hide · esc hide"
        }
        return dialog.canRemove ? "↩ set · ⇥ examples · esc cancel · ⌘⌫ remove" : "↩ set · ⇥ examples · esc cancel"
    }

    @ViewBuilder private var preview: some View {
        switch dialog.preview(now: now, format: format) {
        case .idle(let text):
            Text(text).foregroundStyle(.secondary)
        case .ok(let date, let detail):
            Text("\(Text(date).foregroundStyle(.primary))  \(Text("· \(detail)").foregroundStyle(.secondary))")
        case .error(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
        }
    }

    /// Shows or hides the examples beside the panel. Next turn, so the host window is known.
    private func syncExamples() {
        DispatchQueue.main.async {
            guard dialog.showsExamples, let parent = host.window else {
                examples.hide()
                return
            }
            examples.show(beside: parent, scale: scale) {
                DueExamplesView(now: now, highlighted: dialog.highlightedExample, pick: actions.pickExample)
            }
        }
    }
}

/// The **?** panel's content: grouped example phrases with what each means right now. A click
/// puts the phrase in the dialog's field.
struct DueExamplesView: View {
    let now: Date
    /// The example ↑/↓ moved to (an index into `DueDateExamples.all`).
    var highlighted: Int?
    let pick: (String) -> Void
    @Environment(\.panelScale) private var scale

    var body: some View {
        let format = DueFormat()
        let defaultTime = DueTime.load()
        VStack(alignment: .leading, spacing: 6 * scale) {
            Text("What you can type")
                .panelFont(.headline)
            Text("Click an example (or ↑↓ and ↩) to try it. A day without a time means \(defaultTime.text).")
                .panelFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(DueDateExamples.groups) { group in
                Text(group.title.uppercased())
                    .panelFont(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4 * scale)
                ForEach(group.examples) { example in
                    let outcome = DueDateParser.parse(example.phrase, now: now, defaultTime: defaultTime)
                    let meaning = [outcome.date.map { "→ " + format.short($0, now: now) }, example.hint.isEmpty ? nil : example.hint]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    let isHighlighted = highlighted.map { DueDateExamples.all.indices.contains($0) && DueDateExamples.all[$0] == example } ?? false
                    ExampleRow(phrase: example.phrase, meaning: meaning, isHighlighted: isHighlighted) { pick(example.phrase) }
                }
            }
        }
        .padding(14 * scale)
        .frame(width: 300 * scale, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous).strokeBorder(.separator)
        }
    }

    private struct ExampleRow: View {
        let phrase: String
        let meaning: String
        let isHighlighted: Bool
        let action: () -> Void
        @State private var isHovered = false
        @Environment(\.panelScale) private var scale

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8 * scale) {
                    Text(phrase)
                        .panelFont(.callout, monospacedDigit: true)
                        .fontDesign(.monospaced)
                    Spacer(minLength: 8 * scale)
                    Text(meaning)
                        .panelFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6 * scale)
                .padding(.vertical, 3 * scale)
                .background(
                    isHighlighted ? Color.accentColor.opacity(0.22) : Color.primary.opacity(isHovered ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Put “\(phrase)” in the field")
        }
    }
}

/// A todo's due date in a Browse row: a grey clock and a short label while upcoming, a red bell
/// and "Overdue · …" once due (the bell wiggles when `wiggle` changes). Without a date, a faint
/// clock on the selected row only. A click opens the dialog; hovering shows the full date.
struct DueBadge: View {
    let due: Date?
    let now: Date
    let isSelected: Bool
    var wiggle = 0
    let action: () -> Void
    @Environment(\.panelScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let format = DueFormat()
        Button(action: action) {
            if let due {
                let overdue = DueState(due: due, now: now) == .overdue
                HStack(spacing: 3 * scale) {
                    Image(systemName: overdue ? "bell.fill" : "clock")
                        .symbolEffect(.wiggle, options: .nonRepeating, value: overdue && !reduceMotion ? wiggle : 0)
                    Text(format.short(due, now: now))
                        .monospacedDigit()
                }
                .panelFont(.caption, weight: overdue ? .medium : nil)
                .foregroundStyle(overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
            } else {
                Image(systemName: "clock")
                    .panelFont(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(isSelected ? 1 : 0)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(due.map { "Due \(format.long($0)) (t)" } ?? "Set a due date (t)")
        .accessibilityLabel(due.map { "Due \(format.long($0))" } ?? "Set a due date")
    }
}

/// The editor header's due date: a clickable pill with a clock (or a red bell once due) and the
/// short label, or "Add due date". Hovering shows the full date.
struct DuePill: View {
    let due: Date?
    let now: Date
    let action: () -> Void
    @Environment(\.panelScale) private var scale

    var body: some View {
        let format = DueFormat()
        let overdue = DueState(due: due, now: now) == .overdue
        Button(action: action) {
            HStack(spacing: 4 * scale) {
                Image(systemName: overdue ? "bell.fill" : "clock")
                Text(due.map { format.short($0, now: now) } ?? "Add due date")
                    .monospacedDigit()
            }
            .panelFont(.caption, weight: .medium)
            .foregroundStyle(overdue ? AnyShapeStyle(.red) : due == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 3 * scale)
            .background((overdue ? Color.red : Color.primary).opacity(due == nil ? 0 : 0.08), in: Capsule())
            .overlay { if due == nil { Capsule().strokeBorder(.separator) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(due.map { "Due \(format.long($0)) (⌘T)" } ?? "Set a due date (⌘T)")
    }
}

/// Holds the dialog's panel without triggering view updates.
@MainActor
private final class HostWindowBox {
    weak var window: FloatingPanel?
}

/// Reports the hosting window once the view is in one.
private struct HostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
    }
}
