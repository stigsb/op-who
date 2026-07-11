# Popup table layout redesign

Restructure the approval-overlay popup so a person deep in other work can
glance at it and find each piece of information — action, actor, git branch,
worktree — in a predictable place, without visually searching.

## Goals

- **Glanceability over density (by default).** Row order and labels never
  change between triggers. "branch" is always spelled `branch` and always sits
  directly under `git-root`. Learn the layout once; never search it again.
- Surface **git context** (root, branch, worktree) for triggers that run inside
  a repository — the common case on this machine.
- Make the collapsed **details** block read like `pstree` + YAML instead of a
  wall of `key: value` lines.

## Non-goals

- No change to detection, the rule engine, `RequestSummary`, or which triggers
  produce a popup. This is presentation only.
- No new gathering beyond git context. No network, no 1Password calls.

## 1. New data: `GitContext`

A value type plus a gatherer (`Sources/OpWhoLib/GitContext.swift`):

```swift
public struct GitContext: Equatable {
    /// Main worktree top-level, home-abbreviated (e.g. "~/git/sunstone/fleet").
    public let root: String
    /// Current branch, or a short SHA when HEAD is detached. nil if unknown.
    public let branch: String?
    /// Current worktree's top-level *relative to `root`* (e.g.
    /// ".claude/worktrees/foo"). nil when the cwd is in the main worktree.
    public let worktreeSubpath: String?
}

public func gitContext(forCwd cwd: String) -> GitContext?  // nil = not a repo
```

Implementation:

- One subprocess:
  `git -C <cwd> rev-parse --path-format=absolute --show-toplevel --git-common-dir --abbrev-ref HEAD`.
  Output lines come back in flag order.
- `root` = parent of `--git-common-dir` when it ends in `/.git`; otherwise the
  top-level itself. This resolves to the **main** worktree even when the cwd is
  a linked worktree.
- `worktreeSubpath` = `--show-toplevel` made relative to `root`; `nil` when they
  are equal (main checkout).
- `branch` = `--abbrev-ref HEAD`; when that is `HEAD` (detached), fall back to
  `git -C <cwd> rev-parse --short HEAD`.
- Any non-zero exit, timeout (short, ~1s), or unreadable output → `nil`.
- Home-abbreviation reuses the existing `ProcessTree` helper (exposed as needed).

Gathered **once at capture time** in `OnePasswordWatcher`, alongside `cwd`, and
stored on `OverlayPanel.ProcessEntry` as `let gitContext: GitContext?`. The
overlay never shells out on the main thread.

## 2. Body: aligned two-column table

Replaces today's driver row + operation row. The `op-who` header, the terminal
row (app icon · workspace/tab · shortcuts · elapsed timer), and the action
buttons (Show Tab / Send Message) are unchanged and keep their positions.

**Canonical order (identical for every trigger):**

| Slot       | Label       | Content                                                        | Style |
|------------|-------------|----------------------------------------------------------------|-------|
| action     | *(none)*    | `operationDisplay(argv, chain, cwd: nil)` or a special phrase   | kind color, semibold |
| who        | `who`       | actor (Claude Code / editor / shell) + icon; script suffix when present | driver color |
| location   | see §2.1    | git block *or* single `cwd` row                                | dim label, bright value |
| asked      | `asked`     | Claude natural-language prompt, quoted, wraps ≤3 lines          | secondary, present only for Claude |

The **action** row calls `operationDisplay` with `cwd: nil` so the commit-signing
case renders `"signing a commit"` (not `"… in <cwd>"`) — the location now lives
in its own row. Kind colors are the existing ones: green verified `op`, orange
unverified `op` (warning), blue ssh/git, label color for unknown.

The **who** row keeps the current driver coloring (purple Claude, teal editor,
label-color shell) and its icon, and still appends the detected script
(`bash · python deploy.py`).

The **asked** row is placed *below* the location block so the git rows sit at a
fixed offset directly under `who`, unaffected by whether a (variable-height)
prompt is present.

Labels render in a fixed-width first column (dim); values in the second column
(bright). Wrapping applies only to the `asked` value.

### 2.1 Location block (adaptive)

- **Inside a repo** (`gitContext != nil`): three rows, always in this order —
  `git-root`, `branch`, `worktree`.
  - `worktree` value is the subpath relative to `git-root`.
  - In the **main checkout** (`worktreeSubpath == nil`): the row shows `(main)`
    (Dense off) or is dropped (Dense on) — see §4.
- **Not in a repo** (`gitContext == nil`, `cwd` present): a single `cwd` row.
- **No cwd at all**: location block omitted.

This one table applies uniformly to every render variant — see §5.

## 3. Details: process tree + YAML

