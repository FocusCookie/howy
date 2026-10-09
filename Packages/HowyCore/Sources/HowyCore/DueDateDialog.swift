import Foundation

/// What the flows need to read due-date phrases: the injected clock, the calendar and the
/// default time of day (a Settings choice, read when the panel opens).
public struct DueDateContext: Sendable {
    public var now: @Sendable () -> Date
    public var calendar: Calendar
    public var defaultTime: DueTime

    public init(now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current, defaultTime: DueTime = .standard) {
        self.now = now
        self.calendar = calendar
        self.defaultTime = defaultTime
    }

    /// The real clock and calendar with the stored default time.
    public static func live() -> DueDateContext {
        DueDateContext(defaultTime: DueTime.load())
    }

    func parse(_ text: String) -> DueDateParser.Outcome {
        DueDateParser.parse(text, now: now(), calendar: calendar, defaultTime: defaultTime)
    }
}

/// The due-date dialog's state, shared by the editor (`QuickEntryFlow.dueDialog`) and the
/// Browse list (`BrowseFlow.dueDialog`): one text field, its parse result and the examples panel.
///
/// - Typing re-parses (`outcome`).
/// - ↩ (`confirmation`): a valid phrase sets that date; an empty field keeps the date already
///   set (or does nothing without one); anything else does nothing.
/// - Esc closes the examples first, the dialog second.
/// - ⌘⌫ / Remove clears a set date (without one, ⌘⌫ is the field's).
/// - ⇥ and ⇧⇥ open or close the examples (the **?** button). While they're open ↑/↓ go through
///   them (clamped; ↑ from none starts at the last) and ↩ on a highlighted one puts it in the
///   field instead of setting; with none highlighted ↩ sets as always. Typing clears the highlight.
///
/// The flows run their keys through `handle(_:context:)` and do what it returns.
public struct DueDateDialog: Hashable, Sendable {
    /// What ↩ does.
    public enum Confirmation: Hashable, Sendable {
        /// Set this due date.
        case set(Date)
        /// Close; the date stays as it is (an empty field).
        case keep
    }

    /// The due date when the dialog opened (shown in its header).
    public let current: Date?
    public private(set) var text = ""
    public private(set) var outcome: DueDateParser.Outcome = .empty
    /// The **?** examples panel beside the panel is open.
    public private(set) var showsExamples = false
    /// The example ↑/↓ moved to (an index into `DueDateExamples.all`), while the examples are open.
    public private(set) var highlightedExample: Int?

    /// What a key in the dialog asks the flow to do.
    public enum KeyAction: Hashable, Sendable {
        /// Consumed; nothing else to do.
        case handled
        /// ↩: set the date (`confirmation`), as the Set button does.
        case confirm
        /// ⌘⌫: remove the set date.
        case remove
        /// Esc with the examples closed: close the dialog.
        case close
        /// Not the dialog's: typing (and caret keys) for its field.
        case notOurs
    }

    public init(current: Date?) {
        self.current = current
    }

    mutating func setText(_ text: String, context: DueDateContext) {
        highlightedExample = nil
        guard text != self.text else { return }
        self.text = text
        outcome = context.parse(text)
    }

    /// Opens or closes the examples (⇥, ⇧⇥, the **?** button).
    mutating func toggleExamples() {
        showsExamples.toggle()
        highlightedExample = nil
    }

    /// Closes the examples, if open. Returns whether they were.
    mutating func closeExamples() -> Bool {
        guard showsExamples else { return false }
        showsExamples = false
        highlightedExample = nil
        return true
    }

    /// The dialog's keys (see the type's rules).
    mutating func handle(_ key: QuickEntryKey, context: DueDateContext) -> KeyAction {
        switch key {
        case .escape:
            return closeExamples() ? .handled : .close
        case .enter, .commandEnter:
            if key == .enter, showsExamples, let index = highlightedExample {
                setText(DueDateExamples.all[index].phrase, context: context)
                return .handled
            }
            return .confirm
        case .commandDelete:
            return canRemove ? .remove : .notOurs // without a date the field deletes to the line start
        case .tab, .shiftTab:
            toggleExamples()
            return .handled
        case .up, .down:
            guard showsExamples else { return .notOurs }
            let last = DueDateExamples.all.count - 1
            if let index = highlightedExample {
                highlightedExample = min(max(index + (key == .down ? 1 : -1), 0), last)
            } else {
                highlightedExample = key == .down ? 0 : last
            }
            return .handled
        case .commandDone, .optionEnter, .dueDate:
            return .handled
        default:
            return .notOurs
        }
    }

    /// ↩: what to do, or `nil` while the text isn't a date (or is empty with no date set).
    public var confirmation: Confirmation? {
        switch outcome {
        case .resolved(let date, _): .set(date)
        case .empty: current == nil ? nil : .keep
        case .failure: nil
        }
    }

    public var canConfirm: Bool { confirmation != nil }

    /// Whether Remove (⌘⌫) applies: a date was set when the dialog opened.
    public var canRemove: Bool { current != nil }

    /// The line under the field: what the phrase means, the date that stays, or the problem.
    public func preview(now: Date, format: DueFormat) -> DueFormat.Preview {
        if outcome == .empty, let current {
            return format.preview(.resolved(current, note: nil), now: now, unchanged: true)
        }
        return format.preview(outcome, now: now)
    }
}
