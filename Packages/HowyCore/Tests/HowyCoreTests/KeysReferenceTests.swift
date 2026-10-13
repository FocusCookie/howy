import Foundation
import Testing
@testable import HowyCore

/// Settings → Keys is `KeysReference`. Per screen, the keys its rows name must be exactly the keys
/// that do something there: every key is fed into the flow, in a few states of that screen, and a
/// key "does something" when the flow asks the caller for something or its state changes. So a
/// key a flow learns (or forgets) without the reference following fails here, and so does a
/// reference row for a key that does nothing.
@MainActor
@Suite struct KeysReferenceTests {
    // MARK: Every key

    /// Every `QuickEntryKey` there is. A new case breaks `everyCaseIsListed`'s switch, so it gets
    /// listed here too.
    static let allKeys: [QuickEntryKey] = {
        var keys: [QuickEntryKey] = [
            .up, .down, .left, .right, .enter, .tab, .shiftTab, .commandEnter, .commandDelete,
            .commandDone, .escape, .closePanel, .space, .moveUp, .moveDown, .undo, .optionEnter,
            .zoomIn, .zoomOut, .zoomReset, .backspace, .dueDate, .questionMark, .other,
        ]
        for n in 0...9 { keys += [.digit(n), .commandDigit(n), .optionDigit(n)] }
        keys += "abcdefghijklmnopqrstuvwxyz".map(QuickEntryKey.letter)
        return keys
    }()

    @Test func everyCaseIsListed() {
        for key in Self.allKeys {
            switch key {
            case .up, .down, .left, .right, .digit, .commandDigit, .optionDigit, .enter, .tab, .shiftTab,
                 .commandEnter, .commandDelete, .commandDone, .escape, .closePanel, .space, .moveUp,
                 .moveDown, .undo, .optionEnter, .zoomIn, .zoomOut, .zoomReset, .backspace, .dueDate,
                 .letter, .questionMark, .other:
                break
            }
        }
    }

    // MARK: Helpers

    /// The keys `KeysReference` names for a screen.
    func reference(_ id: KeysReference.ScreenID) -> Set<QuickEntryKey> {
        KeysReference.screen(id).rows.reduce(into: []) { $0.formUnion($1.flowKeys) }
    }

    /// `effective` and `expected` agree; otherwise says which keys only one of them has.
    func expectSame(_ effective: Set<QuickEntryKey>, _ expected: Set<QuickEntryKey>, sourceLocation: SourceLocation = #_sourceLocation) {
        let unlisted = effective.subtracting(expected).map { "\($0)" }.sorted()
        let idle = expected.subtracting(effective).map { "\($0)" }.sorted()
        #expect(unlisted.isEmpty, "handled but not in the reference: \(unlisted)", sourceLocation: sourceLocation)
        #expect(idle.isEmpty, "in the reference but doing nothing: \(idle)", sourceLocation: sourceLocation)
    }

    /// The keys that do something in at least one of the states `setups` makes.
    func effective<Flow>(
        _ setups: [() -> Flow], fingerprint: (Flow) -> String, acts: (Flow, QuickEntryKey) -> Bool
    ) -> Set<QuickEntryKey> {
        var result: Set<QuickEntryKey> = []
        for setup in setups {
            for key in Self.allKeys {
                let flow = setup()
                let before = fingerprint(flow)
                let asked = acts(flow, key)
                if asked || fingerprint(flow) != before { result.insert(key) }
            }
        }
        return result
    }

    // MARK: Browse

    static let todos: [Quadrant: [TodoSnapshot]] = Dictionary(uniqueKeysWithValues: Quadrant.allCases.map { q in
        (q, (1...3).map { TodoSnapshot(id: UUID(), title: "\(q.shortcutNumber)-\($0)", quadrant: q) })
    })

    func browse(_ quadrant: Quadrant, _ keys: [QuickEntryKey] = []) -> () -> BrowseFlow {
        {
            let flow = BrowseFlow(todos: Self.todos, quadrant: quadrant, dueDates: .fixture)
            for key in keys { flow.handle(key) }
            return flow
        }
    }

    func fingerprint(_ flow: BrowseFlow) -> String {
        let rows = Quadrant.allCases.map { q in flow.rows(in: q).map(\.title).joined(separator: ",") }
        return "\(flow.phase) \(flow.quadrant) \(flow.isArchiveHighlighted) \(String(describing: flow.selectedIndex)) "
            + "\(String(describing: flow.movePicker)) \(String(describing: flow.tileEditor)) "
            + "\(String(describing: flow.dueDialog)) \(flow.canUndo) \(rows)"
    }

    func browseEffective(_ setups: [() -> BrowseFlow]) -> Set<QuickEntryKey> {
        effective(setups, fingerprint: fingerprint) { flow, key in
            let outcome = flow.handle(key)
            return outcome != .handled && outcome != .ignored
        }
    }

