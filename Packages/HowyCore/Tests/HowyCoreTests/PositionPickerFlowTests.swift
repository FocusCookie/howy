import CoreGraphics
import Foundation
import Testing
@testable import HowyCore

@MainActor
@Suite struct PositionPickerFlowTests {
    func flow(_ selected: PanelSlot = .center, current: PanelSlot? = .center) -> PositionPickerFlow {
        PositionPickerFlow(selected: selected, current: current)
    }

    @Test func arrowsMoveTheSelection() {
        let picker = flow()
        #expect(picker.handle(.up) == .handled)
        #expect(picker.selected == .top)
        picker.handle(.left)
        #expect(picker.selected == .topLeading)
        picker.handle(.down)
        picker.handle(.down)
        #expect(picker.selected == .bottomLeading)
        picker.handle(.right)
        #expect(picker.selected == .bottom)
        #expect(picker.current == .center, "only ↩ moves the panel")
    }

    @Test func vimKeysMoveTheSelection() {
        let picker = flow()
        picker.handle(.letter("k"))
        #expect(picker.selected == .top)
        picker.handle(.letter("l"))
        #expect(picker.selected == .topTrailing)
        picker.handle(.letter("j"))
        #expect(picker.selected == .trailing)
        picker.handle(.letter("h"))
        #expect(picker.selected == .center)
    }

    @Test(arguments: [
        (PanelSlot.topLeading, QuickEntryKey.up), (.topLeading, .left), (.top, .up), (.topTrailing, .up),
        (.topTrailing, .right), (.trailing, .right), (.bottomTrailing, .right), (.bottomTrailing, .down),
        (.bottom, .down), (.bottomLeading, .down), (.bottomLeading, .left), (.leading, .left),
    ])
    func stopsAtTheEdges(start: PanelSlot, key: QuickEntryKey) {
        let picker = flow(start)
        #expect(picker.handle(key) == .handled)
        #expect(picker.selected == start)
    }

    @Test func returnCommitsTheSelectedSlot() {
        let picker = flow()
        picker.handle(.down)
        picker.handle(.right)
        #expect(picker.handle(.enter) == .commit(.bottomTrailing))
    }

    @Test func escapeCancels() {
        let picker = flow()
        picker.handle(.up)
        #expect(picker.handle(.escape) == .cancel)
    }

    @Test func theShortcutAgainCancels() {
        #expect(flow().handle(.openPositionPicker) == .cancel)
    }

    @Test(arguments: [
        QuickEntryKey.letter("a"), .letter("p"), .other, .digit(3), .space, .tab, .backspace, .questionMark,
        .commandEnter, .zoomIn,
    ])
    func otherKeysAreSwallowed(key: QuickEntryKey) {
        let picker = flow(.leading)
        #expect(picker.handle(key) == .handled)
        #expect(picker.selected == .leading)
    }

    @Test func startsOnTheNearestSlot() {
        let visible = CGRect(x: 0, y: 30, width: 1500, height: 900)
        let dragged = CGRect(x: 820, y: 60, width: 600, height: 300)
        let position = PanelPlacement.position(fromCardFrame: dragged, in: visible)
        let picker = PositionPickerFlow(position: position, cardSize: dragged.size, in: visible)
        #expect(picker.selected == .bottomTrailing)
        #expect(picker.current == nil)
    }

    @Test func startsOnTheCurrentSlot() {
        let visible = CGRect(x: 0, y: 30, width: 1500, height: 900)
        let position = PanelPlacement.position(for: .topTrailing, in: visible)
        let picker = PositionPickerFlow(position: position, cardSize: CGSize(width: 600, height: 300), in: visible)
        #expect(picker.selected == .topTrailing)
        #expect(picker.current == .topTrailing)
    }
}
