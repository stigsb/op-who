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
}
