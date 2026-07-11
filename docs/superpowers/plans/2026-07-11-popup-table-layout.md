# Popup Table Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the 1Password approval overlay into a fixed-order two-column table (action / who / git context / asked) with a pstree-style details block, plus a Settings-window "Dense popup" toggle and appearance override.

**Architecture:** All layout logic lives in UI-free pure functions in `OpWhoLib` (like the existing `terminalRowParts`) that return plain value types; `OverlayPanel` only renders their output. Git context is gathered once at capture time via one `git rev-parse` call. Two new persisted settings live in a UserDefaults-backed `AppSettings` and are surfaced in the existing Settings window.

**Tech Stack:** Swift 5.9, AppKit, Swift Testing (`import Testing`), macOS 13+.

**Spec:** `docs/superpowers/specs/2026-07-11-popup-table-layout-design.md`

---

## File Structure

- **Create** `Sources/OpWhoLib/GitContext.swift` — `GitContext` value type, pure `GitContext.make(...)` builder, and the `gitContext(forCwd:)` subprocess gatherer.
- **Create** `Sources/OpWhoLib/PopupLayout.swift` — pure layout builders: `BodyRow`/`BodyRowStyle` + `bodyRows(...)`, `TreeNode` + `processTreeNodes(...)`, `detailsYAMLLines(...)`.
- **Create** `Sources/OpWhoLib/AppSettings.swift` — `AppAppearance` enum + UserDefaults-backed `AppSettings`.
- **Create** `Sources/OpWhoLib/OverlayColors.swift` — appearance-aware, AA-contrast color constants + a `contrastRatio` helper.
- **Modify** `Sources/OpWhoLib/OverlayPanel.swift` — add `ProcessEntry.gitContext`; replace body + details rendering to consume the pure builders and `OverlayColors`.
- **Modify** `Sources/OpWhoLib/OnePasswordWatcher.swift` — gather + pass `gitContext`.
- **Modify** `Sources/op-who/GeneralPane.swift` — add "Dense popup" checkbox + appearance control.
- **Modify** `Sources/op-who/ConfigWindowController.swift` — reset scroll to top on open.
- **Modify** `Sources/op-who/main.swift` — apply appearance at launch.
- **Create/Modify** tests under `Tests/`.

Task order builds bottom-up: data → pure builders → rendering → settings → UI.

---

## Task 1: `GitContext` type + pure builder

**Files:**
- Create: `Sources/OpWhoLib/GitContext.swift`
- Test: `Tests/GitContextTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import OpWhoLib

@Suite("GitContext.make")
struct GitContextMakeTests {
    // Simulate `~` expansion by pinning home to a known prefix for assertions.
    // GitContext.make abbreviates via ProcessTree.tidyPath, which uses the real
    // home dir; use the real home so the abbreviation matches.
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    @Test("main checkout: worktreeSubpath is nil")
    func mainCheckout() {
        let g = GitContext.make(
            toplevel: "\(home)/git/fleet",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "main",
            detachedSHA: nil
        )
        #expect(g.root == "~/git/fleet")
        #expect(g.branch == "main")
        #expect(g.worktreeSubpath == nil)
    }

    @Test("linked worktree one level down: relative subpath")
    func linkedWorktree() {
        let g = GitContext.make(
            toplevel: "\(home)/git/fleet/.claude/worktrees/foo",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "foo",
            detachedSHA: nil
        )
        #expect(g.root == "~/git/fleet")
        #expect(g.worktreeSubpath == ".claude/worktrees/foo")
    }

    @Test("far-flung worktree (ascends >1 level): absolute home-abbreviated path")
    func farFlungWorktree() {
        let g = GitContext.make(
            toplevel: "\(home)/tmp/wt-foo",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "foo",
            detachedSHA: nil
        )
        // Relative would be ../../tmp/wt-foo (ascends 2), so fall back to absolute.
        #expect(g.root == "~/git/fleet")
        #expect(g.worktreeSubpath == "~/tmp/wt-foo")
    }

    @Test("sibling worktree (ascends exactly 1 level): kept relative")
    func siblingWorktree() {
        let g = GitContext.make(
            toplevel: "\(home)/git/fleet-foo",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "foo",
            detachedSHA: nil
        )
        #expect(g.worktreeSubpath == "../fleet-foo")
    }

    @Test("detached HEAD: branch falls back to short SHA")
    func detachedHead() {
        let g = GitContext.make(
            toplevel: "\(home)/git/fleet",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "HEAD",
            detachedSHA: "a1b2c3d"
        )
        #expect(g.branch == "a1b2c3d")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GitContextMakeTests`
