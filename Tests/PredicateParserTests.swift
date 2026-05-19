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

    @Test func expandsLeadingTildeWithSlash() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = expandLeadingTildes(in: #"triggerCwd BEGINSWITH "~/git/foo""#)
        #expect(expanded == #"triggerCwd BEGINSWITH "\#(home)/git/foo""#)
    }

    @Test func expandsLoneTildeInString() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = expandLeadingTildes(in: #"triggerCwd == "~""#)
        #expect(expanded == #"triggerCwd == "\#(home)""#)
    }

    @Test func expandsTildeInsideInCollection() {
        // Multiple quoted literals in a single predicate: every one
        // gets the leading tilde swapped for $HOME independently.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = expandLeadingTildes(in: #"triggerCwd IN {"~/a","~/b","/abs/c"}"#)
        #expect(expanded == #"triggerCwd IN {"\#(home)/a","\#(home)/b","/abs/c"}"#)
    }

    @Test func doesNotExpandTildeInMiddleOfString() {
        let input = #"name == "foo~bar""#
        #expect(expandLeadingTildes(in: input) == input)
    }

    @Test func doesNotExpandTildeOutsideStringLiterals() {
        // The bare `~` between operands isn't a quoted-string tilde —
        // leave it alone so we don't mangle anything weird the parser
        // might be doing with it. NSPredicate will reject it on its own.
        let input = "foo ~ bar"
        #expect(expandLeadingTildes(in: input) == input)
    }

    @Test func leavesEscapedQuoteAloneInsideString() {
        // \" inside a string literal must not be treated as a closer —
        // otherwise the next " would be read as opening a new string
        // and a leading ~ there would get expanded incorrectly.
        let input = #"name == "she said \"hi\"" AND triggerCwd BEGINSWITH "~/work""#
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = expandLeadingTildes(in: input)
        #expect(expanded == #"name == "she said \"hi\"" AND triggerCwd BEGINSWITH "\#(home)/work""#)
    }

    @Test func parseAppliesTildeExpansionEndToEnd() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let predicate = try PredicateParser.parse(#"triggerCwd BEGINSWITH "~/git""#)
        let node = ProcessNode(
            pid: 1, ppid: 0, name: "git", tty: nil,
            executablePath: nil, isVerifiedOnePasswordCLI: false
        )
        let inside = MatchContext(
            chain: [node], triggerArgv: [],
            cwd: nil, triggerCwd: "\(home)/git/foo",
            claudeSession: nil, pluginUpdate: nil, terminalBundleID: nil
        )
        let outside = MatchContext(
            chain: [node], triggerArgv: [],
            cwd: nil, triggerCwd: "/tmp",
            claudeSession: nil, pluginUpdate: nil, terminalBundleID: nil
        )
        #expect(predicate.evaluate(with: inside.predicateBridge()) == true)
        #expect(predicate.evaluate(with: outside.predicateBridge()) == false)
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
