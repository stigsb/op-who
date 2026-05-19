import Testing
import Foundation
@testable import OpWhoLib

@Suite("PredicateParser")
struct PredicateParserTests {

    @Test func parsesValidFormat() throws {
        let p = try PredicateParser.parse("triggerName == \"git\"")
        #expect(p.predicateFormat.contains("triggerName"))
    }

    @Test func throwsOnUnclosedString() {
        #expect(throws: PredicateParseError.self) {
            _ = try PredicateParser.parse("triggerName == \"git")
        }
    }

    @Test func throwsOnUnknownOperator() {
        #expect(throws: PredicateParseError.self) {
            _ = try PredicateParser.parse("triggerName SUPERGLU \"git\"")
        }
    }

    @Test func throwsOnTrailingJunk() {
        #expect(throws: PredicateParseError.self) {
            _ = try PredicateParser.parse("triggerName == \"git\" AND")
        }
    }

    @Test func validateReturnsNilOnSuccess() {
        #expect(PredicateParser.validate("triggerName == \"git\"") == nil)
    }

    @Test func validateReturnsErrorOnFailure() {
        let err = PredicateParser.validate("garbage ==")
        #expect(err != nil)
    }

    @Test func parseErrorCarriesMessage() {
        do {
            _ = try PredicateParser.parse("garbage ==")
            Issue.record("expected throw")
        } catch let error as PredicateParseError {
            switch error {
            case .invalidFormat(let message):
                #expect(!message.isEmpty)
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func roundTripsThroughEvaluation() throws {
        // End-to-end: parsed predicate evaluates against a real bridge.
        let p = try PredicateParser.parse("triggerName == \"git\" AND ANY triggerArgv == \"push\"")
        let node = ProcessNode(
            pid: 1, ppid: 0, name: "git", tty: nil,
            executablePath: nil, isVerifiedOnePasswordCLI: false
        )
        let ctx = MatchContext(
            chain: [node], triggerArgv: ["git", "push"],
            cwd: nil, triggerCwd: nil, claudeSession: nil,
            pluginUpdate: nil, terminalBundleID: nil
        )
        #expect(p.evaluate(with: ctx.predicateBridge()) == true)
    }
}
