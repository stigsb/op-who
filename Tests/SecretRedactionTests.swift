import Testing
@testable import OpWhoLib

@Suite("Secret redaction")
struct SecretRedactionTests {

    @Test func entropyIsZeroForEmptyAndUniform() {
        #expect(shannonEntropy("") == 0)
        #expect(shannonEntropy("aaaaaaaa") == 0)
    }

    @Test func entropyIsHigherForRandomThanRepeated() {
        #expect(shannonEntropy("wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY") > 4.0)
        #expect(shannonEntropy("abababababab") < 1.5)
    }

    @Test func placeholderIsAngleQuoted() {
        #expect(secretRedactionPlaceholder == "‹redacted›")
    }

    @Test func entropyLayerRedactsLongRandomBlob() {
        #expect(redactHighEntropy("wJalrXUtnFEMIK7MDENGbPxRfiCYz9qLpTvBhKmN") == secretRedactionPlaceholder)
    }

    @Test func entropyLayerRedactsValueAfterEquals() {
        #expect(redactHighEntropy("--secret=wJalrXUtnFEMIK7MDENGbPxRfiCYz9qLpTvBhKmN")
                == "--secret=" + secretRedactionPlaceholder)
    }

    @Test func entropyLayerKeepsPathsAndShortWordsAndUris() {
        #expect(redactHighEntropy("/usr/local/bin/op") == "/usr/local/bin/op")
        #expect(redactHighEntropy("op://Personal/GitHub/token") == "op://Personal/GitHub/token")
        #expect(redactHighEntropy("item create") == "item create")
        #expect(redactHighEntropy("short") == "short")
    }

    @Test func knownPatternsRedactStructuredTokens() {
        #expect(redactKnownPatterns("AKIAIOSFODNN7EXAMPLE") == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("ghp_" + String(repeating: "a", count: 36)) == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("xoxb-123456789012-abcdefabcdef") == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("AIza" + String(repeating: "b", count: 35)) == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("eyJhbGc.eyJzdWI.SflKxwRJ") == secretRedactionPlaceholder)
        #expect(redactKnownPatterns("-----BEGIN OPENSSH PRIVATE KEY-----") == secretRedactionPlaceholder)
    }

    @Test func knownPatternsKeepBearerAndUrlPrefix() {
        #expect(redactKnownPatterns("Authorization: Bearer abcdef123456")
                == "Authorization: Bearer " + secretRedactionPlaceholder)
        #expect(redactKnownPatterns("https://user:hunter2@example.com")
                == "https://user:" + secretRedactionPlaceholder + "@example.com")
    }

    @Test func knownPatternsLeaveOrdinaryTextAlone() {
        #expect(redactKnownPatterns("op item get GitHub") == "op item get GitHub")
    }
}
