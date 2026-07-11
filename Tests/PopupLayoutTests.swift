import Foundation
import Testing
@testable import OpWhoLib

@Suite("bodyRows")
struct BodyRowsTests {
    private func node(_ name: String, pid: pid_t = 100) -> ProcessNode {
        ProcessNode(pid: pid, ppid: 1, name: name, tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: false)
    }

    private func entry(
        argv: [String],
        chain: [ProcessNode],
        cwd: String?,
        git: GitContext?,
        claudeSession: String? = nil,
        prompt: String? = nil,
        kind: RequestKind = .onePasswordCLI
    ) -> OverlayPanel.ProcessEntry {
        OverlayPanel.ProcessEntry(
            pid: 1, chain: chain, triggerArgv: argv, tty: "/dev/ttys1",
            tabTitle: nil, tabShortcut: nil, claudeSession: claudeSession,
            claudeContext: prompt.map { ClaudeContext(sessionID: "s", lastUserPrompt: $0, lastRelevantCommand: nil) },
            scriptInfo: nil, terminalBundleID: nil, terminalPID: nil,
            cwd: cwd, triggerCwd: cwd, cmuxWorkspaceID: nil, cmuxTabID: nil,
            cmuxSurface: nil, pluginUpdate: nil,
            summary: RequestSummary(kind: kind, title: "", subtitle: nil, isWarning: false),
            matchedRuleID: nil, matchedRuleName: nil, matchedBuiltInID: nil,
            gitContext: git
        )
    }

    @Test("in-repo, worktree, dense off: action/who/git-root/branch/worktree")
    func inRepoWorktree() {
        let e = entry(
            argv: ["op", "item", "get", "GitHub"],
            chain: [node("op"), node("zsh")],
            cwd: "~/git/fleet/.claude/worktrees/foo",
            git: GitContext(root: "~/git/fleet", branch: "foo",
                            worktreeSubpath: ".claude/worktrees/foo")
        )
        let rows = bodyRows(entry: e, dense: false)
        #expect(rows.map { $0.label } == [nil, "who", "git-root", "branch", "worktree"])
        #expect(rows[2].value == "~/git/fleet")
        #expect(rows[3].value == "foo")
        #expect(rows[4].value == ".claude/worktrees/foo")
    }

    @Test("main checkout, dense off: worktree row shows (main)")
    func mainCheckoutDenseOff() {
        let e = entry(
            argv: ["op", "read", "op://v/x"], chain: [node("op")],
            cwd: "~/git/fleet",
            git: GitContext(root: "~/git/fleet", branch: "main", worktreeSubpath: nil)
        )
        let rows = bodyRows(entry: e, dense: false)
        #expect(rows.last?.label == "worktree")
        #expect(rows.last?.value == "(main)")
    }

    @Test("main checkout, dense on: worktree row dropped")
    func mainCheckoutDenseOn() {
        let e = entry(
            argv: ["op", "read", "op://v/x"], chain: [node("op")],
            cwd: "~/git/fleet",
            git: GitContext(root: "~/git/fleet", branch: "main", worktreeSubpath: nil)
        )
        let rows = bodyRows(entry: e, dense: true)
        #expect(rows.map { $0.label } == [nil, "who", "git-root", "branch"])
    }

    @Test("not in a repo: single cwd row")
    func notInRepo() {
        let e = entry(
            argv: ["op", "read", "op://v/x"], chain: [node("op")],
            cwd: "~/Downloads", git: nil
        )
        let rows = bodyRows(entry: e, dense: false)
        #expect(rows.map { $0.label } == [nil, "who", "cwd"])
        #expect(rows.last?.value == "~/Downloads")
    }

    @Test("claude prompt: asked row appended last")
    func askedRow() {
        let e = entry(
            argv: ["op", "read", "op://v/x"], chain: [node("op"), node("node")],
            cwd: "~/git/fleet",
            git: GitContext(root: "~/git/fleet", branch: "main", worktreeSubpath: nil),
            claudeSession: "sess", prompt: "commit the fix"
        )
        let rows = bodyRows(entry: e, dense: true)
        #expect(rows.last?.label == "asked")
        #expect(rows.last?.value == "\u{201C}commit the fix\u{201D}")
    }

    @Test("action uses cwd:nil form (commit signing has no trailing cwd)")
    func actionNoCwd() {
        let e = entry(
            argv: ["op-ssh-sign", "-Y", "sign", "-n", "git", "-f", "/tmp/x"],
            chain: [node("op-ssh-sign"), node("git")],
            cwd: "~/git/fleet",
            git: GitContext(root: "~/git/fleet", branch: "main", worktreeSubpath: nil),
            kind: .ssh
        )
        let rows = bodyRows(entry: e, dense: false)
        #expect(rows[0].label == nil)
        #expect(rows[0].value == "signing a commit")
    }
}