    /// Every quadrant, with `keys` pressed after it; plus each with the last row selected.
    func everyQuadrant(_ keys: [QuickEntryKey], lastRow: Bool = true) -> [() -> BrowseFlow] {
        Quadrant.allCases.flatMap { q in
            [browse(q, keys)] + (lastRow ? [browse(q, keys + [.down, .down])] : [])
        }
    }

    /// d then ⌘Z-able: a todo of the first quadrant marked done, then `keys`.
    func withUndo(_ keys: [QuickEntryKey]) -> () -> BrowseFlow {
        browse(.urgentImportant, [.digit(1), .letter(BrowseFlow.doneKey)] + keys)
    }

    @Test func grid() {
        let setups = everyQuadrant([], lastRow: false)
            + [browse(.urgentUnimportant, [.down]), withUndo([.escape])] // the Archive button; ⌘Z
        expectSame(browseEffective(setups), reference(.grid))
    }

    @Test func list() {
        let open = { (q: Quadrant) in [QuickEntryKey.digit(q.shortcutNumber)] }
        let setups = Quadrant.allCases.flatMap { q in [browse(q, open(q)), browse(q, open(q) + [.down, .down])] }
            + [withUndo([])]
        expectSame(browseEffective(setups), reference(.list))
    }

    @Test func movePicker() {
        // The highlight starts in the top row; ↓ takes it to the bottom one.
        let fromList = Quadrant.allCases.flatMap { q in
            let open: [QuickEntryKey] = [.digit(q.shortcutNumber), .letter(BrowseFlow.moveKey)]
            return [browse(q, open), browse(q, open + [.down])]
        }
        expectSame(browseEffective(fromList), reference(.movePicker))
        let fromOverview = Quadrant.allCases.flatMap { q in
            let open: [QuickEntryKey] = [.letter(BrowseFlow.overviewKey), .letter(BrowseFlow.moveKey)]
            return [browse(q, open), browse(q, open + [.down])]
        }
        // ⌥1–4 still focuses another tile there (the Overview's row says so).
        let optionDigits = Set((1...4).map(QuickEntryKey.optionDigit))
        expectSame(browseEffective(fromOverview), reference(.movePicker).union(optionDigits))
    }

    @Test func overview() {
        let setups = everyQuadrant([.letter(BrowseFlow.overviewKey)])
            + [withUndo([.letter(BrowseFlow.overviewKey)])]
        expectSame(browseEffective(setups), reference(.overview))
    }

    @Test func dueDateDialogInBrowse() {
        // With the examples shown, with a date set (⌘⌫), and plain.
        let open: [QuickEntryKey] = [.digit(1), .letter(BrowseFlow.dueKey)]
        let withDate: () -> BrowseFlow = {
            let flow = BrowseFlow(todos: Self.todos, quadrant: .urgentImportant, dueDates: .fixture)
            flow.handle(.digit(1))
            let id = flow.selectedTodo!.id
            flow.handle(.letter(BrowseFlow.dueKey))
            flow.setDueText("tomorrow")
            flow.handle(.enter)
            flow.beginDueDate(id: id)
            return flow
        }
        let setups = [browse(.urgentImportant, open), browse(.urgentImportant, open + [.tab]), withDate]
        expectSame(browseEffective(setups), reference(.dueDateDialog))
    }

    // MARK: Archive

    @Test func archive() {
        let ids = [UUID(), UUID(), UUID()]
        let setups: [() -> ArchiveFlow] = [
            { ArchiveFlow(ids: ids) },
            { let flow = ArchiveFlow(ids: ids); flow.select(id: ids[2]); return flow },
        ]
        let keys = effective(setups, fingerprint: { "\($0.ids) \(String(describing: $0.selectedIndex))" }) { flow, key in
            let outcome = flow.handle(key)
            return outcome != .handled
        }
        expectSame(keys, reference(.archive))
    }

    // MARK: Editor

    func fingerprint(_ flow: QuickEntryFlow) -> String {
        "\(flow.phase) \(flow.quadrant) \(flow.title) \(flow.note) \(flow.attachments.map(\.name)) "
            + "\(String(describing: flow.selectedAttachmentIndex)) \(String(describing: flow.request)) "
            + "\(String(describing: flow.savedDraft)) \(String(describing: flow.due)) "
            + "\(String(describing: flow.dueDialog)) \(String(describing: flow.linkDialog)) "
            + "\(String(describing: flow.pendingNoteEdit))"
    }

    func editorEffective(_ setups: [() -> QuickEntryFlow]) -> Set<QuickEntryKey> {
        effective(setups, fingerprint: fingerprint) { flow, key in
            flow.handle(key)
            return false // a swallowed key changes nothing
        }
    }

