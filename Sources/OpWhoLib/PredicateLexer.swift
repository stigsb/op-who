import Foundation

/// Token kinds the predicate highlighter cares about. Granular enough to
/// drive syntax colouring but coarser than a full NSPredicate parser —
/// we only need positions, not an AST.
public enum PredicateTokenKind: Equatable {
    case keyword
    case identifier
    case stringLiteral
    case numberLiteral
    case `operator`
    case punctuation
    case unknown
}

/// One lexed token. `range` is in UTF-16 units (matches NSAttributedString
/// / NSTextStorage), so it can be handed straight to attribute APIs.
public struct PredicateToken: Equatable {
    public let kind: PredicateTokenKind
    public let range: NSRange
    public let text: String

    public init(kind: PredicateTokenKind, range: NSRange, text: String) {
        self.kind = kind
        self.range = range
        self.text = text
    }
}

/// Minimal lexer for NSPredicate format strings. Emits tokens with
/// NSRange positions so the highlighter can colour them directly on an
/// `NSTextStorage`. Whitespace is consumed silently — we don't emit
/// tokens for it. Unknown characters produce a `.unknown` token so the
/// highlighter can flag them rather than skipping them invisibly.
public enum PredicateLexer {

    /// Case-insensitive set of NSPredicate keywords + boolean/null
    /// literals. NSPredicate's parser accepts these in any case; we
    /// normalise to uppercase before checking.
    public static let keywords: Set<String> = [
        // Logical connectives
        "AND", "OR", "NOT",
        // Quantifiers
        "ANY", "ALL", "NONE", "SOME",
        // Comparison-flavoured keywords
        "IN", "BETWEEN", "BEGINSWITH", "ENDSWITH", "CONTAINS",
        "MATCHES", "LIKE",
        // Whole-predicate literals
        "TRUEPREDICATE", "FALSEPREDICATE",
        // Value literals
        "YES", "NO", "TRUE", "FALSE", "NIL", "NULL",
        // Functions / specials
        "SELF", "FUNCTION", "SUBQUERY", "CAST",
    ]

    public static func tokenize(_ source: String) -> [PredicateToken] {
        var tokens: [PredicateToken] = []
        let chars = Array(source)
        var i = 0
        var utf16Offset = 0

        while i < chars.count {
            let startIdx = i
            let startOffset = utf16Offset
            let c = chars[i]

            if c.isWhitespace {
                utf16Offset += c.utf16.count
                i += 1
                continue
            }

            if c == "\"" || c == "'" {
                consumeStringLiteral(chars: chars, opener: c, i: &i, utf16Offset: &utf16Offset)
                tokens.append(PredicateToken(
                    kind: .stringLiteral,
                    range: NSRange(location: startOffset, length: utf16Offset - startOffset),
                    text: String(chars[startIdx..<i])
                ))
                continue
            }

            if isIdentifierStart(c) {
                consumeIdentifier(chars: chars, i: &i, utf16Offset: &utf16Offset)
                let text = String(chars[startIdx..<i])
                let kind: PredicateTokenKind = keywords.contains(text.uppercased()) ? .keyword : .identifier
                tokens.append(PredicateToken(
                    kind: kind,
                    range: NSRange(location: startOffset, length: utf16Offset - startOffset),
                    text: text
                ))
                continue
            }

            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                consumeNumber(chars: chars, i: &i, utf16Offset: &utf16Offset)
                tokens.append(PredicateToken(
                    kind: .numberLiteral,
                    range: NSRange(location: startOffset, length: utf16Offset - startOffset),
                    text: String(chars[startIdx..<i])
                ))
                continue
            }

            // Two-character operators come before single-character ones
            // so `==` isn't lexed as two `=` tokens.
            if i + 1 < chars.count {
                let two = "\(c)\(chars[i + 1])"
                if Self.twoCharOperators.contains(two) {
                    utf16Offset += c.utf16.count + chars[i + 1].utf16.count
                    i += 2
                    tokens.append(PredicateToken(
                        kind: .operator,
                        range: NSRange(location: startOffset, length: utf16Offset - startOffset),
                        text: two
                    ))
                    continue
                }
            }

            if Self.singleCharOperators.contains(c) {
                utf16Offset += c.utf16.count
                i += 1
                tokens.append(PredicateToken(
                    kind: .operator,
                    range: NSRange(location: startOffset, length: utf16Offset - startOffset),
                    text: String(c)
                ))
                continue
            }

            if Self.punctuationChars.contains(c) {
                utf16Offset += c.utf16.count
                i += 1
                tokens.append(PredicateToken(
                    kind: .punctuation,
                    range: NSRange(location: startOffset, length: utf16Offset - startOffset),
                    text: String(c)
                ))
                continue
            }

            // Anything else — emit as .unknown so the highlighter can flag it.
            utf16Offset += c.utf16.count
            i += 1
            tokens.append(PredicateToken(
                kind: .unknown,
                range: NSRange(location: startOffset, length: utf16Offset - startOffset),
                text: String(c)
            ))
        }
        return tokens
    }

    // MARK: - Internals

    private static let twoCharOperators: Set<String> = [
        "==", "!=", "<=", ">=", "<>", "&&", "||",
    ]
    private static let singleCharOperators: Set<Character> = ["=", "<", ">", "!"]
    private static let punctuationChars: Set<Character> = ["(", ")", "{", "}", ",", "."]

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c.isLetter || c == "_" || c == "@" || c == "$"
    }

    private static func isIdentifierContinue(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "@" || c == "."
    }

    private static func consumeStringLiteral(
        chars: [Character], opener: Character, i: inout Int, utf16Offset: inout Int
    ) {
        // Consume the opening quote.
        utf16Offset += chars[i].utf16.count
        i += 1
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\", i + 1 < chars.count {
                utf16Offset += ch.utf16.count
                utf16Offset += chars[i + 1].utf16.count
                i += 2
                continue
            }
            utf16Offset += ch.utf16.count
            i += 1
            if ch == opener { return }
        }
    }

    private static func consumeIdentifier(
        chars: [Character], i: inout Int, utf16Offset: inout Int
    ) {
        // First char already validated by caller.
        utf16Offset += chars[i].utf16.count
        i += 1
        while i < chars.count, isIdentifierContinue(chars[i]) {
            utf16Offset += chars[i].utf16.count
            i += 1
        }
    }

    private static func consumeNumber(
        chars: [Character], i: inout Int, utf16Offset: inout Int
    ) {
        var sawDot = false
        while i < chars.count {
            let ch = chars[i]
            if ch.isNumber {
                utf16Offset += ch.utf16.count
                i += 1
            } else if ch == "." && !sawDot {
                sawDot = true
                utf16Offset += ch.utf16.count
                i += 1
            } else {
                break
            }
        }
    }
}