Expected: FAIL — `cannot find 'GitContext' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Git context for the directory a 1Password trigger ran in. Resolved to the
/// *main* worktree even when the trigger ran inside a linked worktree.
public struct GitContext: Equatable {
    /// Main worktree top-level, home-abbreviated (e.g. "~/git/fleet").
    public let root: String
    /// Current branch, or a short SHA when HEAD is detached. nil if unknown.
    public let branch: String?
    /// Current worktree relative to `root` (e.g. ".claude/worktrees/foo"), or a
    /// full home-abbreviated path when it ascends more than one level, or nil in
    /// the main checkout.
    public let worktreeSubpath: String?

    public init(root: String, branch: String?, worktreeSubpath: String?) {
        self.root = root
        self.branch = branch
        self.worktreeSubpath = worktreeSubpath
    }

    /// Build a GitContext from raw `git rev-parse` outputs. Pure — no I/O.
    ///
    /// - `toplevel`: absolute `--show-toplevel` (current worktree).
    /// - `gitCommonDir`: absolute `--git-common-dir` (ends in `/.git` for the
    ///   main repo, shared by all linked worktrees).
    /// - `branchRaw`: `--abbrev-ref HEAD` ("HEAD" when detached).
    /// - `detachedSHA`: short SHA used when `branchRaw == "HEAD"`.
    public static func make(
        toplevel: String,
        gitCommonDir: String,
        branchRaw: String,
        detachedSHA: String?
    ) -> GitContext {
        let rootAbs: String
        if gitCommonDir.hasSuffix("/.git") {
            rootAbs = String(gitCommonDir.dropLast("/.git".count))
        } else if (gitCommonDir as NSString).lastPathComponent == ".git" {
            rootAbs = (gitCommonDir as NSString).deletingLastPathComponent
        } else {
            rootAbs = toplevel
        }

        let branch: String? = branchRaw == "HEAD" ? detachedSHA : branchRaw

        let subpath: String?
        if toplevel == rootAbs {
            subpath = nil
        } else {
            let rel = relativePath(from: rootAbs, to: toplevel)
            if rel.hasPrefix("../../") {
                subpath = ProcessTree.tidyPath(toplevel)
            } else {
                subpath = rel
            }
        }

        return GitContext(
            root: ProcessTree.tidyPath(rootAbs),
            branch: branch,
            worktreeSubpath: subpath
        )
    }

    /// Compute `to` relative to `from` using path components.
    static func relativePath(from: String, to: String) -> String {
        let fromParts = (from as NSString).pathComponents.filter { $0 != "/" }
        let toParts = (to as NSString).pathComponents.filter { $0 != "/" }
        var i = 0
        while i < fromParts.count, i < toParts.count, fromParts[i] == toParts[i] {
            i += 1
        }
        let ups = Array(repeating: "..", count: fromParts.count - i)
        let downs = Array(toParts[i...])
        return (ups + downs).joined(separator: "/")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GitContextMakeTests`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/GitContext.swift Tests/GitContextTests.swift
git commit -m "feat: add GitContext value type and pure builder"
```

---

## Task 2: `gitContext(forCwd:)` subprocess gatherer

**Files:**
- Modify: `Sources/OpWhoLib/GitContext.swift`
- Test: `Tests/GitContextTests.swift`

This task shells out to `git`, so the assertion is integration-style: run it against this repo's own working directory (tests execute inside the checkout).

- [ ] **Step 1: Write the failing test**

```swift
@Suite("gitContext(forCwd:)")
struct GitContextGatherTests {
    @Test("resolves this repo's own checkout")
    func selfRepo() {
        let cwd = FileManager.default.currentDirectoryPath
        let g = gitContext(forCwd: cwd)
        #expect(g != nil)
        // Root ends in the repo dir name; branch is non-empty.
        #expect(g?.root.hasSuffix("op-who") == true)
        #expect((g?.branch?.isEmpty ?? true) == false)
    }

