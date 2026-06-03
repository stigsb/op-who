import Testing
import Foundation
@testable import OpWhoLib

@Suite("UpdateChecker version logic")
struct UpdateCheckerVersionTests {

    @Test func parsesBareVersion() {
        #expect(UpdateChecker.parseVersion("0.9.0") == [0, 9, 0])
    }

    @Test func stripsLeadingV() {
        #expect(UpdateChecker.parseVersion("v0.9.0") == [0, 9, 0])
        #expect(UpdateChecker.parseVersion("V1.2.3") == [1, 2, 3])
    }

    @Test func rejectsMalformedVersion() {
        #expect(UpdateChecker.parseVersion("") == nil)
        #expect(UpdateChecker.parseVersion("v") == nil)
        #expect(UpdateChecker.parseVersion("1.x.0") == nil)
        #expect(UpdateChecker.parseVersion("nightly") == nil)
    }

    @Test func comparesNumericallyNotLexically() {
        // Lexical compare would say "0.10.0" < "0.9.0"; numeric must not.
        #expect(UpdateChecker.compare([0, 10, 0], [0, 9, 0]) == .orderedDescending)
        #expect(UpdateChecker.compare([0, 9, 0], [0, 10, 0]) == .orderedAscending)
    }

    @Test func comparesEqualVersions() {
        #expect(UpdateChecker.compare([0, 8, 0], [0, 8, 0]) == .orderedSame)
    }

    @Test func comparesDifferentComponentCounts() {
        // Shorter version is zero-padded: 1.2 == 1.2.0, and 1.2.1 > 1.2.
        #expect(UpdateChecker.compare([1, 2], [1, 2, 0]) == .orderedSame)
        #expect(UpdateChecker.compare([1, 2, 1], [1, 2]) == .orderedDescending)
    }
}