The collapsed "▸ details" block becomes:

```
cmux.app (1234)
└─ login (5678)
   └─ bash (9101)
      └─ git (1213)
         └─ op-ssh-sign (78288)

tty: /dev/ttys002
pid: 78288
workspace: 81E5BE1A-98F5-435C-9747-F8DE11A6FD13
tab: 81E5BE1A-98F5-435C-9747-F8DE11A6FD13
argv:
  - /Applications/1Password.app/Contents/MacOS/op-ssh-sign
  - -Y
  - sign
  - -n
  - git
  - -f
  - /var/folders/…
```

**Process tree:**
- Parent-est process first (the current chain is trigger-first, so reverse it).
- The **terminal app** (`terminalBundleID` / `terminalPID`) is prepended as the
  root node when known, labeled `<name>.app` (e.g. `cmux.app`). Omitted when the
  terminal app is unknown.
- Linear spine (the chain is a single parent path): each deeper level indented
  by 3 spaces with a `└─ ` connector; PID in parentheses after the name.
- The `op` node keeps its green (verified) / orange (unverified) color; other
  nodes are secondary-label color.

**YAML block** (after one blank line):
- `tty:` and `pid:` (trigger pid) on their own lines.
- `workspace:` and `tab:` on their own lines, values in the value column — only
  when cmux surface IDs are present.
- `argv:` header followed by one `  - <token>` per argv element. argv is already
  redacted at capture (`SecretRedaction`); rendering does not re-redact.
- **Dropped:** the `cwd:` line (redundant with the body) and the `script:` line
  (surfaced in the body `who` row).

## 4. "Dense popup" setting (default OFF)

A persisted boolean controlling how droppable rows behave. Row **order and
labels are identical** in both modes; only whether an empty-in-this-instance row
is reserved differs.

- **OFF (default) — per-family stability:** within git triggers, always render
  `git-root` / `branch` / `worktree`, so those rows never move between one git
  command and the next. In the main checkout the `worktree` row shows `(main)`
  rather than disappearing. Non-git triggers show the single `cwd` row (no empty
  git rows — there is no git information to hunt for).
- **ON — compact:** collapse droppable rows. The `worktree` row is omitted in the
  main checkout.

Surfaced as a checkmarked **status-bar menu item** ("Dense popup"), persisted in
the existing config store. No changes to the rules/Settings window.

## 5. Every render variant, in the canonical layout

The point of the redesign is that all of these share one skeleton:

- **op read / op item get** (green): action = `read op://…` / `use 'op item get'`;
  who = shell or Claude; location adaptive.
- **op signin / inject / run** (green): action phrases from `describeOpInvocation`.
- **unverified op** (orange): identical layout, action in warning color.
- **ssh / scp / sftp / rsync** (blue): action from `operationDisplay`; location
  adaptive (often `cwd`, sometimes a repo).
- **git over ssh — fetch / push** (blue): action e.g. `git fetch origin`; location
  block populated. Prime branch/worktree case.
- **git commit signing** (`op-ssh-sign -n git`): action = `signing a commit`;
  location block populated.
- **plugin update** (Claude background git refresh): action = `plugin update
  check from <url>`; who = Claude Code; no tty → no action buttons (unchanged).
- **unknown**: action = trigger name / raw argv; layout unchanged.

Multiple entries (SSH-agent case) each render the same table.

## 6. Testability

UI-free pure functions carry the logic; the AppKit layer only renders their
output. New / extended pure functions, each unit-tested with Swift Testing:

- `parseGitContext(from rawRevParseOutput:) -> GitContext?` — fixture strings for
  main checkout, linked worktree, detached HEAD, and non-repo (empty/garbage).
- `bodyRows(entry:git:dense:) -> [BodyRow]` where `BodyRow` carries label, value,
  and a style enum — asserts order/labels, adaptive location (repo vs cwd),
  `(main)` vs dropped worktree per `dense`, action-with-`cwd:nil`.
- `processTreeLines(terminalApp:chain:) -> [TreeNode]` (name, pid, depth, color) —
  asserts parent-first order, app inclusion/omission, indentation depth, pids.
- argv → YAML list and the tty/pid/workspace/tab lines — trivial string asserts.

Existing `terminalRowParts` tests and behavior are untouched.

## 7. Files touched

- **New:** `Sources/OpWhoLib/GitContext.swift` (+ its test file).
- `Sources/OpWhoLib/OverlayPanel.swift` — new body table + details renderer;
  `ProcessEntry.gitContext`.
- `Sources/OpWhoLib/OnePasswordWatcher.swift` — gather + pass `gitContext`.
- Config store — `densePopup` boolean; status-menu toggle in the app target.
- Tests under `Tests/…` for the pure functions above.
