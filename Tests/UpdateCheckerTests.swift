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

    @Test func rejectsNegativeComponents() {
        #expect(UpdateChecker.parseVersion("1.-1.0") == nil)
    }
}

@Suite("UpdateChecker release evaluation")
struct UpdateCheckerEvaluateTests {

    private func releaseJSON(tag: String, url: String = "https://github.com/stigsb/op-who/releases/tag/x") -> Data {
        """
        {"tag_name": "\(tag)", "html_url": "\(url)", "name": "ignored"}
        """.data(using: .utf8)!
    }

    @Test func reportsUpdateAvailableWhenRemoteNewer() {
        let url = "https://github.com/stigsb/op-who/releases/tag/v0.9.0"
        let result = UpdateChecker.evaluate(responseData: releaseJSON(tag: "v0.9.0", url: url),
                                            currentVersion: "0.8.0")
        #expect(result == .updateAvailable(latest: "0.9.0", releaseURL: URL(string: url)!))
    }

    @Test func reportsUpToDateWhenEqual() {
        let result = UpdateChecker.evaluate(responseData: releaseJSON(tag: "v0.8.0"),
                                            currentVersion: "0.8.0")
        #expect(result == .upToDate(current: "0.8.0"))
    }

    @Test func reportsUpToDateWhenRemoteOlder() {
        let result = UpdateChecker.evaluate(responseData: releaseJSON(tag: "v0.7.0"),
                                            currentVersion: "0.8.0")
        #expect(result == .upToDate(current: "0.8.0"))
    }

    @Test func failsOnMalformedTag() {
        let result = UpdateChecker.evaluate(responseData: releaseJSON(tag: "nightly"),
                                            currentVersion: "0.8.0")
        if case .failed = result { } else { Issue.record("expected .failed, got \(result)") }
    }

    @Test func failsOnGarbageJSON() {
        let result = UpdateChecker.evaluate(responseData: Data("not json".utf8),
                                            currentVersion: "0.8.0")
        if case .failed = result { } else { Issue.record("expected .failed, got \(result)") }
    }

    @Test func reportsUpdateAvailableWhenCurrentVersionUnparseable() {
        let url = "https://github.com/stigsb/op-who/releases/tag/v1.0.0"
        let result = UpdateChecker.evaluate(responseData: releaseJSON(tag: "v1.0.0", url: url),
                                            currentVersion: "unknown")
        #expect(result == .updateAvailable(latest: "1.0.0", releaseURL: URL(string: url)!))
    }
}
