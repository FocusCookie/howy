import Foundation
import Testing
@testable import HowyCore

@Suite struct CodeHighlighterTests {
    /// The code substrings coloured as `token`, in order.
    func covered(_ code: String, _ language: String?, _ token: CodeHighlighter.Token) -> [String] {
        let ns = code as NSString
        return CodeHighlighter.tokens(in: code, language: language)
            .filter { $0.token == token }
            .map { ns.substring(with: $0.range) }
    }

    @Test func jsonKeysStringsNumbersAndLiterals() {
        let code = #"{ "hello": true, "n": -1.5e3, "s": "a \"q\": b", "z": null }"#
        #expect(covered(code, "json", .property) == [#""hello""#, #""n""#, #""s""#, #""z""#])
        #expect(covered(code, "json", .string) == [#""a \"q\": b""#])
        #expect(covered(code, "json", .number) == ["-1.5e3"])
        #expect(covered(code, "json", .literal) == ["true", "null"])
    }

    @Test func languageNameIsCaseInsensitiveAndHasAliases() {
        #expect(covered("let x = 1", "Swift", .keyword) == ["let"])
        #expect(covered("const x = 1", "ts", .keyword) == ["const"])
        #expect(covered("def f(): pass", "py", .keyword) == ["def", "pass"])
    }

    @Test func commentMarkersInsideStringsStayString() {
        let code = "let url = \"http://x\" // note \"quoted\""
        #expect(covered(code, "swift", .string) == ["\"http://x\""])
        #expect(covered(code, "swift", .comment) == ["// note \"quoted\""])
    }

    @Test func blockCommentsSpanLinesAndRunToTheEndWhenOpen() {
        #expect(covered("a /* one\ntwo */ b", "js", .comment) == ["/* one\ntwo */"])
        #expect(covered("a /* open\nstill", "js", .comment) == ["/* open\nstill"])
    }

    @Test func wordsInsideNamesAreNotKeywords() {
        #expect(covered("letter = forest", "swift", .keyword).isEmpty)
    }

    @Test func swiftTypesAndAttributes() {
        let code = "@MainActor final class Store: Sendable {}"
        #expect(covered(code, "swift", .keyword) == ["@MainActor", "final", "class"])
        #expect(covered(code, "swift", .type) == ["Store", "Sendable"])
    }

    @Test func pythonAndShellHashComments() {
        #expect(covered("x = 1  # one", "python", .comment) == ["# one"])
        #expect(covered("echo $HOME # home", "sh", .comment) == ["# home"])
        #expect(covered("echo $HOME ${USER}", "sh", .property) == ["$HOME", "${USER}"])
    }

    @Test func yamlKeys() {
        let code = "name: Howy\nversion: 2\nlist:\n  - item: true"
        #expect(covered(code, "yaml", .property) == ["name", "version", "list", "  - item"])
        #expect(covered(code, "yaml", .literal) == ["true"])
    }

    @Test func unknownLanguageGetsStringsNumbersAndComments() {
        let code = "foo \"bar\" 42 // baz"
        #expect(covered(code, "brainfuck", .string) == ["\"bar\""])
        #expect(covered(code, nil, .number) == ["42"])
        #expect(covered(code, nil, .comment) == ["// baz"])
        #expect(covered(code, nil, .keyword).isEmpty)
    }

    @Test func rangesAreUTF16() {
        let code = #"{"🙂": "é"}"#
        let ns = code as NSString
        let ranges = CodeHighlighter.tokens(in: code, language: "json").map { ns.substring(with: $0.range) }
        #expect(ranges == [#""🙂""#, #""é""#])
    }
}

@Suite struct MarkdownCodeBlockTests {
    func covered(_ text: String, _ style: MarkdownStyleSpan.Style) -> [String] {
        let ns = text as NSString
        return MarkdownHighlighter.spans(in: text)
            .filter { $0.style == style }
            .sorted { $0.range.location < $1.range.location }
            .map { ns.substring(with: $0.range) }
    }

    @Test func bodyIsColouredByTheFenceLanguage() {
        let text = "```json\n{\n  \"helo\": true\n}\n```\n\"not code\""
        #expect(covered(text, .code(.property)) == ["\"helo\""])
        #expect(covered(text, .code(.literal)) == ["true"])
        #expect(covered(text, .code(.string)).isEmpty, "nothing outside the block, nothing in the fence")
    }

    @Test func fenceInfoAfterTheLanguageIsIgnored() {
        #expect(covered("~~~ swift title=x\nlet a = 1\n~~~", .code(.keyword)) == ["let"])
    }

    @Test func unclosedBlockIsColouredToo() {
        #expect(covered("```py\nimport os", .code(.keyword)) == ["import"])
    }

    @Test func codeBlocksListEachBlockWithItsFences() {
        let text = "a\n```\nx\n```\nb\n```js\ny"
        let ns = text as NSString
        #expect(MarkdownHighlighter.codeBlocks(in: text).map { ns.substring(with: $0) } == ["```\nx\n```", "```js\ny"])
    }
}