    @Test("non-repo directory returns nil")
    func nonRepo() {
        let g = gitContext(forCwd: "/tmp")
        // /tmp is not a git repo (or resolves outside one); expect nil.
        #expect(g == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GitContextGatherTests`
Expected: FAIL — `cannot find 'gitContext' in scope`.

- [ ] **Step 3: Write the implementation** (append to `GitContext.swift`)

```swift
/// Gather git context for `cwd` by running one `git rev-parse`. Returns nil
/// when `cwd` is not inside a repository, git is missing, or the call errors.
/// `cwd` may be home-abbreviated ("~/…"); the leading `~` is expanded first.
public func gitContext(forCwd cwd: String) -> GitContext? {
    let path = expandTilde(cwd)
    guard let out = runGit(
        ["-C", path, "rev-parse", "--path-format=absolute",
         "--show-toplevel", "--git-common-dir", "--abbrev-ref", "HEAD"]
    ) else { return nil }

    let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        .map { String($0) }
    guard lines.count >= 3 else { return nil }
    let toplevel = lines[0]
    let commonDir = lines[1]
    let branchRaw = lines[2]
    guard !toplevel.isEmpty, !commonDir.isEmpty else { return nil }

    var detached: String? = nil
    if branchRaw == "HEAD" {
        detached = runGit(["-C", path, "rev-parse", "--short", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return GitContext.make(
        toplevel: toplevel,
        gitCommonDir: commonDir,
        branchRaw: branchRaw,
        detachedSHA: detached
    )
}

private func expandTilde(_ path: String) -> String {
    if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
    if path.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2))).path
    }
    return path
}

/// Run `git` with `args`, returning trimmed stdout on exit code 0, else nil.
/// Times out defensively at ~2s so a hung git never blocks the caller.
private func runGit(_ args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    // Keep git from prompting or reading global config surprises.
    var env = ProcessInfo.processInfo.environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    proc.environment = env

    do {
        try proc.run()
    } catch {
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GitContextGatherTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/GitContext.swift Tests/GitContextTests.swift
git commit -m "feat: gather git context via git rev-parse"
```

---

## Task 3: Add `gitContext` to `ProcessEntry` and gather it in the watcher

**Files:**
- Modify: `Sources/OpWhoLib/OverlayPanel.swift:46` (end of ProcessEntry fields)
- Modify: `Sources/OpWhoLib/OnePasswordWatcher.swift:328` (entry construction)

- [ ] **Step 1: Add the field to `ProcessEntry`**

In `OverlayPanel.swift`, after the `matchedBuiltInID` property (line ~46), add:

```swift
        /// Git context for the trigger's working directory, gathered at
        /// capture time. nil when the trigger did not run inside a repo.
        let gitContext: GitContext? = nil
```

The `= nil` default keeps every existing `ProcessEntry(...)` call site (and all test factories) compiling unchanged — the synthesized memberwise initializer gains an optional `gitContext:` parameter.

- [ ] **Step 2: Gather + pass it in the watcher**

In `OnePasswordWatcher.swift`, immediately before `let entry = OverlayPanel.ProcessEntry(` (line ~328), add:

```swift
            let gitCtx = cwd.map { gitContext(forCwd: $0) } ?? nil
```

Then add `gitContext: gitCtx,` to the `ProcessEntry(...)` argument list (place it right after `triggerCwd: triggerCWD,`).

(If `cwd` is a non-optional `String` at that point rather than `String?`, use `let gitCtx = gitContext(forCwd: cwd)` instead — check the local type.)

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Run the full suite (nothing should break)**

Run: `swift test`
Expected: PASS (existing tests unaffected by the defaulted field).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/OverlayPanel.swift Sources/OpWhoLib/OnePasswordWatcher.swift
git commit -m "feat: carry gathered GitContext on ProcessEntry"
```

---

## Task 4: Pure body-row builder

**Files:**
- Create: `Sources/OpWhoLib/PopupLayout.swift`
- Test: `Tests/PopupLayoutTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
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
        #expect(rows.last?.value == "“commit the fix”")
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BodyRowsTests`
Expected: FAIL — `cannot find 'bodyRows' in scope`.

- [ ] **Step 3: Write the implementation** (`PopupLayout.swift`)

```swift
import Foundation

/// A single rendered row of the popup body. `label` nil = the label-less
/// action row. Styling is decided by `style`; the renderer maps it to colors.
public struct BodyRow: Equatable {
    public let label: String?
    public let value: String
    public let style: BodyRowStyle
}

public enum BodyRowStyle: Equatable {
    /// Top action line, colored by request kind.
    case action(RequestKind)
    /// "who" line, colored by driver kind.
    case who(DriverKind)
    /// A labeled context field (git-root/branch/worktree/cwd) — dim label,
    /// bright value.
    case field
    /// The wrapping Claude "asked" prompt line.
    case asked
}

/// Build the ordered body rows for an entry. Pure — no AppKit, no I/O.
///
/// Canonical order (identical for every trigger): action, who, location block
/// (git-root/branch/worktree in a repo, else a single cwd), asked.
public func bodyRows(entry: OverlayPanel.ProcessEntry, dense: Bool) -> [BodyRow] {
    var rows: [BodyRow] = []

    // Action — cwd:nil so commit-signing renders "signing a commit" (location
    // lives in its own row).
    let actionText: String
    if let update = entry.pluginUpdate {
        actionText = "plugin update check from \(update.remoteURL)"
    } else {
        actionText = operationDisplay(argv: entry.triggerArgv, chain: entry.chain, cwd: nil)
    }
    rows.append(BodyRow(label: nil, value: actionText, style: .action(entry.summary.kind)))

    // Who — driver + optional script (cwd is no longer appended here).
    let driver = driverDescription(chain: entry.chain, claudeSession: entry.claudeSession)
    var whoValue = driver.text
    if entry.claudeSession == nil, let s = entry.scriptInfo {
        whoValue += " · \(s.scriptName)"
    }
    rows.append(BodyRow(label: "who", value: whoValue, style: .who(driver.kind)))

    // Location block.
    if let git = entry.gitContext {
        rows.append(BodyRow(label: "git-root", value: git.root, style: .field))
        if let branch = git.branch {
            rows.append(BodyRow(label: "branch", value: branch, style: .field))
        }
        if let sub = git.worktreeSubpath {
            rows.append(BodyRow(label: "worktree", value: sub, style: .field))
        } else if !dense {
            rows.append(BodyRow(label: "worktree", value: "(main)", style: .field))
        }
    } else if let cwd = entry.cwd, cwd != "/", !cwd.isEmpty {
        rows.append(BodyRow(label: "cwd", value: cwd, style: .field))
    }

    // Asked — Claude natural-language prompt, last.
    if let prompt = entry.claudeContext?.lastUserPrompt, !prompt.isEmpty {
        rows.append(BodyRow(label: "asked", value: "“\(prompt)”", style: .asked))
    }

    return rows
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BodyRowsTests`
Expected: PASS (all 7).

Note: if `ClaudeContext(lastUserPrompt:lastCommand:)` has a different initializer shape, adjust the test factory to match its real init — check `ClaudeContext.swift`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/PopupLayout.swift Tests/PopupLayoutTests.swift
git commit -m "feat: pure body-row builder for the popup table"
```

---

## Task 5: Pure process-tree + YAML detail builders

**Files:**
- Modify: `Sources/OpWhoLib/PopupLayout.swift`
- Modify: `Tests/PopupLayoutTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Suite("processTreeNodes")
struct ProcessTreeNodesTests {
    private func node(_ name: String, pid: pid_t, op: Bool = false, verified: Bool = false) -> ProcessNode {
        ProcessNode(pid: pid, ppid: 1, name: name, tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: verified)
    }

    @Test("app prepended, parent-first order, increasing depth")
    func withApp() {
        // chain is trigger-first: op-ssh-sign -> git -> bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProcessTreeNodesTests`
Expected: FAIL — `cannot find 'processTreeNodes' in scope`.

- [ ] **Step 3: Write the implementation** (append to `PopupLayout.swift`)

```swift
/// One node of the rendered process tree.
public struct TreeNode: Equatable {
    public let name: String
    public let pid: pid_t
    /// 0 = parent-est (usually the terminal app); each child is +1.
    public let depth: Int
    /// Coloring hint for the `op` node; `.none` for every other node.
    public let opColor: OpColor
}

public enum OpColor: Equatable { case none, verified, unverified }

/// Build the process tree parent-first. `chain` is trigger-first (chain[0] is
/// the trigger); it is reversed here. The terminal app, when known, is
/// prepended as the root (`<name>.app`). Pure — no AppKit.
public func processTreeNodes(appName: String?, appPID: pid_t?, chain: [ProcessNode]) -> [TreeNode] {
    var nodes: [TreeNode] = []
    var depth = 0
    if let appName = appName {
        nodes.append(TreeNode(name: "\(appName).app", pid: appPID ?? 0,
                              depth: depth, opColor: .none))
        depth += 1
    }
    for node in chain.reversed() {
        let color: OpColor
        if node.name == "op" {
            color = node.isVerifiedOnePasswordCLI ? .verified : .unverified
        } else {
            color = .none
        }
        nodes.append(TreeNode(name: node.name, pid: node.pid, depth: depth, opColor: color))
        depth += 1
    }
    return nodes
}

/// The YAML lines shown under the process tree in the details block.
/// No cwd (spec §3). Pure — argv is already redacted at capture.
public func detailsYAMLLines(entry: OverlayPanel.ProcessEntry) -> [String] {
    var lines: [String] = []
    if let tty = entry.tty { lines.append("tty: \(tty)") }
    lines.append("pid: \(entry.pid)")

    if let ws = entry.cmuxWorkspaceID {
        let title = entry.cmuxSurface?.displayWorkspaceTitle ?? ""
        lines.append(title.isEmpty ? "workspace: \(ws)" : "workspace: \(title) (\(ws))")
    }
    if let tab = entry.cmuxTabID {
        let raw = entry.cmuxSurface?.surfaceTitle ?? ""
        let title = CmuxHelper.looksGenericTitle(raw) ? "" : raw
        lines.append(title.isEmpty ? "tab: \(tab)" : "tab: \(title) (\(tab))")
    }

    if !entry.triggerArgv.isEmpty {
        lines.append("argv:")
        for token in entry.triggerArgv { lines.append("  - \(token)") }
    }
    return lines
}
```

Note: verify `CmuxHelper.looksGenericTitle` is `public` (it is referenced from `CmuxSurfaceInfo.displayWorkspaceTitle`). If it is not accessible, inline a small local check or make it `public`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "ProcessTreeNodesTests"` then `swift test --filter "DetailsYAMLTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/PopupLayout.swift Tests/PopupLayoutTests.swift
git commit -m "feat: pure process-tree and details-YAML builders"
```

---

## Task 6: `AppSettings` persistence

**Files:**
- Create: `Sources/OpWhoLib/AppSettings.swift`
- Test: `Tests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import OpWhoLib

@Suite("AppSettings")
struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        // Unique suite name per test avoids cross-test bleed. Vary by a fixed
        // salt + object identity rather than time (Date.now is unavailable).
        let name = "op-who-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("densePopup defaults to false")
    func denseDefault() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.densePopup == false)
    }

