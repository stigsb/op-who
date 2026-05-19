import Testing
import Foundation
@testable import OpWhoLib

@Suite("PredicateLexer")
struct PredicateLexerTests {

    private func kinds(_ source: String) -> [PredicateTokenKind] {
        PredicateLexer.tokenize(source).map(\.kind)
    }

    private func texts(_ source: String) -> [String] {
        PredicateLexer.tokenize(source).map(\.text)
    }

    @Test func tokenisesSimpleEquality() {
        #expect(texts("triggerName == \"git\"") == ["triggerName", "==", "\"git\""])
        #expect(kinds("triggerName == \"git\"") == [.identifier, .operator, .stringLiteral])
    }

    @Test func keywordsAreRecognisedCaseInsensitively() {
        let result = PredicateLexer.tokenize("a AND b or NOT c")
        #expect(result.map(\.kind) == [
            .identifier, .keyword, .identifier, .keyword, .keyword, .identifier
        ])
        #expect(result.filter { $0.kind == .keyword }.map(\.text) == ["AND", "or", "NOT"])
    }

    @Test func quantifiersAndComparators() {
        let kinds = self.kinds("ANY triggerArgv BEGINSWITH \"--\"")
        #expect(kinds == [.keyword, .identifier, .keyword, .stringLiteral])
    }

    @Test func inCollectionLiteral() {
        let toks = PredicateLexer.tokenize("subcommand IN {\"a\",\"b\"}")
        #expect(toks.map(\.kind) == [
            .identifier, .keyword, .punctuation,
            .stringLiteral, .punctuation, .stringLiteral,
            .punctuation,
        ])
        #expect(toks.filter { $0.kind == .stringLiteral }.map(\.text) == ["\"a\"", "\"b\""])
    }

    @Test func numbersIntAndFloat() {
        let toks = PredicateLexer.tokenize("count == 42 AND ratio == 3.14")
        let nums = toks.filter { $0.kind == .numberLiteral }.map(\.text)
        #expect(nums == ["42", "3.14"])
    }

    @Test func keypathsAreOneIdentifier() {
        let toks = PredicateLexer.tokenize("triggerArgv.@count > 2")
        #expect(toks.map(\.kind) == [.identifier, .operator, .numberLiteral])
        #expect(toks[0].text == "triggerArgv.@count")
    }

    @Test func rangesAreUTF16Offsets() {
        // Plain ASCII case — UTF-16 count equals character count.
        let source = "x == 1"
        let toks = PredicateLexer.tokenize(source)
        #expect(toks[0].range == NSRange(location: 0, length: 1))
        #expect(toks[1].range == NSRange(location: 2, length: 2))
        #expect(toks[2].range == NSRange(location: 5, length: 1))
    }

    @Test func unicodeStringLiteralAdvancesUtf16Correctly() {
        // The é and 你 are multi-byte in UTF-8 but single UTF-16 units;
        // an emoji like 🚀 takes two UTF-16 units. Make sure subsequent
        // token positions account for that.
        let source = "name == \"naïve你🚀\" AND x"
        let toks = PredicateLexer.tokenize(source)
        // Recover each token by slicing the source by its NSRange and
        // confirming it matches `text`.
        let nsSource = source as NSString
        for tok in toks {
            #expect(nsSource.substring(with: tok.range) == tok.text)
        }
    }

    @Test func escapedQuoteStaysInsideString() {
        // \" inside a string mustn't end the literal early.
        let toks = PredicateLexer.tokenize(#"name == "she said \"hi\"""#)
        #expect(toks.map(\.kind) == [.identifier, .operator, .stringLiteral])
        #expect(toks[2].text == #""she said \"hi\"""#)
    }

    @Test func unknownCharactersAreFlagged() {
        let toks = PredicateLexer.tokenize("x § y")
        let unknown = toks.first { $0.kind == .unknown }
        #expect(unknown?.text == "§")
    }

    @Test func punctuationTokens() {
        let toks = PredicateLexer.tokenize("(a, b)")
        #expect(toks.map(\.kind) == [
            .punctuation, .identifier, .punctuation, .identifier, .punctuation
        ])
    }

    @Test func operatorsAreLexedAsUnits() {
        // == must not become two = tokens; <= and != likewise.
        let toks = PredicateLexer.tokenize("a == b <= c != d")
        let ops = toks.filter { $0.kind == .operator }.map(\.text)
        #expect(ops == ["==", "<=", "!="])
    }
}
