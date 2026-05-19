import Testing
import Foundation
import Darwin
@testable import OpWhoLib

private func node(_ name: String, pid: pid_t = 100, verified: Bool = false) -> ProcessNode {
    ProcessNode(
        pid: pid, ppid: 1, name: name, tty: nil,
        executablePath: nil, isVerifiedOnePasswordCLI: verified
    )
}

private func ctx(
    chain: [ProcessNode],
    argv: [String] = [],
    cwd: String? = nil,
    triggerCwd: String? = nil,
    claudeSession: String? = nil,
    pluginUpdate: ClaudePluginUpdate? = nil,
    terminalBundleID: String? = nil
) -> MatchContext {
    MatchContext(
        chain: chain, triggerArgv: argv, cwd: cwd, triggerCwd: triggerCwd,
        claudeSession: claudeSession, pluginUpdate: pluginUpdate,
        terminalBundleID: terminalBundleID
    )
}

@Suite("Built-in predicates")
struct BuiltInPredicateTests {

    @Test func everyBuiltInPredicateParses() throws {
        // First line of defence: any rewrite of the built-in ruleset
        // must keep every predicate string parse-able. A regression
        // here would otherwise only surface at engine evaluation time.
        for rule in RequestRule.builtIns {
            _ = try PredicateParser.parse(rule.predicate)
        }
    }
}

@Suite("renderTemplate")
struct RenderTemplateTests {

    @Test func simplePlaceholders() {
        let c = ctx(chain: [node("git")], argv: ["git", "fetch", "origin"])
        #expect(renderTemplate("needs an SSH key for ‘git {subcommand}’", context: c) == "needs an SSH key for ‘git fetch’")
    }

    @Test func emptyPlaceholderCausesFallthrough() {
        // {op_uri} not present → render returns nil so the engine moves on.
        let c = ctx(chain: [node("op", verified: true)], argv: ["op", "read"])
        #expect(renderTemplate("wants to read {op_uri}", context: c) == nil)
    }

    @Test func unknownPlaceholderTreatedAsEmpty() {
        let c = ctx(chain: [node("op")])
        #expect(renderTemplate("hello {nope} world", context: c) == nil)
    }

    @Test func processPlaceholderFallsBackToQuestionMark() {
        // Fallback rule uses {process}; empty chain must still render so the
        // engine produces SOMETHING for unclassifiable triggers.
        let c = ctx(chain: [])
        #expect(renderTemplate("triggered 1Password (via ‘{process}’)", context: c) == "triggered 1Password (via ‘?’)")
    }

    @Test func argvIndexPlaceholder() {
        let c = ctx(chain: [node("op", verified: true)], argv: ["op", "item", "get", "GitHub"])
        #expect(renderTemplate("op {argv[1]} {argv[2]}", context: c) == "op item get")
        // Out-of-bounds index → empty → fallthrough.
        #expect(renderTemplate("op {argv[1]} {argv[9]}", context: c) == nil)
    }

    @Test func cwdSlashTreatedAsEmpty() {
        // "/" is not a useful cwd to surface; rules referencing {cwd} should
        // fall through when the chain only resolved to root.
        let c = ctx(chain: [node("op-ssh-sign")], argv: ["op-ssh-sign", "sign", "git"], cwd: "/")
        #expect(renderTemplate("is signing a commit in {cwd}", context: c) == nil)
        let c2 = ctx(chain: [node("op-ssh-sign")], argv: ["op-ssh-sign", "sign", "git"], cwd: "~/proj")
        #expect(renderTemplate("is signing a commit in {cwd}", context: c2) == "is signing a commit in ~/proj")
    }

    @Test func opPhrasePlaceholder() {
        let c = ctx(chain: [node("op", verified: false)], argv: ["op", "read", "op://X/Y"])
        #expect(renderTemplate("({op_phrase})", context: c) == "(read op://X/Y)")
    }
}

@Suite("RequestRuleEngine")
struct RequestRuleEngineTests {

    @Test func defaultsMatchPluginUpdateFirst() {
        // Marketplace lookup populated repo + sourceType → 1a wins and
        // renders the structured form.
        let update = ClaudePluginUpdate(
            remoteURL: "git@github.com:cloudflare/skills.git",
            repo: "cloudflare/skills",
            sourceType: "github",
            marketplaceName: "cloudflare"
        )
        let c = ctx(
            chain: [node("git"), node("node"), node("claude")],
            argv: ["git", "pull", "origin", "HEAD"],
            cwd: "~/.claude/plugins/marketplaces/cloudflare",
            triggerCwd: "/Users/x/.claude/plugins/marketplaces/cloudflare",
            claudeSession: "op-who",
            pluginUpdate: update,
            terminalBundleID: "com.googlecode.iterm2"
        )
        let result = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(result?.rendered == "Claude plugin update check for cloudflare/skills (github)")
        #expect(result?.rule.replacesActor == true)
        #expect(result?.rule.name == "Claude plugin update (known marketplace)")
    }

