import Testing
import Foundation
import Darwin
@testable import OpWhoLib

@Suite("TriggerEntryBuilder")
struct TriggerEntryBuilderTests {
    // Synthetic chain with no TTY/terminal/Claude so the builder never
    // calls AppleScript or reads cmux state during tests.
    private func selfNode(_ name: String) -> ProcessNode {
        ProcessNode(pid: getpid(), ppid: 1, name: name, tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: false)
    }

    private func result(chain: [ProcessNode], appBundleID: String? = nil) -> ChainResult {
        ChainResult(
            chain: chain, tty: nil, terminalBundleID: nil, terminalPID: nil,
            hasClaudeCode: false, claudePID: nil, scriptInfo: nil,
            appBundleID: appBundleID, appPID: appBundleID == nil ? nil : 77
        )
    }

    private let emptyChainRule = RequestRule(
        name: "empty", predicate: #"triggerName == """#, template: "needs a login", kind: .oidcLogin
    )

    @Test func usesGivenRulesAndSource() {
        let node = selfNode("kubectl")
        let rules = [RequestRule(
            name: "t", predicate: "TRUEPREDICATE", template: "did {process}", kind: .unknown
        )]
        let entry = TriggerEntryBuilder.makeEntry(
            foldedChain: [node], fallbackNode: node, chainResult: result(chain: [node]),
            triggerArgv: ["kubectl", "get", "pods"], rules: rules, source: .oidcLogin
        )
        #expect(entry.pid == getpid())
        #expect(entry.source == .oidcLogin)
        #expect(entry.summary.title.hasSuffix("did kubectl"))
        #expect(entry.matchedRuleName == "t")
    }

    @Test func emptyChainUsesFallbackNodeAndAppActor() {
        let helper = selfNode("kubelogin")
        // A bundle ID that is not installed displays as itself.
        let bundleID = "com.example.op-who-tests.not-installed"
        let entry = TriggerEntryBuilder.makeEntry(
            foldedChain: [], fallbackNode: helper,
            chainResult: result(chain: [helper], appBundleID: bundleID),
            triggerArgv: [], rules: [emptyChainRule], source: .oidcLogin
        )
        #expect(entry.pid == getpid())
        #expect(entry.chain.isEmpty)
        #expect(entry.appBundleID == bundleID)
        #expect(entry.appPID == 77)
        #expect(entry.appName == bundleID)
        #expect(entry.summary.title == "\(bundleID) needs a login")
        #expect(entry.summary.kind == .oidcLogin)
    }

    @Test func onePasswordEntriesCarryNoAppName() {
        let node = selfNode("ssh")
        let entry = TriggerEntryBuilder.makeEntry(
            foldedChain: [node], fallbackNode: node,
            chainResult: result(chain: [node], appBundleID: "com.example.op-who-tests.not-installed"),
            triggerArgv: ["ssh", "host"], rules: RequestRule.builtIns, source: .onePassword
        )
        #expect(entry.source == .onePassword)
        #expect(entry.appName == nil)
    }

    @Test func appNameIsActorOnlyForEmptyChain() {
        let rule = RequestRule(name: "t", predicate: "TRUEPREDICATE", template: "x", kind: .unknown)
        let empty = makeRequestSummary(
            chain: [], triggerArgv: [], tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil, rules: [rule], appName: "Visual Studio Code"
        )
        #expect(empty.title == "Visual Studio Code x")

        let noApp = makeRequestSummary(
            chain: [], triggerArgv: [], tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil, rules: [rule]
        )
        #expect(noApp.title == "An unknown process x")

        let withChain = makeRequestSummary(
            chain: [selfNode("zsh")], triggerArgv: [], tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil, rules: [rule], appName: "Visual Studio Code"
        )
        #expect(withChain.title == "Your zsh shell x")
    }

    @Test func ttyMessageNamesTheSource() {
        #expect(RequestSource.onePassword.ttyMessage.contains("1Password approval"))
        #expect(RequestSource.oidcLogin.ttyMessage.contains("OIDC login"))
    }
}
