import AppKit
import Testing
@testable import OpWhoLib

/// Regression coverage for the AppKit construction of the popup body grid.
/// The pure `bodyRows` builder is tested elsewhere; these tests exercise
/// `OverlayPanel.makeBodyTable`, which previously crashed with an
/// NSRangeException by indexing `column(at: 0)` on an empty `NSGridView`
/// before any rows (and therefore any columns) existed.
@Suite("OverlayPanel.makeBodyTable")
@MainActor
struct BodyTableRenderTests {
    private func node(_ name: String, pid: pid_t = 100) -> ProcessNode {
        ProcessNode(pid: pid, ppid: 1, name: name, tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: false)
    }

    private func entry(git: GitContext?) -> OverlayPanel.ProcessEntry {
        OverlayPanel.ProcessEntry(
            pid: 1, chain: [node("op"), node("zsh")], triggerArgv: ["op", "vault", "list"],
            tty: "/dev/ttys1", tabTitle: nil, tabShortcut: nil, claudeSession: nil,
            claudeContext: nil, scriptInfo: nil, terminalBundleID: nil, terminalPID: nil,
            cwd: "~/git/fleet", triggerCwd: "~/git/fleet",
            cmuxWorkspaceID: nil, cmuxTabID: nil, cmuxSurface: nil, pluginUpdate: nil,
            summary: RequestSummary(kind: .onePasswordCLI, title: "", subtitle: nil, isWarning: false),
            matchedRuleID: nil, matchedRuleName: nil, matchedBuiltInID: nil,
            gitContext: git
        )
    }

    @Test("builds a 2-column grid without crashing (in a repo)")
    func inRepo() {
        let panel = OverlayPanel()
        let git = GitContext(root: "~/git/fleet", branch: "main", worktreeSubpath: nil)
        let view = panel.makeBodyTable(entry(git: git))
        let grid = try! #require(view as? NSGridView)
        // action + who + git-root + branch + worktree(main) = 5 rows, 2 columns.
        #expect(grid.numberOfColumns == 2)
        #expect(grid.numberOfRows == 5)
    }

    @Test("builds without crashing (not a repo)")
    func notRepo() {
        let panel = OverlayPanel()
        let view = panel.makeBodyTable(entry(git: nil))
        let grid = try! #require(view as? NSGridView)
        // action + who + cwd = 3 rows.
        #expect(grid.numberOfColumns == 2)
        #expect(grid.numberOfRows == 3)
    }
}