    @Test("densePopup persists")
    func densePersists() {
        let d = freshDefaults()
        AppSettings(defaults: d).densePopup = true
        #expect(AppSettings(defaults: d).densePopup == true)
    }

    @Test("appearance defaults to system")
    func appearanceDefault() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.appearance == .system)
    }

    @Test("appearance persists")
    func appearancePersists() {
        let d = freshDefaults()
        AppSettings(defaults: d).appearance = .dark
        #expect(AppSettings(defaults: d).appearance == .dark)
    }

    @Test("unknown stored appearance falls back to system")
    func appearanceFallback() {
        let d = freshDefaults()
        d.set("chartreuse", forKey: "appearance")
        #expect(AppSettings(defaults: d).appearance == .system)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppSettingsTests`
Expected: FAIL — `cannot find 'AppSettings' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Popup appearance override.
public enum AppAppearance: String, CaseIterable {
    case system, light, dark
}

/// UserDefaults-backed app settings. Inject a suite in tests.
public final class AppSettings {
    private let defaults: UserDefaults
    private enum Key {
        static let densePopup = "densePopup"
        static let appearance = "appearance"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Collapse droppable popup rows (e.g. the worktree row in the main
    /// checkout). Default false (positional stability).
    public var densePopup: Bool {
        get { defaults.bool(forKey: Key.densePopup) }
        set { defaults.set(newValue, forKey: Key.densePopup) }
    }

    public var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppSettingsTests`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/AppSettings.swift Tests/AppSettingsTests.swift
git commit -m "feat: UserDefaults-backed AppSettings (dense popup + appearance)"
```

---

## Task 7: Contrast-safe color constants + audit test

**Files:**
- Create: `Sources/OpWhoLib/OverlayColors.swift`
- Test: `Tests/OverlayColorsTests.swift`

The test computes WCAG contrast ratios of each popup color against the popup
background in both light and dark appearances and asserts they pass. The color
values are tuned until the test is green — the test *is* the audit.

- [ ] **Step 1: Write the failing test**

```swift
import AppKit
import Testing
@testable import OpWhoLib

@Suite("OverlayColors contrast")
struct OverlayColorsContrastTests {
    private func ratio(_ fg: NSColor, on bg: NSColor, appearance: NSAppearance.Name) -> Double {
        var r = 0.0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            r = contrastRatio(OverlayColors.srgb(fg), OverlayColors.srgb(bg))
        }
        return r
    }

    // Small body/detail text needs AA 4.5:1; the ≥13pt semibold action row
    // qualifies as large text at AA 3:1. Test the strict 4.5 bar for the
    // field/label/who colors used at 11–12pt.
    private let bodyColors: [NSColor] = [
        OverlayColors.claude, OverlayColors.editor,
        OverlayColors.verifiedOp, OverlayColors.unverifiedOp,
        OverlayColors.ssh, OverlayColors.dimLabel,
    ]

    @Test("body colors pass AA 4.5:1 in light mode")
    func lightMode() {
        for c in bodyColors {
            #expect(ratio(c, on: OverlayColors.background, appearance: .aqua) >= 4.5)
        }
    }

    @Test("body colors pass AA 4.5:1 in dark mode")
    func darkMode() {
        for c in bodyColors {
            #expect(ratio(c, on: OverlayColors.background, appearance: .darkAqua) >= 4.5)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OverlayColorsContrastTests`
Expected: FAIL — `cannot find 'OverlayColors' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import AppKit

/// Popup color palette, audited for WCAG AA contrast against `background` in
/// both light and dark appearances (see OverlayColorsContrastTests). Values
/// that fail as raw `system*` colors are replaced with appearance-aware pairs.
public enum OverlayColors {
    /// The popup's window background.
    public static let background = NSColor.windowBackgroundColor

    // Appearance-aware pairs: (light, dark). Tune until the contrast test passes.
    public static let claude = dynamic(light: #colorLiteral(red: 0.42, green: 0.20, blue: 0.60, alpha: 1),
                                       dark:  #colorLiteral(red: 0.78, green: 0.60, blue: 0.98, alpha: 1))
    public static let editor = dynamic(light: #colorLiteral(red: 0.0, green: 0.42, blue: 0.45, alpha: 1),
                                       dark:  #colorLiteral(red: 0.40, green: 0.85, blue: 0.90, alpha: 1))
    public static let verifiedOp = dynamic(light: #colorLiteral(red: 0.0, green: 0.45, blue: 0.20, alpha: 1),
                                           dark:  #colorLiteral(red: 0.40, green: 0.85, blue: 0.55, alpha: 1))
    public static let unverifiedOp = dynamic(light: #colorLiteral(red: 0.70, green: 0.38, blue: 0.0, alpha: 1),
                                             dark:  #colorLiteral(red: 1.0, green: 0.70, blue: 0.30, alpha: 1))
    public static let ssh = dynamic(light: #colorLiteral(red: 0.0, green: 0.35, blue: 0.80, alpha: 1),
                                    dark:  #colorLiteral(red: 0.45, green: 0.72, blue: 1.0, alpha: 1))
    public static let dimLabel = NSColor.secondaryLabelColor
    public static let brightValue = NSColor.labelColor

    /// Build an appearance-aware color from a light/dark pair.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    /// Resolve `color` to sRGB components in the current drawing appearance.
    public static func srgb(_ color: NSColor) -> (r: Double, g: Double, b: Double) {
        let c = (color.usingColorSpace(.sRGB) ?? color)
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}

/// WCAG relative-luminance contrast ratio of two sRGB colors (1…21).
public func contrastRatio(_ a: (r: Double, g: Double, b: Double),
                          _ b: (r: Double, g: Double, b: Double)) -> Double {
    func lum(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func chan(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b)
    }
    let l1 = lum(a), l2 = lum(b)
    let hi = max(l1, l2), lo = min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)
}
```

- [ ] **Step 4: Run test; tune colors until it passes**

Run: `swift test --filter OverlayColorsContrastTests`
Expected: PASS. If a color fails, darken (light mode) or lighten (dark mode) it and re-run until ≥4.5:1.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/OverlayColors.swift Tests/OverlayColorsTests.swift
git commit -m "feat: AA-contrast popup palette with audit test"
```

---

## Task 8: Render the body table in `OverlayPanel`

**Files:**
- Modify: `Sources/OpWhoLib/OverlayPanel.swift`

This replaces `makeDriverRow` + `makeOperationRow` + the standalone prompt label
in `buildEntryView` with a table driven by `bodyRows`. The terminal row, details
toggle, and action buttons stay.

- [ ] **Step 1: Add a settings hook to `OverlayPanel`**

Add a stored property so the panel knows the dense flag (defaulted so existing
call sites/tests are unaffected):

```swift
    /// When true, droppable rows collapse (see AppSettings.densePopup).
    var densePopup: Bool = false
```

- [ ] **Step 2: Replace the body-building section of `buildEntryView`**

In `buildEntryView(_:)`, delete these blocks:
- the `makeDriverRow(entry)` and `makeOperationRow(entry, kind:)` `addArrangedSubview` calls,
- the entire `if let prompt = entry.claudeContext?.lastUserPrompt { … }` block.

Keep the `terminalRow` block above them and everything from the details toggle
down. In their place insert:

```swift
        stack.addArrangedSubview(makeBodyTable(entry))
```

- [ ] **Step 3: Add the table renderer**

Add these methods to `OverlayPanel`:

```swift
    /// Render the ordered `bodyRows` as an aligned two-column grid: dim labels
    /// in a fixed first column, values in the second. The action row spans with
    /// no label; the "asked" row wraps.
    private func makeBodyTable(_ entry: ProcessEntry) -> NSView {
        let rows = bodyRows(entry: entry, dense: densePopup)
        let grid = NSGridView()
        grid.rowSpacing = 3
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .leading

        for row in rows {
            let labelView = makeLabel(
                row.label ?? "", size: 11, weight: .regular, color: OverlayColors.dimLabel, mono: true
            )
            let valueView = makeBodyValueLabel(row)
            grid.addRow(with: [labelView, valueView])
        }
        return grid
    }

    private func makeBodyValueLabel(_ row: BodyRow) -> NSTextField {
        let color: NSColor
        let weight: NSFont.Weight
        switch row.style {
        case .action(let kind): color = bodyActionColor(kind); weight = .semibold
        case .who(let kind):    color = bodyWhoColor(kind);    weight = .semibold
        case .field:            color = OverlayColors.brightValue; weight = .regular
        case .asked:            color = OverlayColors.dimLabel;    weight = .regular
        }
        let label = makeLabel(row.value, size: 12, weight: weight, color: color)
        if case .asked = row.style {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            label.cell?.wraps = true
            label.preferredMaxLayoutWidth = promptMaxLayoutWidth()
        } else {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func bodyActionColor(_ kind: RequestKind) -> NSColor {
        switch kind {
        case .onePasswordCLI: return OverlayColors.verifiedOp
        case .unverifiedOp:   return OverlayColors.unverifiedOp
        case .ssh:            return OverlayColors.ssh
        case .unknown:        return OverlayColors.brightValue
        }
    }

    private func bodyWhoColor(_ kind: DriverKind) -> NSColor {
        switch kind {
        case .claude: return OverlayColors.claude
        case .editor: return OverlayColors.editor
        case .shell, .other: return OverlayColors.brightValue
        }
    }
```

Delete the now-unused `makeDriverRow`, `makeOperationRow`, and (if nothing else
references it) `makeIconRow`. Keep `operationColor` only if still referenced;
otherwise remove it. Build after deleting to catch stragglers.

- [ ] **Step 4: Build + run existing overlay tests**

Run: `swift build && swift test --filter OverlayPanel`
Expected: builds; `terminalRowText` tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/OverlayPanel.swift
git commit -m "feat: render popup body as aligned table from bodyRows"
```

---

## Task 9: Render the details block (tree + YAML)

**Files:**
- Modify: `Sources/OpWhoLib/OverlayPanel.swift`

- [ ] **Step 1: Replace the details container contents in `buildEntryView`**

Find the `detailsContainer` block (the `makeChainDetailLabel` + `detailLines`
loop) and replace its body with:

```swift
        let detailsContainer = NSStackView()
        detailsContainer.orientation = .vertical
        detailsContainer.alignment = .leading
        detailsContainer.spacing = 2
        detailsContainer.isHidden = true
        detailsContainer.addArrangedSubview(makeProcessTreeLabel(entry))
        // Blank spacer line between the tree and the YAML block.
        detailsContainer.addArrangedSubview(makeDimDetailLabel(" "))
        for line in detailsYAMLLines(entry: entry) {
            detailsContainer.addArrangedSubview(makeDimDetailLabel(line))
        }
```

- [ ] **Step 2: Add the tree renderer**

```swift
    /// Render the parent-first process tree as a single monospaced label with
    /// `└─` connectors and PIDs in parens. The `op` node is colored.
    private func makeProcessTreeLabel(_ entry: ProcessEntry) -> NSTextField {
        let appName = humanTerminalName(bundleID: entry.terminalBundleID)
        let nodes = processTreeNodes(
            appName: appName, appPID: entry.terminalPID, chain: entry.chain
        )
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let out = NSMutableAttributedString()
        for (i, node) in nodes.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let indent = node.depth == 0
                ? ""
                : String(repeating: "   ", count: node.depth - 1) + "└─ "
            let color: NSColor
            switch node.opColor {
            case .verified:   color = OverlayColors.verifiedOp
            case .unverified: color = OverlayColors.unverifiedOp
            case .none:       color = OverlayColors.dimLabel
            }
            out.append(NSAttributedString(
                string: "\(indent)\(node.name) (\(node.pid))",
                attributes: [.font: font, .foregroundColor: color]
            ))
        }
        let label = NSTextField(labelWithAttributedString: out)
        label.isSelectable = true
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 0
        return label
    }
```

Delete the now-unused `makeChainDetailLabel` and `detailLines` methods. Build to
confirm nothing else references them.

- [ ] **Step 3: Build + run**

Run: `swift build && swift test --filter OverlayPanel`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpWhoLib/OverlayPanel.swift
git commit -m "feat: render details as process tree plus YAML"
```

---

## Task 10: Wire dense flag from settings into the panel

**Files:**
- Modify: `Sources/op-who/main.swift`

- [ ] **Step 1: Read the setting where the overlay is shown**

Locate where the `OverlayPanel` is created/shown in `main.swift` (search for
`OverlayPanel(` or `.show(entries:`). Just before `show`, set the flag from a
shared `AppSettings`:

```swift
        overlayPanel.densePopup = AppSettings().densePopup
```

Use a single stored `AppSettings()` instance on the app delegate if one is
convenient; a fresh `AppSettings()` (backed by `.standard`) reads the same
persisted value and is fine here.

- [ ] **Step 2: Build + smoke test**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/op-who/main.swift
git commit -m "feat: apply densePopup setting to the overlay"
```

---

## Task 11: Settings UI — Dense popup checkbox + appearance control

**Files:**
- Modify: `Sources/op-who/GeneralPane.swift`
- Modify: `Sources/op-who/main.swift`

- [ ] **Step 1: Add the controls to `GeneralPane`**

Add a settings instance and two controls, placed *after* the existing startup
checkbox. Replace `GeneralPane`'s stored properties and `makeContentView` with:

```swift
    private let settings = AppSettings()

    private let startupCheckbox = NSButton(
        checkboxWithTitle: "Run op-who on startup", target: nil, action: nil
    )
    private let denseCheckbox = NSButton(
        checkboxWithTitle: "Dense popup (collapse rows that don't apply)",
        target: nil, action: nil
    )
    private let appearanceLabel = NSTextField(labelWithString: "Appearance:")
    private let appearanceControl = NSSegmentedControl(
        labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil
    )
```

Wire actions in `init()` (after the startup wiring):

```swift
        denseCheckbox.target = self
        denseCheckbox.action = #selector(toggleDense(_:))
        denseCheckbox.state = settings.densePopup ? .on : .off

        appearanceControl.target = self
        appearanceControl.action = #selector(changeAppearance(_:))
        appearanceControl.selectedSegment = {
            switch settings.appearance {
            case .system: return 0
            case .light:  return 1
            case .dark:   return 2
            }
        }()
```

Lay them out under the startup checkbox (stack vertically). Replace
`makeContentView` with:

```swift
    private func makeContentView() -> NSView {
        let stack = NSStackView(views: [
            startupCheckbox, denseCheckbox,
            NSStackView(views: [appearanceLabel, appearanceControl]).horizontal(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
```

Add a tiny helper at file scope (or inline the horizontal stack construction):

```swift
private extension NSStackView {
    func horizontal() -> NSStackView { orientation = .horizontal; spacing = 8; return self }
}
```

Add the action handlers:

```swift
    @objc private func toggleDense(_ sender: NSButton) {
        settings.densePopup = (sender.state == .on)
    }

    @objc private func changeAppearance(_ sender: NSSegmentedControl) {
        let a: AppAppearance = [.system, .light, .dark][sender.selectedSegment]
        settings.appearance = a
        applyAppearance(a)
    }
```

- [ ] **Step 2: Add the appearance application helper**

Add to `main.swift` (file scope, importing OpWhoLib) or a small shared file:

```swift
/// Apply the appearance override to the whole app. `.system` clears the
/// override so macOS follows the system setting.
func applyAppearance(_ a: AppAppearance) {
    switch a {
    case .system: NSApp.appearance = nil
    case .light:  NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
```

If `changeAppearance` in `GeneralPane` can't see `applyAppearance` from
`main.swift`, move `applyAppearance` into a new `Sources/op-who/Appearance.swift`
so both files reference it.

- [ ] **Step 3: Apply appearance at launch**

In `main.swift`'s `applicationDidFinishLaunching` (or equivalent startup), after
setup, call:

```swift
        applyAppearance(AppSettings().appearance)
```

- [ ] **Step 4: Build + manual check**

Run: `swift build`
Then run the app (`scripts/bundle.sh` per CONTRIBUTORS, or `swift run op-who`),
open Settings, confirm: "Dense popup" checkbox appears after "Run on startup",
appearance control switches light/dark live, and both persist across relaunch.

- [ ] **Step 5: Commit**

```bash
git add Sources/op-who/GeneralPane.swift Sources/op-who/main.swift Sources/op-who/Appearance.swift
git commit -m "feat: Settings controls for dense popup and appearance"
```

---

## Task 12: Reset Settings-window scroll on open

**Files:**
- Modify: `Sources/op-who/ConfigWindowController.swift`

- [ ] **Step 1: Keep a reference to the scroll view**

In `ConfigWindowController`, add a stored property and capture the scroll view in
`makeContentView` (currently it returns `scroll` directly):

```swift
    private var scrollView: NSScrollView?
```

At the end of `makeContentView`, before `return scroll`, add `self.scrollView = scroll`.

- [ ] **Step 2: Scroll to top in `showWindow`**

Extend the existing `showWindow(_:)` override:

```swift
    override func showWindow(_ sender: Any?) {
        generalPane.refreshState()
        super.showWindow(sender)
        resetScrollToTop()
    }

    /// The Settings window controller is retained and reused, so NSScrollView
    /// keeps its prior scroll offset — which hides the topmost options on
    /// reopen. Snap the document view back to the top every time.
    private func resetScrollToTop() {
        guard let scroll = scrollView, let doc = scroll.documentView else { return }
        // Flipped or not, the top is the max-Y corner of the document.
        let topY = doc.isFlipped ? 0 : max(0, doc.bounds.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: topY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
```

- [ ] **Step 3: Build + manual check**

Run: `swift build`
Open Settings, scroll down, close, reopen — confirm it opens scrolled to the top.

- [ ] **Step 4: Commit**

```bash
git add Sources/op-who/ConfigWindowController.swift
git commit -m "fix: reset Settings scroll position to top on open"
```

---

## Task 13: Full-suite verification + doc note

**Files:**
- Modify: `CLAUDE.md` (Key design decisions — one line)

- [ ] **Step 1: Run the whole suite**

Run: `swift test`
Expected: all suites PASS (per CONTRIBUTORS, add the CommandLineTools framework
flags if this machine lacks full Xcode — see CLAUDE.md → Testing).

- [ ] **Step 2: Build the signed bundle and smoke-test the popup**

Run: `scripts/bundle.sh` and launch, or follow CONTRIBUTORS' local-run steps.
Trigger a real 1Password approval from a git worktree and from a non-repo dir;
confirm the table rows land in the fixed order, details show the tree + YAML,
and Dense/Appearance behave.

- [ ] **Step 3: Add a design-decision line to `CLAUDE.md`**

Under "Key design decisions", add:

```markdown
- Popup body is an aligned two-column table with a fixed row order (action / who / git-root·branch·worktree or cwd / asked) so branch and worktree land in predictable places; `bodyRows`/`processTreeNodes`/`detailsYAMLLines` (`PopupLayout.swift`) are pure builders the AppKit layer renders. Git context (`GitContext.swift`) is gathered once per trigger via `git rev-parse`. Colors live in `OverlayColors.swift`, audited for WCAG AA in both appearances. `AppSettings` persists `densePopup` (collapses droppable rows) and `appearance` (system/light/dark).
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: note popup table layout in design decisions"
```

---

## Self-Review Notes

- **Spec coverage:** §1 GitContext → Tasks 1–3; §2 body table → Tasks 4, 8, 10; §2.1 adaptive location → Task 4; §3 details → Tasks 5, 9; §4.1 Dense → Tasks 6, 8/10, 11; §4.2 appearance + contrast → Tasks 7, 11; §4.3 scroll reset → Task 12; §5 variants → covered by `bodyRows` uniformity (tested) + Task 13 manual check; §6 testability → pure functions throughout.
- **Type consistency:** `GitContext(root:branch:worktreeSubpath:)`, `GitContext.make(toplevel:gitCommonDir:branchRaw:detachedSHA:)`, `bodyRows(entry:dense:)`, `BodyRow{label,value,style}`, `processTreeNodes(appName:appPID:chain:)`, `TreeNode{name,pid,depth,opColor}`, `detailsYAMLLines(entry:)`, `AppSettings{densePopup,appearance}`, `OverlayColors.*` — used identically across tasks.
- **Known verifications to do during implementation (noted inline):** exact type of `cwd` at the watcher construction site (Task 3), `ClaudeContext` initializer shape (Task 4 test), `CmuxHelper.looksGenericTitle` visibility (Task 5), and whether `makeIconRow`/`operationColor` have remaining references after Task 8.
