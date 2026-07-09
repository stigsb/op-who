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
}
