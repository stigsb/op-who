import Testing
import Foundation
@testable import OpWhoLib

@Suite("previewTitle")
struct PreviewTitleTests {

    /// Build a RecentRequest with sensible defaults so each test only
    /// has to specify the fields it cares about.
    private func recent(
        chainNames: [String] = ["git", "zsh"],
        triggerArgv: [String] = ["git", "fetch", "origin"],
        cwd: String? = "/Users/x/proj",
        triggerCwd: String? = nil,
        claudeSession: String? = nil,
        terminalBundleID: String? = "com.googlecode.iterm2",
        tabTitle: String? = nil,
        pluginRemoteURL: String? = nil
    ) -> RecentRequest {
        RecentRequest(
            chainNames: chainNames,
            triggerArgv: triggerArgv,
            cwd: cwd,
            triggerCwd: triggerCwd,
            binaryVerified: false,
            claudeSession: claudeSession,
            terminalBundleID: terminalBundleID,
            tabTitle: tabTitle,
            pluginRemoteURL: pluginRemoteURL,
            title: "stored title",
            subtitle: nil,
            kindRaw: RequestKind.ssh.rawValue,
            isWarning: false,
            matchedRuleID: nil,
            matchedRuleName: nil
        )
    }

    @Test func prependsActorWhenNotReplacing() {
        let rule = RequestRule(
            name: "Test", predicate: "TRUEPREDICATE",
            template: "is doing something in {cwd}",
            kind: .ssh
        )
        let r = recent(claudeSession: "abc")
        let title = previewTitle(rule: rule, recent: r)
        #expect(title == "Claude Code session ‘abc’ is doing something in /Users/x/proj")
    }

    @Test func suppressesActorWhenReplaces() {
        let rule = RequestRule(
            name: "Test", predicate: "TRUEPREDICATE",
            template: "Claude plugin update check from {plugin_remote}",
            replacesActor: true,
            kind: .ssh
        )
        let r = recent(
            claudeSession: "abc",
            pluginRemoteURL: "https://github.com/foo/bar.git"
        )
        let title = previewTitle(rule: rule, recent: r)
        #expect(title == "Claude plugin update check from https://github.com/foo/bar.git")
    }

    @Test func returnsNilWhenPlaceholderUnresolved() {
        // `{plugin_remote}` resolves to "" when the recent has no plugin
        // update info — renderTemplate signals that with nil, which
        // previewTitle must propagate so the caller can sample another
        // recent.
        let rule = RequestRule(
            name: "Test", predicate: "TRUEPREDICATE",
            template: "update check from {plugin_remote}",
            replacesActor: true,
            kind: .ssh
        )
        let r = recent(pluginRemoteURL: nil)
        #expect(previewTitle(rule: rule, recent: r) == nil)
    }

    @Test func actorFallsBackToShellWhenNothingSpecific() {
        let rule = RequestRule(
            name: "Test", predicate: "TRUEPREDICATE",
            template: "is using ‘op’",
            kind: .ssh
        )
        let r = recent(
            chainNames: ["op", "zsh"],
            claudeSession: nil,
            terminalBundleID: nil,
            tabTitle: nil
        )
        let title = previewTitle(rule: rule, recent: r)
        #expect(title == "Your zsh shell is using ‘op’")
    }
}
