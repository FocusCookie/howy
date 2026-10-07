import Testing
@testable import HowyCore

@Suite struct DoneEmojiTests {
    @Test func neverRepeatsTheLastOne() {
        var emoji = DoneEmoji()
        var previous = emoji.next()
        for _ in 0..<200 {
            let next = emoji.next()
            #expect(next != previous)
            #expect(DoneEmoji.all.contains(next))
            previous = next
        }
    }

    @Test func remembersTheLast() {
        var emoji = DoneEmoji()
        #expect(emoji.last == nil)
        let picked = emoji.next()
        #expect(emoji.last == picked)
    }
}
