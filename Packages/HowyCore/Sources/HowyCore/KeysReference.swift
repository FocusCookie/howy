import Foundation

/// Every key Howy knows, grouped by screen, for Settings → Keys (read-only). It is data, so a test
/// (`KeysReferenceTests`) can check it against the keys the flows really handle: each row names
/// the `QuickEntryKey`s it stands for (`flowKeys`), and per screen those must be exactly the keys
/// that do something there. Rows with no `flowKeys` are handled outside the flows (the note
/// editor's ⇧⌘L, ⌘V, ⌘O, ⌥⌘O, ⌘E; the global Open Howy shortcut).
///
/// Keys are written like the panels' footer hints (`KeyHint`): letters as capitals ("N"), vim keys
/// in lower case as an alternative next to the arrows ("↑↓ / j k").
public enum KeysReference {
    public enum ScreenID: String, CaseIterable, Hashable, Sendable {
        case everywhere, positionPicker, grid, list, movePicker, overview, archive
        case editor, editorQuadrantPicker, attachments, dueDateDialog, linkDialog, attachmentDialog
    }

    public struct Screen: Identifiable, Hashable, Sendable {
        public let id: ScreenID
        public let title: String
        /// How to get there, or what to know about it.
        public let note: String?
        public let rows: [Row]
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public enum Keys: Hashable, Sendable {
            /// Alternatives, each a space-separated run of keys: ["↑↓", "j k"] reads "↑↓ / j k".
            case keys([String])
            /// The global Open Howy shortcut, whatever it is set to.
            case openHowyShortcut
        }

        public let keys: Keys
        public let action: String
        /// The flow keys this row stands for (empty: handled outside the flows).
        public let flowKeys: Set<QuickEntryKey>

        public var id: String { "\(keys) \(action)" }

        init(_ keys: [String], _ action: String, _ flowKeys: Set<QuickEntryKey> = []) {
            self.keys = .keys(keys)
            self.action = action
            self.flowKeys = flowKeys
        }

        init(openHowy action: String) {
            keys = .openHowyShortcut
            self.action = action
            flowKeys = []
        }
    }

    @MainActor public static func screen(_ id: ScreenID) -> Screen {
        screens.first { $0.id == id }!
    }

    // MARK: Building blocks

    private static let arrows: Set<QuickEntryKey> = [.up, .down, .left, .right]
    private static let upDown: Set<QuickEntryKey> = [.up, .down]
    private static let vim: Set<QuickEntryKey> = [.letter("h"), .letter("j"), .letter("k"), .letter("l")]
    private static let vimUpDown: Set<QuickEntryKey> = [.letter("j"), .letter("k")]
    private static let digits = Set((1...4).map(QuickEntryKey.digit))
    private static let commandDigits = Set((1...4).map(QuickEntryKey.commandDigit))
    private static let optionDigits = Set((1...4).map(QuickEntryKey.optionDigit))

    private static func cap(_ letter: Character) -> String { letter.uppercased() }
    private static func letter(_ letter: Character) -> Set<QuickEntryKey> { [.letter(letter)] }

    private static let undoRow = Row(["⌘Z"], "Undo the last done, archive, move or reorder", [.undo])
    private static let keysRow = Row(["?"], "This keys reference", [.questionMark])
    private static let reorderRow = Row(["⌘↑ ⌘↓", "⌘K ⌘J"], "Move the selected todo up or down", [.moveUp, .moveDown])

    // MARK: The screens

