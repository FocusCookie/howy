import Foundation

/// Finds the tokens to colour in the body of a fenced code block, by the fence's language
/// ("```json"). Simple per-language rules (strings, comments, numbers, keywords, ...), not a parser:
/// good enough for a note. Ranges are UTF-16 (`NSRange`) in the code passed in.
///
/// Known languages: JSON, Swift, JavaScript / TypeScript, Python, shell, YAML, plus their usual
/// short names ("js", "ts", "py", "sh", "zsh", "yml"). Any other language, or none, gets strings,
/// numbers and comments only.
public enum CodeHighlighter {
    public enum Token: Hashable, Sendable {
        case keyword
        /// `true`, `false`, `null`, `nil`, `None` ...
        case literal
        case string
        case number
        case comment
        /// A key in JSON or YAML.
        case property
        /// A capitalised name (Swift, JavaScript / TypeScript).
        case type
    }

    public static func tokens(in code: String, language: String?) -> [(token: Token, range: NSRange)] {
        guard !code.isEmpty else { return [] }
        let grammar = Grammar.for(language)
        var tokens: [(Token, NSRange)] = []
        // One alternation, scanned left to right: the earliest match wins, so a `//` inside a
        // string stays string and a quote inside a comment stays comment.
        for match in grammar.regex.matches(in: code, range: NSRange(location: 0, length: (code as NSString).length)) {
            for (index, token) in grammar.tokens.enumerated() where match.range(at: index + 1).location != NSNotFound {
                tokens.append((token, match.range(at: index + 1)))
                break
            }
        }
        return tokens
    }

    // MARK: Grammars

    private struct Grammar {
        let regex: NSRegularExpression
        let tokens: [Token]

        /// Rules in priority order; each pattern must not have capture groups of its own.
        init(_ rules: [(Token, String)]) {
            tokens = rules.map(\.0)
            let pattern = rules.map { "(\($0.1))" }.joined(separator: "|")
            // swiftlint:disable:next force_try
            regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) // fixed, covered by tests
        }

        static func `for`(_ language: String?) -> Grammar {
            switch language?.lowercased() {
            case "json", "jsonc", "json5": json
            case "swift": swift
            case "js", "javascript", "jsx", "mjs", "ts", "typescript", "tsx": javaScript
            case "py", "python": python
            case "sh", "bash", "zsh", "shell", "console": shell
            case "yaml", "yml": yaml
            default: generic
            }
        }

        private static func words(_ list: String) -> String {
            #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
        }

        private static let doubleQuoted = #""(?:[^"\\\n]|\\.)*""#
        private static let singleQuoted = #"'(?:[^'\\\n]|\\.)*'"#
        private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
        private static let lineComment = #"//.*"#
        private static let blockComment = #"/\*[\s\S]*?(?:\*/|$(?![\s\S]))"#
        private static let hashComment = #"(?<![\w$])#.*"#
        private static let capitalised = #"\b[A-Z][A-Za-z0-9_]*\b"#

        static let json = Grammar([
            (.comment, lineComment), (.comment, blockComment),
            (.property, doubleQuoted + #"(?=\s*:)"#),
            (.string, doubleQuoted),
            (.literal, words("true false null")),
            (.number, #"-?"# + number),
        ])

        static let swift = Grammar([
            (.comment, lineComment), (.comment, blockComment),
            (.string, #""""[\s\S]*?(?:"""|$(?![\s\S]))"#),
            (.string, doubleQuoted),
            (.literal, words("true false nil self Self super")),
            (.keyword, words("""
                actor associatedtype async await break case catch class continue default defer deinit do else enum \
                extension fallthrough fileprivate final for func guard if import in init inout internal is lazy let \
                mutating nonisolated open operator override private protocol public repeat rethrows return some any \
                static struct subscript switch throw throws try typealias var weak where while
                """)),
            (.keyword, #"@\w+"#),
            (.type, capitalised),
            (.number, number),
        ])

        static let javaScript = Grammar([
            (.comment, lineComment), (.comment, blockComment),
            (.string, doubleQuoted), (.string, singleQuoted),
            (.string, #"`(?:[^`\\]|\\.)*`"#),
            (.literal, words("true false null undefined this NaN Infinity")),
            (.keyword, words("""
                as async await break case catch class const continue debugger default delete do else enum export \
                extends finally for from function if implements import in instanceof interface let new of private \
                protected public readonly return static super switch throw try type typeof var void while yield
                """)),
            (.type, capitalised),
            (.number, number),
        ])

        static let python = Grammar([
            (.comment, hashComment),
            (.string, #"(?:"""[\s\S]*?(?:"""|$(?![\s\S]))|'''[\s\S]*?(?:'''|$(?![\s\S])))"#),
            (.string, doubleQuoted), (.string, singleQuoted),
            (.literal, words("True False None self")),
            (.keyword, words("""
                and as assert async await break class continue def del elif else except finally for from global if \
                import in is lambda match case nonlocal not or pass raise return try while with yield
                """)),
            (.keyword, #"@\w+"#),
            (.number, number),
        ])

        static let shell = Grammar([
            (.comment, hashComment),
            (.string, doubleQuoted), (.string, singleQuoted),
            (.keyword, words("if then else elif fi for in do done while until case esac function return export local")),
            (.property, #"\$\{[^}\n]*\}|\$\w+"#),
            (.number, number),
        ])

        static let yaml = Grammar([
            (.comment, hashComment),
            (.property, #"^[ \t]*(?:- )?[\w.\-"' ]+?(?=:(?:\s|$))"#),
            (.string, doubleQuoted), (.string, singleQuoted),
            (.literal, words("true false null yes no on off")),
            (.number, number),
        ])

        static let generic = Grammar([
            (.comment, lineComment), (.comment, blockComment),
            (.string, doubleQuoted),
            (.number, number),
        ])
    }
}