    @Test func defaultsPluginUpdateFallsBackWhenMarketplaceLookupMisses() {
        // Only remoteURL filled (e.g. known_marketplaces.json missing
        // or entry not present) → 1a's {repo}/{source} resolve empty →
        // engine falls through to 1b which echoes the raw URL.
        let update = ClaudePluginUpdate(remoteURL: "git@gitlab.com:acme/widgets.git")
        let c = ctx(
            chain: [node("git")],
            argv: ["git", "pull", "origin", "HEAD"],
            pluginUpdate: update
        )
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "Claude plugin update check from git@gitlab.com:acme/widgets.git")
        #expect(r?.rule.name == "Claude plugin update")
    }

    @Test func repoAndSourcePlaceholdersResolveFromMarketplace() {
        let update = ClaudePluginUpdate(
            remoteURL: "git@github.com:sunstoneinstitute/claude-plugins.git",
            repo: "sunstoneinstitute/claude-plugins",
            sourceType: "github",
            marketplaceName: "sunstone-plugins"
        )
        let c = ctx(chain: [node("git")], pluginUpdate: update)
        #expect(renderTemplate("{repo} via {source} ({marketplace})", context: c)
                == "sunstoneinstitute/claude-plugins via github (sunstone-plugins)")
    }

    @Test func repoPlaceholderFallsThroughWhenAbsent() {
        // No pluginUpdate at all → {repo} resolves to "" → render fails.
        let c = ctx(chain: [node("git")])
        #expect(renderTemplate("for {repo}", context: c) == nil)
    }

    @Test func defaultsHandleGitNetworkSubcommand() {
        let c = ctx(chain: [node("git")], argv: ["git", "fetch", "origin"])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "needs an SSH key for ‘git fetch’")
        #expect(r?.rule.kind == .ssh)
    }

    @Test func defaultsHandleGitFallback() {
        let c = ctx(chain: [node("git")], argv: [])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "needs an SSH key (via ‘git’)")
    }

    @Test func defaultsHandleOpReadWithUri() {
        let c = ctx(
            chain: [node("op", verified: true)],
            argv: ["op", "read", "op://Dev/Secret/cred"]
        )
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "wants to read op://Dev/Secret/cred")
    }

    @Test func defaultsHandleOpReadWithoutUri() {
        // {op_uri} empty → falls through to "op read" fallback rule.
        let c = ctx(chain: [node("op", verified: true)], argv: ["op", "read"])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "wants to use ‘op read’")
    }

    @Test func defaultsHandleUnverifiedOp() {
        let c = ctx(chain: [node("op", verified: false)], argv: [])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rule.kind == .unverifiedOp)
        #expect(r?.rule.isWarning == true)
    }

    @Test func defaultsHandleResourceWithAction() {
        let c = ctx(
            chain: [node("op", verified: true)],
            argv: ["op", "item", "get", "GitHub"]
        )
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "wants to use ‘op item get’")
    }

    @Test func defaultsHandleResourceWithoutAction() {
        // argv[2] missing → 14a falls through to 14b.
        let c = ctx(
            chain: [node("op", verified: true)],
            argv: ["op", "vault"]
        )
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rendered == "wants to use ‘op vault’")
    }

    @Test func defaultsFallbackForUnknownTrigger() {
        let c = ctx(chain: [node("weird-thing")])
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: c)
        #expect(r?.rule.kind == .unknown)
        #expect(r?.rule.isWarning == true)
        #expect(r?.rendered.contains("weird-thing") == true)
    }

    @Test func defaultsFallbackForEmptyChain() {
        let r = RequestRuleEngine.evaluate(rules: RequestRule.builtIns, context: ctx(chain: []))
        #expect(r?.rule.kind == .unknown)
        #expect(r?.rendered.contains("?") == true)
    }

    @Test func firstMatchWinsOverridesDefaults() {
        // A user-added override rule placed first should win even though a
        // built-in default would also match.
        let custom = RequestRule(
            name: "Custom op read",
            predicate: #"triggerName == "op" AND subcommand == "read" AND binaryVerified == YES"#,
            template: "is pulling ‘{op_uri}’ from 1Password",
            kind: .onePasswordCLI
        )
        let rules = [custom] + RequestRule.builtIns
        let c = ctx(
            chain: [node("op", verified: true)],
            argv: ["op", "read", "op://X/Y"]
        )
        let r = RequestRuleEngine.evaluate(rules: rules, context: c)
        #expect(r?.rule.id == custom.id)
        #expect(r?.rendered == "is pulling ‘op://X/Y’ from 1Password")
    }

    @Test func malformedPredicateIsSkippedNotFatal() {
        // A bad predicate string must not crash the engine — the rule is
        // skipped (with a log) and evaluation continues to the next rule.
        let broken = RequestRule(
            name: "Broken",
            predicate: "this is not a predicate (",
            template: "x",
            kind: .ssh
        )
        let working = RequestRule(
            name: "Works",
            predicate: #"triggerName == "git""#,
            template: "ok",
            kind: .ssh
        )
        let c = ctx(chain: [node("git")])
        let r = RequestRuleEngine.evaluate(rules: [broken, working], context: c)
        #expect(r?.rule.name == "Works")
    }
}

