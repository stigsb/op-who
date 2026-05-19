import Testing
import Foundation
import Darwin
@testable import OpWhoLib

private func node(_ name: String) -> ProcessNode {
    ProcessNode(
        pid: 100, ppid: 1, name: name, tty: nil,
        executablePath: nil, isVerifiedOnePasswordCLI: name == "verified-op"
    )
}

private func bridge(
    chain: [String] = ["git"],
    argv: [String] = ["git", "push", "origin", "main"],
    cwd: String? = "/Users/stig/git/repo",
    triggerCwd: String? = "/Users/stig/git/repo",
    pluginUpdate: ClaudePluginUpdate? = nil
) -> PredicateContext {
    let nodes = chain.map(node)
    let ctx = MatchContext(
        chain: nodes,
        triggerArgv: argv,
        cwd: cwd,
        triggerCwd: triggerCwd,
        claudeSession: nil,
        pluginUpdate: pluginUpdate,
        terminalBundleID: nil
    )
    return ctx.predicateBridge()
}

@Suite("PredicateContext")
struct PredicateContextTests {

    @Test func scalarEqualityOnTriggerName() {
        #expect(NSPredicate(format: "triggerName == %@", "git").evaluate(with: bridge()) == true)
        #expect(NSPredicate(format: "triggerName == %@", "ssh").evaluate(with: bridge()) == false)
    }

    @Test func anyOverArgvArray() {
        #expect(NSPredicate(format: "ANY triggerArgv == %@", "push").evaluate(with: bridge()) == true)
        #expect(NSPredicate(format: "ANY triggerArgv == %@", "pull").evaluate(with: bridge()) == false)
    }

    @Test func argvContainsAllViaAndedAny() {
        // The "list contains all of these" pattern users will reach for.
        let p = NSPredicate(format:
            "ANY triggerArgv == %@ AND ANY triggerArgv == %@",
            "push", "origin"
        )
        #expect(p.evaluate(with: bridge()) == true)
    }

    @Test func argvSetEqualityViaCountAndContains() {
        // Set-equality is expressible but verbose — capture that here so
        // future contributors don't accidentally break the idiom.
        let p = NSPredicate(format:
            "triggerArgv.@count == 4 AND ANY triggerArgv == %@ AND ANY triggerArgv == %@",
            "push", "origin"
        )
        #expect(p.evaluate(with: bridge()) == true)
    }

    @Test func subcommandLikeMatchingViaIn() {
        // What `subcommand IN {…}` will compile to once we no longer
        // have a parsed-subcommand field — predicates operate on the
        // raw argv array.
        let p = NSPredicate(format: "ANY triggerArgv IN %@", ["push", "fetch", "pull"])
        #expect(p.evaluate(with: bridge()) == true)
    }

    @Test func beginsWithOnTriggerCwd() {
        let p = NSPredicate(format: "triggerCwd BEGINSWITH %@", "/Users/stig")
        #expect(p.evaluate(with: bridge()) == true)
    }

    @Test func nilFieldIsFalseForBeginsWith() {
        let p = NSPredicate(format: "triggerCwd BEGINSWITH %@", "/")
        #expect(p.evaluate(with: bridge(triggerCwd: nil)) == false)
    }

    @Test func matchesRegexOnTriggerName() {
        let p = NSPredicate(format: "triggerName MATCHES %@", "g.+")
        #expect(p.evaluate(with: bridge()) == true)
    }

    @Test func chainNamesQuantifier() {
        let p = NSPredicate(format: "ANY chainNames == %@", "op")
        #expect(p.evaluate(with: bridge(chain: ["op", "ssh"])) == true)
        #expect(p.evaluate(with: bridge(chain: ["git"])) == false)
    }

    @Test func compoundExpression() {
        let p = NSPredicate(format:
            "triggerName == %@ AND ANY triggerArgv == %@ AND triggerCwd BEGINSWITH %@",
            "git", "push", "/Users/stig"
        )
        #expect(p.evaluate(with: bridge()) == true)
    }

    @Test func pluginUpdateFieldsFlattened() {
        let update = ClaudePluginUpdate(
            remoteURL: "https://github.com/example/plugin",
            repo: "example/plugin",
            sourceType: "github",
            marketplaceName: "Claude"
        )
        let b = bridge(pluginUpdate: update)
        #expect(NSPredicate(format: "pluginUpdateAvailable == YES").evaluate(with: b) == true)
        #expect(NSPredicate(format: "pluginRemoteURL CONTAINS %@", "github.com").evaluate(with: b) == true)
        #expect(NSPredicate(format: "pluginUpdateAvailable == YES").evaluate(with: bridge()) == false)
    }

    @Test func exposedKeysListsEveryProperty() {
        // Editor validation depends on this list being exhaustive — if
        // someone adds a new @objc property to PredicateContext, this
        // test fails until they remember to add it to exposedKeys.
        let mirrored = Set(Mirror(reflecting: bridge()).children.compactMap { $0.label })
        let declared = Set(PredicateContext.exposedKeys)
        #expect(mirrored.subtracting(declared).isEmpty,
                "PredicateContext has properties missing from exposedKeys: \(mirrored.subtracting(declared))")
    }
}
