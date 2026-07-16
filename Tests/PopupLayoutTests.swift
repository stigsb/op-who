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
        scriptInfo: ScriptInfo? = nil,
        kind: RequestKind = .onePasswordCLI
    ) -> OverlayPanel.ProcessEntry {
        OverlayPanel.ProcessEntry(
            pid: 1, chain: chain, triggerArgv: argv, tty: "/dev/ttys1",
            tabTitle: nil, tabShortcut: nil, claudeSession: claudeSession,
            claudeContext: prompt.map { ClaudeContext(sessionID: "s", lastUserPrompt: $0, lastRelevantCommand: nil) },
            scriptInfo: scriptInfo, terminalBundleID: nil, terminalPID: nil,
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

    @Test("who-line shows the full invoked command, name included")
    func whoLineIncludesInvokedCommandName() {
        // A plain invoked command (interpreter is the leading argv token) must
        // keep its name: `git commit -m msg`, not just `commit -m msg`.
        let e = entry(
            argv: ["op-ssh-sign", "-Y", "sign"], chain: [node("op-ssh-sign")],
            cwd: "~/git/fleet", git: nil,
            scriptInfo: ScriptInfo(interpreter: "git", scriptName: "commit -m msg", scriptPath: nil)
        )
        let who = bodyRows(entry: e, dense: false).first { $0.label == "who" }
        #expect(who?.value.contains("git commit -m msg") == true)
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

@Suite("processTreeNodes")
struct ProcessTreeNodesTests {
    private func node(_ name: String, pid: pid_t, op: Bool = false, verified: Bool = false) -> ProcessNode {
        ProcessNode(pid: pid, ppid: 1, name: name, tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: verified)
    }

    @Test("app prepended, parent-first order, increasing depth")
    func withApp() {
        let chain = [node("op-ssh-sign", pid: 78288),
                     node("git", pid: 1213),
                     node("bash", pid: 9101)]
        let nodes = processTreeNodes(appName: "cmux", appPID: 1234, chain: chain)
        #expect(nodes.map { $0.name } == ["cmux.app", "bash", "git", "op-ssh-sign"])
        #expect(nodes.map { $0.pid } == [1234, 9101, 1213, 78288])
        #expect(nodes.map { $0.depth } == [0, 1, 2, 3])
    }

    @Test("no app: chain alone, depth from 0")
    func withoutApp() {
        let chain = [node("op", pid: 5), node("zsh", pid: 6)]
        let nodes = processTreeNodes(appName: nil, appPID: nil, chain: chain)
        #expect(nodes.map { $0.name } == ["zsh", "op"])
        #expect(nodes.map { $0.depth } == [0, 1])
    }

    @Test("op node flagged for coloring")
    func opFlagged() {
        let chain = [node("op", pid: 5, op: true, verified: true)]
        let nodes = processTreeNodes(appName: nil, appPID: nil, chain: chain)
        #expect(nodes[0].opColor == .verified)
    }
}

@Suite("detailsYAMLLines")
struct DetailsYAMLTests {
    private func entry(argv: [String], tty: String?, workspace: (String, String)?, tab: (String, String)?) -> OverlayPanel.ProcessEntry {
        var surface: CmuxSurfaceInfo? = nil
        if workspace != nil || tab != nil {
            surface = CmuxSurfaceInfo(
                workspaceRef: "ws", workspaceTitle: workspace?.0 ?? "",
                surfaceRef: "sf", surfaceTitle: tab?.0 ?? "",
                tty: "/dev/ttys002", workspaceIndex: 1, tabIndex: 1
            )
        }
        return OverlayPanel.ProcessEntry(
            pid: 78288, chain: [], triggerArgv: argv, tty: tty,
            tabTitle: nil, tabShortcut: nil, claudeSession: nil, claudeContext: nil,
            scriptInfo: nil, terminalBundleID: nil, terminalPID: nil,
            cwd: nil, triggerCwd: nil,
            cmuxWorkspaceID: workspace?.1, cmuxTabID: tab?.1, cmuxSurface: surface,
            pluginUpdate: nil,
            summary: RequestSummary(kind: .unknown, title: "", subtitle: nil, isWarning: false),
            matchedRuleID: nil, matchedRuleName: nil, matchedBuiltInID: nil
        )
    }

    @Test("tty/pid/workspace/tab/argv, no cwd, title (guid)")
    func fullLines() {
        let e = entry(
            argv: ["/Applications/1Password.app/op-ssh-sign", "-Y", "sign"],
            tty: "/dev/ttys002",
            workspace: ("fleet", "WS-GUID"),
            tab: ("editor", "TAB-GUID")
        )
        let lines = detailsYAMLLines(entry: e)
        #expect(lines == [
            "tty: /dev/ttys002",
            "pid: 78288",
            "workspace: fleet (WS-GUID)",
            "tab: editor (TAB-GUID)",
            "argv:",
            "  - /Applications/1Password.app/op-ssh-sign",
            "  - -Y",
            "  - sign",
        ])
    }

    @Test("bare guid when no title")
    func bareGuid() {
        let e = entry(argv: ["op"], tty: nil, workspace: ("", "WS-GUID"), tab: nil)
        let lines = detailsYAMLLines(entry: e)
        #expect(lines.contains("workspace: WS-GUID"))
        #expect(!lines.contains(where: { $0.hasPrefix("tty:") }))
    }
}