@Suite("Stores")
struct StoresTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("op-who-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func ruleStoreFreshInstallShowsAllBuiltIns() {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        #expect(store.userRules.isEmpty)
        #expect(store.disabledBuiltInIDs.isEmpty)
        #expect(store.allRules == RequestRule.builtIns)
    }

    @Test func ruleStoreRoundTripsUserRulesAndDisabledBuiltIns() {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        let custom = RequestRule(
            name: "Custom",
            predicate: #"triggerName == "ssh""#,
            template: "hi",
            kind: .ssh
        )
        store.setUserRules([custom])
        store.setBuiltInDisabled(id: "git-fallback", disabled: true)
        store.setBuiltInDisabled(id: "ssh", disabled: true)

        let reloaded = RequestRuleStore(fileURL: url)
        #expect(reloaded.userRules.count == 1)
        #expect(reloaded.userRules.first?.name == "Custom")
        #expect(reloaded.disabledBuiltInIDs == ["git-fallback", "ssh"])
        // allRules now includes disabled built-ins so the Settings UI can
        // render them as greyed-out rows; the engine skips any rule whose
        // `enabled` is false. Verify both: the entries are present, but
        // their `enabled` flag is off.
        let gitFallback = reloaded.allRules.first { $0.builtInID == "git-fallback" }
        let ssh = reloaded.allRules.first { $0.builtInID == "ssh" }
        #expect(gitFallback != nil)
        #expect(ssh != nil)
        #expect(gitFallback?.enabled == false)
        #expect(ssh?.enabled == false)
    }

    @Test func ruleStoreClearsUserRulesWithoutTouchingBuiltIns() {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        store.setUserRules([
            RequestRule(name: "x", predicate: "TRUEPREDICATE", template: "x", kind: .unknown)
        ])
        store.setBuiltInDisabled(id: "ssh", disabled: true)
        store.clearUserRules()
        #expect(store.userRules.isEmpty)
        #expect(store.disabledBuiltInIDs == ["ssh"])  // untouched
    }

    /// `setRuleEnabled` is the single API the unified rules table uses,
    /// so it must route by ID — flipping the field on user rules and
    /// flipping the disabled-built-in set for built-ins.
    @Test func setRuleEnabledRoutesUserVsBuiltIn() {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        let userRule = RequestRule(
            name: "U", predicate: #"triggerName == "ssh""#,
            template: "u", kind: .ssh
        )
        store.setUserRules([userRule])

        // Disable a user rule by ID.
        store.setRuleEnabled(id: userRule.id, enabled: false)
        #expect(store.userRules.first?.enabled == false)

        // Re-enable it.
        store.setRuleEnabled(id: userRule.id, enabled: true)
        #expect(store.userRules.first?.enabled == true)

        // Disable a built-in by its per-process UUID.
        let sshBuiltIn = RequestRule.builtIn(id: "ssh")!
        store.setRuleEnabled(id: sshBuiltIn.id, enabled: false)
        #expect(store.disabledBuiltInIDs.contains("ssh"))
    }

    /// The engine must skip any rule with `enabled == false`, whether
    /// that rule is a user rule or a built-in that the user has toggled
    /// off via the Settings checkbox.
    @Test func engineSkipsDisabledRules() {
        let userRule = RequestRule(
            name: "shadow",
            predicate: #"triggerName == "ssh""#,
            template: "user-template",
            kind: .ssh,
            enabled: false
        )
        let sshBuiltIn = RequestRule.builtIn(id: "ssh")!
        let chain = [node("ssh")]
        let context = ctx(chain: chain)

        // With the disabled user rule first, the engine should fall through
        // to the built-in.
        let result = RequestRuleEngine.evaluate(
            rules: [userRule, sshBuiltIn], context: context
        )
        #expect(result?.rule.builtInID == "ssh")
    }

    /// The `comment` field on a rule must round-trip through JSON so
    /// users' notes survive a relaunch.
    @Test func commentFieldRoundTripsThroughJSON() throws {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        let userRule = RequestRule(
            name: "with-comment",
            predicate: #"triggerName == "op""#,
            template: "x",
            kind: .onePasswordCLI,
            comment: "Friendly reminder: this rule shadows the op-read built-in."
        )
        store.setUserRules([userRule])

        let reloaded = RequestRuleStore(fileURL: url)
        #expect(reloaded.userRules.first?.comment ==
            "Friendly reminder: this rule shadows the op-read built-in.")
    }

    /// Decoding a rule with only the required fields (no `enabled` or
    /// `comment` keys) must succeed, with the defaults filled in. Tests
    /// the custom Codable initializer that backstops the optional fields.
    @Test func ruleDecodesWithoutEnabledOrComment() throws {
        let minimal = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "minimal",
          "predicate": "TRUEPREDICATE",
          "template": "x",
          "replacesActor": false,
          "kind": "unknown",
          "isWarning": false
        }
        """.data(using: .utf8)!
        let rule = try JSONDecoder().decode(RequestRule.self, from: minimal)
        #expect(rule.enabled == true)
        #expect(rule.comment == nil)
    }

    @Test func ruleStoreEnableAllBuiltInsClearsDisabledSet() {
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        store.setBuiltInDisabled(id: "ssh", disabled: true)
        store.setBuiltInDisabled(id: "git-fallback", disabled: true)
        store.enableAllBuiltIns()
        #expect(store.disabledBuiltInIDs.isEmpty)
        #expect(store.allRules == RequestRule.builtIns)
    }

    @Test func userRulesEvaluatedBeforeBuiltIns() {
        // A user rule that matches the same trigger as a built-in must
        // win because user rules come first in `allRules`.
        let url = tempDir().appendingPathComponent("rules.json")
        let store = RequestRuleStore(fileURL: url)
        let shadow = RequestRule(
            name: "Custom git override",
            predicate: #"triggerName == "git""#,
            template: "custom git output",
            kind: .ssh
        )
        store.setUserRules([shadow])
        let chain = [ProcessNode(
            pid: 1, ppid: 1, name: "git", tty: nil,
            executablePath: nil, isVerifiedOnePasswordCLI: false
        )]
        let c = MatchContext(
            chain: chain, triggerArgv: ["git", "status"],
            cwd: nil, triggerCwd: nil, claudeSession: nil,
            pluginUpdate: nil, terminalBundleID: nil
        )
        let r = RequestRuleEngine.evaluate(rules: store.allRules, context: c)
        #expect(r?.rendered == "custom git output")
    }

    @Test func recentRequestsRingTrimsToCapacity() {
        let url = tempDir().appendingPathComponent("recent.json")
        let store = RecentRequestsStore(capacity: 3, fileURL: url)
        for i in 0..<10 {
            store.record(sampleRequest(title: "req-\(i)"))
        }
        #expect(store.requests.count == 3)
        #expect(store.requests.last?.title == "req-9")
        #expect(store.requests.first?.title == "req-7")
        let reloaded = RecentRequestsStore(capacity: 3, fileURL: url)
        #expect(reloaded.requests.map { $0.title } == ["req-7", "req-8", "req-9"])
    }

    /// Built-in `RequestRule` UUIDs regenerate every process run, so a
    /// `matchedRuleID` persisted to recent-requests.json in one session
    /// won't match any rule in the next session. The stable `builtInID`
    /// slug survives the round-trip and resolves via
    /// `RequestRule.builtIn(id:)`.
    @Test func recentRequestMatchedBuiltInIDSurvivesPersistence() {
        let url = tempDir().appendingPathComponent("recent-builtin.json")
        let store = RecentRequestsStore(capacity: 5, fileURL: url)
        let builtIn = RequestRule.builtIns.first(where: { $0.builtInID == "op-read-uri" })!
        let request = RecentRequest(
            chainNames: ["op"], triggerArgv: ["op", "read", "op://X/Y"],
            cwd: nil, triggerCwd: nil, binaryVerified: true,
            claudeSession: nil, terminalBundleID: nil, tabTitle: nil,
            pluginRemoteURL: nil,
            title: "wants to read op://X/Y", subtitle: nil,
            kindRaw: "onePasswordCLI", isWarning: false,
            matchedRuleID: builtIn.id,
            matchedRuleName: builtIn.name,
            matchedBuiltInID: builtIn.builtInID
        )
        store.record(request)

        let reloaded = RecentRequestsStore(capacity: 5, fileURL: url)
        let loaded = reloaded.requests.first!
        // UUID does NOT survive a process restart for built-ins, so we
        // only assert the stable slug survived.
        #expect(loaded.matchedBuiltInID == "op-read-uri")
        #expect(RequestRule.builtIn(id: loaded.matchedBuiltInID!)?.template == builtIn.template)
    }

    /// recent-requests.json files written by v0.5.2 (before
    /// `matchedBuiltInID` existed) must still decode. The synthesized
    /// Codable treats the missing optional as nil.
    @Test func recentRequestDecodesWithoutMatchedBuiltInID() throws {
        let legacy = """
        [{
          "id": "00000000-0000-0000-0000-000000000001",
          "timestamp": "2026-01-01T00:00:00Z",
          "chainNames": ["op"],
          "triggerArgv": ["op", "read"],
          "binaryVerified": true,
          "title": "legacy",
          "kindRaw": "onePasswordCLI",
          "isWarning": false
        }]
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([RecentRequest].self, from: legacy)
        #expect(decoded.count == 1)
        #expect(decoded.first?.matchedBuiltInID == nil)
    }

    @Test func makeMatchContextRebuildsTriggerNameAndArgv() {
        let r = RecentRequest(
            chainNames: ["git", "node"],
            triggerArgv: ["git", "push", "origin", "main"],
            cwd: "/Users/x/proj", triggerCwd: "/Users/x/proj",
            binaryVerified: false,
            claudeSession: nil, terminalBundleID: nil, tabTitle: nil,
            pluginRemoteURL: nil,
            title: "x", subtitle: nil,
            kindRaw: "ssh", isWarning: false,
            matchedRuleID: nil, matchedRuleName: nil
        )
        let ctx = r.makeMatchContext()
        #expect(ctx.triggerName == "git")
        #expect(ctx.triggerArgv == ["git", "push", "origin", "main"])
        #expect(ctx.triggerCwd == "/Users/x/proj")
        #expect(ctx.binaryVerified == false)
        #expect(ctx.chain.map(\.name) == ["git", "node"])
    }

    @Test func makeMatchContextPreservesBinaryVerifiedOnTrigger() {
        let r = RecentRequest(
            chainNames: ["op", "zsh"],
            triggerArgv: ["op", "read", "op://x/y"],
            cwd: nil, triggerCwd: nil,
            binaryVerified: true,
            claudeSession: nil, terminalBundleID: nil, tabTitle: nil,
            pluginRemoteURL: nil,
            title: "x", subtitle: nil,
            kindRaw: "onePasswordCLI", isWarning: false,
            matchedRuleID: nil, matchedRuleName: nil
        )
        let ctx = r.makeMatchContext()
        // binaryVerified reads from chain.first, so the flag has to land
        // on the trigger node specifically.
        #expect(ctx.binaryVerified == true)
        #expect(ctx.chain.first?.isVerifiedOnePasswordCLI == true)
        #expect(ctx.chain.last?.isVerifiedOnePasswordCLI == false)
    }

    @Test func makeMatchContextReconstructsPluginUpdateFromRemoteURL() {
        let r = RecentRequest(
            chainNames: ["git"],
            triggerArgv: ["git", "pull"],
            cwd: nil, triggerCwd: nil, binaryVerified: false,
            claudeSession: nil, terminalBundleID: nil, tabTitle: nil,
            pluginRemoteURL: "git@github.com:foo/bar.git",
            title: "x", subtitle: nil,
            kindRaw: "ssh", isWarning: false,
            matchedRuleID: nil, matchedRuleName: nil
        )
        let ctx = r.makeMatchContext()
        #expect(ctx.pluginUpdate?.remoteURL == "git@github.com:foo/bar.git")
        // PredicateContext flattens this to pluginUpdateAvailable; the
        // test sheet needs that flag set so user predicates like
        // `pluginUpdateAvailable == YES` actually match.
        #expect(ctx.predicateBridge().pluginUpdateAvailable == true)
    }

    private func sampleRequest(title: String) -> RecentRequest {
        RecentRequest(
            chainNames: ["op"], triggerArgv: ["op", "read", "op://X/Y"],
            cwd: nil, triggerCwd: nil, binaryVerified: true,
            claudeSession: nil, terminalBundleID: nil, tabTitle: nil,
            pluginRemoteURL: nil,
            title: title, subtitle: nil, kindRaw: "onePasswordCLI",
            isWarning: false, matchedRuleID: nil, matchedRuleName: nil,
            matchedBuiltInID: nil
        )
    }
}
