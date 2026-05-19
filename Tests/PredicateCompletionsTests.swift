import Testing
import Foundation
@testable import OpWhoLib

@Suite("PredicateCompletions")
struct PredicateCompletionsTests {

    @Test func emptyPartialReturnsIdentifiersThenKeywords() {
        let result = PredicateCompletions.candidates(forPartialWord: "")
        for key in PredicateContext.exposedKeys {
            #expect(result.contains(key), "expected exposed key \(key) in completions")
        }
        for kw in PredicateLexer.keywords {
            #expect(result.contains(kw), "expected keyword \(kw) in completions")
        }
        // Identifiers come first, then keywords. The first identifier
        // (sorted) should appear before any keyword.
        let sortedIdentifiers = PredicateContext.exposedKeys.sorted()
        let sortedKeywords = PredicateLexer.keywords.sorted()
        let firstIdentifierIdx = result.firstIndex(of: sortedIdentifiers.first!)!
        let firstKeywordIdx = result.firstIndex(of: sortedKeywords.first!)!
        #expect(firstIdentifierIdx < firstKeywordIdx)

        // Identifiers in result preserve insertion order: sorted alphabetically.
        let identifiersInResult = result.filter { PredicateContext.exposedKeys.contains($0) }
        #expect(identifiersInResult == sortedIdentifiers)
        let keywordsInResult = result.filter { PredicateLexer.keywords.contains($0) }
        #expect(keywordsInResult == sortedKeywords)
    }

    @Test func partialMatchesOnlyIdentifiers() {
        let result = PredicateCompletions.candidates(forPartialWord: "trigger")
        #expect(result == ["triggerArgv", "triggerCwd", "triggerName"])
    }

    @Test func partialMatchesKeywordsSorted() {
        let result = PredicateCompletions.candidates(forPartialWord: "AN")
        #expect(result == ["ALL", "AND", "ANY"].filter { $0.hasPrefix("AN") })
        // Belt-and-braces: exactly AND and ANY, both keywords with the AN prefix.
        #expect(result == ["AND", "ANY"])
    }

    @Test func caseInsensitivePrefixMatch() {
        let lower = PredicateCompletions.candidates(forPartialWord: "trigger")
        let upper = PredicateCompletions.candidates(forPartialWord: "TRIGGER")
        let mixed = PredicateCompletions.candidates(forPartialWord: "Trigger")
        #expect(lower == upper)
        #expect(lower == mixed)
        // And original case is preserved (lowercase identifiers, not uppercased).
        #expect(lower.contains("triggerArgv"))
        #expect(!lower.contains("TRIGGERARGV"))
    }

    @Test func noMatchesReturnsEmpty() {
        #expect(PredicateCompletions.candidates(forPartialWord: "zzz") == [])
    }

    @Test func keywordMatchPreservesUpperCase() {
        let result = PredicateCompletions.candidates(forPartialWord: "begin")
        #expect(result == ["BEGINSWITH"])
    }
}