    /// Main-actor bound: the letters come from the flows' constants.
    @MainActor public static let screens: [Screen] = [
        Screen(id: .everywhere, title: "Everywhere", note: nil, rows: [
            Row(openHowy: "Open Howy on the quadrant grid; closes Howy when it is open"),
            Row(["⌘W", "⌘esc"], "Close Howy from any screen (an unsaved todo is kept as a draft)", [.closePanel]),
            Row(["⌘+ ⌘-"], "Make the panel bigger or smaller", [.zoomIn, .zoomOut]),
            Row(["⌘0"], "Panel size back to 100 %", [.zoomReset]),
            Row(["⌘⇧P"], "Move the panel (position picker); or drag it by its background", [.openPositionPicker]),
        ]),
        Screen(id: .positionPicker, title: "Position picker", note: "⌘⇧P in any panel. Howy remembers the spot.", rows: [
            Row(["←↑↓→", "h j k l"], "Choose a spot on the screen", arrows.union(vim)),
            Row(["↩"], "Move the panel there", [.enter]),
            Row(["esc", "⌘⇧P"], "Close the picker, leaving the panel where it is", [.escape, .openPositionPicker]),
        ]),
        Screen(id: .grid, title: "Quadrant grid", note: "What Open Howy shows first.", rows: [
            Row(["←↑↓→", "h j k l"], "Move the highlight (↓ from the bottom row reaches Archive)", arrows.union(vim)),
            Row(["1–4"], "Open that quadrant's list", digits),
            Row(["↩", "⇥"], "Open the highlighted quadrant (or the archive)", [.enter, .tab]),
            Row([cap(BrowseFlow.newKey)], "New todo in the highlighted quadrant", letter(BrowseFlow.newKey)),
            Row([cap(BrowseFlow.overviewKey)], "Overview: all four quadrants at once", letter(BrowseFlow.overviewKey)),
            Row([cap(BrowseFlow.archiveKey)], "Archive", letter(BrowseFlow.archiveKey)),
            undoRow,
            keysRow,
            Row(["esc"], "Close Howy", [.escape]),
        ]),
        Screen(id: .list, title: "List", note: "One quadrant's todos.", rows: [
            Row(["↑↓", "j k"], "Select a todo", upDown.union(vimUpDown)),
            Row(["↩"], "Open the selected todo in the editor", [.enter]),
            Row([cap(BrowseFlow.newKey)], "New todo in this quadrant", letter(BrowseFlow.newKey)),
            Row([cap(BrowseFlow.doneKey)], "Mark the selected todo done", letter(BrowseFlow.doneKey)),
            Row(["⌫"], "Archive it without the celebration", [.backspace]),
            Row([cap(BrowseFlow.dueKey)], "Set its due date", letter(BrowseFlow.dueKey)),
            Row([cap(BrowseFlow.moveKey)], "Move it to another quadrant (move picker)", letter(BrowseFlow.moveKey)),
            Row(["⌘1–4"], "Move it to that quadrant right away", commandDigits),
            reorderRow,
            Row(["1–4"], "Show another quadrant", digits),
            Row([cap(BrowseFlow.overviewKey)], "Overview", letter(BrowseFlow.overviewKey)),
            Row([cap(BrowseFlow.archiveKey)], "Archive", letter(BrowseFlow.archiveKey)),
            undoRow,
            keysRow,
            Row(["esc", "⇧⇥"], "Back to the grid", [.escape, .shiftTab]),
        ]),
        Screen(id: .movePicker, title: "Move picker", note: "\(cap(BrowseFlow.moveKey)) in the list or the Overview.", rows: [
            Row(["1–4", "⌘1–4"], "Move the todo to that quadrant", digits.union(commandDigits)),
            Row(["←↑↓→", "h j k l"], "Move the highlight", arrows.union(vim)),
            Row(["↩"], "Move it to the highlighted quadrant", [.enter]),
            Row(["esc"], "Close the picker", [.escape]),
        ]),
        Screen(id: .overview, title: "Overview", note: "The focused tile works like a list.", rows: [
            Row(["↑↓", "j k"], "Select a todo in the focused tile", upDown.union(vimUpDown)),
            Row(["←→", "h l"], "Focus the tile beside it", [.left, .right, .letter("h"), .letter("l")]),
            Row(["1–4", "⌥1–4"], "Focus that quadrant (⌥ also from a tile's editor, keeping it as a draft)", digits.union(optionDigits)),
            Row(["⇥ ⇧⇥"], "Focus the next or previous quadrant", [.tab, .shiftTab]),
            Row(["↩"], "Edit the selected todo in its tile", [.enter]),
            Row([cap(BrowseFlow.newKey)], "New todo in the focused tile", letter(BrowseFlow.newKey)),
            Row([cap(BrowseFlow.doneKey)], "Mark the selected todo done", letter(BrowseFlow.doneKey)),
            Row(["⌫"], "Archive it without the celebration", [.backspace]),
            Row([cap(BrowseFlow.dueKey)], "Set its due date", letter(BrowseFlow.dueKey)),
            Row([cap(BrowseFlow.moveKey)], "Move it to another quadrant (move picker)", letter(BrowseFlow.moveKey)),
            Row(["⌘1–4"], "Move it to that quadrant right away", commandDigits),
            reorderRow,
            Row([cap(BrowseFlow.archiveKey)], "Archive", letter(BrowseFlow.archiveKey)),
            undoRow,
            keysRow,
            Row(["esc"], "Back to the grid (closes a tile's editor first)", [.escape]),
        ]),
        Screen(id: .archive, title: "Archive", note: "\(cap(BrowseFlow.archiveKey)) on the grid, in a list or the Overview.", rows: [
            Row(["↑↓", "j k"], "Select a todo", upDown.union(vimUpDown)),
            Row([cap(ArchiveFlow.restoreKey)], "Restore it", letter(ArchiveFlow.restoreKey)),
            Row(["⌫", "⌘⌫"], "Delete it for good", [.backspace, .commandDelete]),
            keysRow,
            Row(["esc"], "Close, or back to where you came from", [.escape]),
        ]),
        Screen(id: .editor, title: "Editor", note: "A new or opened todo: its title, then its note.", rows: [
            Row(["⌘↩"], "Save", [.commandEnter]),
            Row(["⌘D"], "Save and mark done (an opened todo)", [.commandDone]),
            Row(["⌘T"], "Set the due date", [.dueDate]),
            Row(["↩", "⇥"], "From the title on to the note", [.enter, .tab]),
            Row(["⇧⇥"], "Back: note to title, title to the quadrant picker", [.shiftTab]),
            Row(["⌥↩"], "Go to the attachments", [.optionEnter]),
            Row(["⇧⌘L"], "Note: make the lines checklist items, or tick them"),
            Row(["⇥ ⇧⇥"], "Note: nest a list item one level deeper, or less deep"),
            Row(["⌘V"], "Note: paste files or a screenshot as attachments, or a link"),
            Row(["⌘O"], "Note: open the link or attachment at the caret"),
            Row(["⌥⌘O"], "Note: open the attachment at the caret the other way"),
            Row(["⌘E"], "Note: edit the link or attachment at the caret"),
            Row(["esc"], "Close, keeping a new todo as a draft; an opened todo's changes are dropped", [.escape]),
        ]),
        Screen(id: .editorQuadrantPicker, title: "Editor's quadrant picker", note: "⇧⇥ from the title.", rows: [
            Row(["←↑↓→"], "Choose a quadrant", arrows),
            Row(["1–4"], "Choose that quadrant and go to the title", digits),
            Row(["↩", "⇥"], "On to the title", [.enter, .tab]),
        ]),
        Screen(id: .attachments, title: "Attachments", note: "⌥↩ in the editor.", rows: [
            Row(["←→", "h l"], "Select an attachment or the Add button", [.left, .right, .letter("h"), .letter("l")]),
            Row(["space", "↩"], "Open it (Add: choose files)", [.space, .enter]),
            Row(["⌥↩"], "Open it the other way (see Settings → General)", [.optionEnter]),
            Row(["⌫"], "Remove it", [.backspace]),
            Row([cap(QuickEntryFlow.insertKey)], "Insert it into the note at the caret (a selected line becomes its title)", letter(QuickEntryFlow.insertKey)),
            Row(["⇧⇥"], "Back to the note", [.shiftTab]),
        ]),
        Screen(id: .dueDateDialog, title: "Due-date dialog", note: "⌘T in the editor, \(cap(BrowseFlow.dueKey)) in a list. Type \"fri 2pm\", \"24.12.\" or \"in a week\".", rows: [
            Row(["↩", "⌘↩"], "Set the date (↩ on a highlighted example puts it in the field)", [.enter, .commandEnter]),
            Row(["⇥ ⇧⇥"], "Show or hide the examples", [.tab, .shiftTab]),
            Row(["↑↓"], "Choose an example", upDown),
            Row(["⌘⌫"], "Remove the due date", [.commandDelete]),
            Row(["esc"], "Hide the examples, then cancel", [.escape]),
        ]),
        Screen(id: .linkDialog, title: "Link dialog", note: "Pasting a link into the note, or ⌘E on one.", rows: [
            Row(["↩", "⌘↩"], "Add or save the link", [.enter, .commandEnter]),
            Row(["⇥ ⇧⇥"], "Switch between title and URL (⌘E)", [.tab, .shiftTab]),
            Row(["⌘⌫"], "Remove the link, keeping its title as text (⌘E)", [.commandDelete]),
            Row(["esc"], "Cancel", [.escape]),
        ]),
        Screen(id: .attachmentDialog, title: "Attachment dialog", note: "Pasting or dropping a file into the note, \(cap(QuickEntryFlow.insertKey)) in the attachments, or ⌘E on an attachment.", rows: [
            Row(["↩", "⌘↩"], "Add the attachment, or save its title", [.enter, .commandEnter]),
            Row(["⌘⌫"], "Remove it from the note (⌘E); asks whether to delete the attachment too", [.commandDelete]),
            Row(["Y"], "Asked: yes, delete the attachment too", [.letter("y")]),
            Row(["N", "↩"], "Asked: no, keep the attachment (the default)", [.letter("n")]),
            Row(["esc"], "Cancel (asked: back to the title)", [.escape]),
        ]),
    ]
}