    /// A new todo titled "Pay" (or, `editing`, an opened one) in `quadrant`, with `keys` pressed.
    func editor(
        _ quadrant: Quadrant = .urgentImportant, editing: Bool = false, due: Date? = nil,
        attachments: [TodoAttachment] = [], keys: [QuickEntryKey] = []
    ) -> () -> QuickEntryFlow {
        {
            let mode: QuickEntryFlow.Mode = editing
                ? .edit(QuickEntryDraft(todoID: UUID(), title: "Pay", note: "[Howy](https://example.com)", quadrant: quadrant, attachments: attachments, due: due))
                : .create(quadrant)
            let flow = QuickEntryFlow(mode: mode, lastUsed: MemoryLastQuadrantStore(), dueDates: .fixture)
            if !editing { flow.title = "Pay" }
            for key in keys { flow.handle(key) }
            return flow
        }
    }

    /// ⌘↩, ⌘D, ⌘T and Esc work in every part of the editor.
    var editorEverywhere: Set<QuickEntryKey> { [.commandEnter, .commandDone, .dueDate, .escape] }

    @Test func editorTitleAndNote() {
        let setups = [editor(), editor(editing: true), editor(keys: [.enter]), editor(editing: true, keys: [.enter])]
        expectSame(editorEffective(setups), reference(.editor))
    }

    @Test func editorQuadrantPicker() {
        let setups = Quadrant.allCases.flatMap { q in [editor(q, keys: [.shiftTab]), editor(q, editing: true, keys: [.shiftTab])] }
        expectSame(editorEffective(setups), reference(.editorQuadrantPicker).union(editorEverywhere))
    }

    @Test func attachments() {
        let files = [TodoAttachment(name: "a.txt"), TodoAttachment(name: "b.txt")]
        let setups = [
            editor(editing: true, keys: [.optionEnter]), // none: the Add button
            editor(editing: true, attachments: files, keys: [.optionEnter]),
            editor(editing: true, attachments: files, keys: [.optionEnter, .right, .right]),
        ]
        expectSame(editorEffective(setups), reference(.attachments).union(editorEverywhere))
    }

    @Test func dueDateDialogInTheEditor() {
        let due = DueFixture.wednesday.addingTimeInterval(86_400)
        let setups = [
            editor(keys: [.dueDate]), editor(keys: [.dueDate, .tab]),
            editor(editing: true, due: due, keys: [.dueDate]), editor(editing: true, due: due, keys: [.dueDate, .tab, .down]),
        ]
        expectSame(editorEffective(setups), reference(.dueDateDialog))
    }

    @Test func linkDialog() {
        let adding = { () -> QuickEntryFlow in
            let flow = editor(keys: [.enter])()
            flow.beginAddingLink(url: "https://example.com", replacing: NSRange(location: 0, length: 0))
            return flow
        }
        let editing = { () -> QuickEntryFlow in
            let flow = editor(editing: true, keys: [.enter])()
            flow.beginEditingLink(NoteLinks.links(in: flow.note)[0])
            return flow
        }
        expectSame(editorEffective([adding, editing]), reference(.linkDialog))
    }

    // MARK: Everywhere

    /// The panel's own keys, which no flow handles: ⌘W / ⌘Esc and the zoom.
    @Test func everywhere() {
        #expect(reference(.everywhere) == [.closePanel, .zoomIn, .zoomOut, .zoomReset])
        #expect(QuickEntryKey(keyCode: 13, modifiers: .command, characters: "w") == .closePanel)
        #expect(QuickEntryKey(keyCode: 53, modifiers: .command, characters: nil) == .closePanel)
        #expect(QuickEntryKey(keyCode: 24, modifiers: [.command, .shift], characters: "+") == .zoomIn)
        #expect(QuickEntryKey(keyCode: 27, modifiers: .command, characters: "-") == .zoomOut)
        #expect(QuickEntryKey(keyCode: 29, modifiers: .command, characters: "0") == .zoomReset)
        let openHowy = KeysReference.screen(.everywhere).rows.filter { $0.keys == .openHowyShortcut }
        #expect(openHowy.count == 1)
    }

    // MARK: How the keys are written

    @Test func everyScreenOnceAndInOrder() {
        #expect(KeysReference.screens.map(\.id) == KeysReference.ScreenID.allCases)
        for screen in KeysReference.screens {
            #expect(Set(screen.rows.map(\.id)).count == screen.rows.count, "\(screen.title) has a row twice")
        }
    }

    /// A row's letters and vim keys are written out: "N" for n, "j k" next to "↑↓".
    @Test func rowsShowTheirLetters() {
        for screen in KeysReference.screens {
            for row in screen.rows {
                guard case .keys(let alternatives) = row.keys else { continue }
                #expect(!alternatives.isEmpty)
                let shown = alternatives.joined(separator: " ").lowercased().split(separator: " ")
                for case .letter(let letter) in row.flowKeys {
                    #expect(shown.contains { $0 == String(letter) }, "\(screen.title): \(row.action) doesn't show \(letter)")
                }
            }
        }
    }
}
