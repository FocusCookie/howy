import Foundation
import Testing
@testable import HowyCore

@Suite struct DeepLinkTests {
    static let id = UUID(uuidString: "6F1C2B8E-4C7A-4E59-9A41-1E2D3C4B5A69")!

    @Test(arguments: [
        DeepLink.edit(id),
        .quickAdd(nil),
        .quickAdd(.urgentImportant),
        .quickAdd(.notUrgentImportant),
        .quickAdd(.urgentUnimportant),
        .quickAdd(.notUrgentUnimportant),
        .archive,
    ])
    func roundTrip(link: DeepLink) {
        #expect(link.url.scheme == "howy")
        #expect(DeepLink(url: link.url) == link)
    }

    @Test func urlShapes() {
        #expect(DeepLink.edit(Self.id).url.absoluteString == "howy://edit/6F1C2B8E-4C7A-4E59-9A41-1E2D3C4B5A69")
        #expect(DeepLink.quickAdd(.urgentUnimportant).url.absoluteString == "howy://quick-add/3")
        #expect(DeepLink.quickAdd(nil).url.absoluteString == "howy://quick-add")
        #expect(DeepLink.archive.url.absoluteString == "howy://archive")
        #expect(DeepLink.scheme == "howy")
    }

    @Test func parsingIsLenientAboutCaseAndTrailingSlash() {
        #expect(DeepLink(url: URL(string: "HOWY://Archive/")!) == .archive)
        #expect(DeepLink(url: URL(string: "howy://edit/6f1c2b8e-4c7a-4e59-9a41-1e2d3c4b5a69")!) == .edit(Self.id))
    }

    @Test(arguments: [
        "https://edit/6F1C2B8E-4C7A-4E59-9A41-1E2D3C4B5A69",
        "howy://edit",
        "howy://edit/not-a-uuid",
        "howy://quick-add/0",
        "howy://quick-add/5",
        "howy://quick-add/x",
        "howy://archive/extra",
        "howy://unknown",
        "howy:",
    ])
    func rejectsInvalidURLs(string: String) throws {
        let url = try #require(URL(string: string))
        #expect(DeepLink(url: url) == nil)
    }
}
