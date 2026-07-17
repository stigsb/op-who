# Command-from-Process Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Derive the popup command subtitle from the real process a shell `-c` wrapper invoked (read from the process chain op-who already walks), instead of parsing the `bash -c` string — deleting `claudeWrapperCommand`, `stripLeadingCd`, and `ScriptInfo.workingDirectory`.

**Architecture:** A new pure function `ProcessTree.resolveScriptInfo(chain:triggerPID:claudePID:argvFor:)` replaces the inline interpreter-scan in `buildChain`. When the chain contains a shell node invoked with an inline-command flag (`bash -c`, `sh -lc`, …), it returns the `ScriptInfo` for the first non-shell process below that wrapper (toward the trigger), or `nil` when that process is the trigger itself (the title already names it). When there is no wrapper, it falls back to the existing `detectScript` interpreter/named-script detection. CWD stops using the deleted `workingDirectory` override and relies on the existing `bestCWD` walk. `argvFor` is injected so the whole decision is unit-testable against fixture chains built from real `recent-requests.json` data.

**Tech Stack:** Swift, Swift Testing (`import Testing`), Swift Package Manager (`swift test`, `swift build`).

**Testing note:** If `swift test` fails with `no such module 'Testing'` / `Library not loaded: @rpath/Testing.framework`, this machine is on CommandLineTools-only. Follow the symlink+flags dance in `CLAUDE.md` → "Running tests without full Xcode". Assume full Xcode first; only fall back if the bare command fails.

---

### Task 1: Pure `resolveScriptInfo` with shell-wrapper walk

Introduce the new logic alongside the old code (old code still used by `buildChain` until Task 2). All new code is pure and fixture-testable.

**Files:**
- Modify: `Sources/OpWhoLib/ProcessTree.swift` (add functions near `detectScript`, ~line 337)
- Test: `Tests/ProcessTreeTests.swift`

- [ ] **Step 1: Write the failing tests**

Add a fixture helper and tests inside `struct ProcessTreeTests` in `Tests/ProcessTreeTests.swift` (e.g. after line 30):

```swift
    // Build a chain node with just the fields resolveScriptInfo reads.
    private func pn(_ pid: pid_t, _ name: String) -> ProcessNode {
        ProcessNode(pid: pid, ppid: 0, name: name, tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: false)
    }

    @Test func resolveDropsWhenInvokedCommandIsTrigger() {
        // [op, bash(-c), claude] — the op trigger is the wrapper's own child,
        // so the subtitle is redundant with the title and must be dropped.
        let chain = [pn(1, "op"), pn(2, "bash"), pn(3, "claude")]
        let argv: [pid_t: [String]] = [
            1: ["op", "item", "edit", "flux-webhook-tokens"],
            2: ["bash", "-c", "source /x/.claude/shell-snapshots/s.sh && eval 'op item edit flux-webhook-tokens'"],
            3: ["claude"],
        ]
        let info = ProcessTree.resolveScriptInfo(
            chain: chain, triggerPID: 1, claudePID: 3, argvFor: { argv[$0] ?? [] })
        #expect(info == nil)
    }

    @Test func resolveShowsDistinctInvokedCommand() {
        // [op-ssh-sign, git, bash(-c), claude] — the real command is `git commit`,
        // one non-shell hop below the wrapper, distinct from the op-ssh-sign trigger.
        let chain = [pn(1, "op-ssh-sign"), pn(2, "git"), pn(3, "bash"), pn(4, "claude")]
        let argv: [pid_t: [String]] = [
            1: ["op-ssh-sign", "-Y", "sign"],
            2: ["git", "commit", "-m", "msg"],
            3: ["bash", "-c", "source /x/.claude/shell-snapshots/s.sh && eval 'git commit -m msg'"],
            4: ["claude"],
        ]
        let info = ProcessTree.resolveScriptInfo(
            chain: chain, triggerPID: 1, claudePID: 4, argvFor: { argv[$0] ?? [] })
        #expect(info?.interpreter == "git")
        #expect(info?.scriptName == "commit -m msg")
        #expect(info?.scriptPath == nil)
    }

    @Test func resolveSkipsSubshellToFirstRealProcess() {
        // [op, Python, uv, bash, bash(-c), claude] — a `(uv run …)` subshell sits
        // between the wrapper and uv; skip the shell, land on uv.
        let chain = [pn(1, "op"), pn(2, "Python"), pn(3, "uv"),
                     pn(4, "bash"), pn(5, "bash"), pn(6, "claude")]
        let argv: [pid_t: [String]] = [
            1: ["op", "item", "get", "x"],
            2: ["Python", "-c", "…"],
            3: ["uv", "run", "scripts/generate-notifications.py"],
            4: ["bash", "-c", "source /x/.claude/shell-snapshots/s.sh && eval '(uv run scripts/generate-notifications.py)'"],
            5: ["bash", "-c", "source /x/.claude/shell-snapshots/s.sh && eval '(uv run scripts/generate-notifications.py)'"],
            6: ["claude"],
        ]
        let info = ProcessTree.resolveScriptInfo(
            chain: chain, triggerPID: 1, claudePID: 6, argvFor: { argv[$0] ?? [] })
        #expect(info?.interpreter == "uv")
        #expect(info?.scriptName == "run scripts/generate-notifications.py")
    }

    @Test func resolveFallsBackToNamedScriptWithoutWrapper() {
        // No `-c` wrapper: `python app.py` in the chain resolves via detectScript.
        let chain = [pn(1, "op"), pn(2, "python")]
        let argv: [pid_t: [String]] = [1: ["op", "read", "x"], 2: ["python", "app.py"]]
        let info = ProcessTree.resolveScriptInfo(
            chain: chain, triggerPID: 1, claudePID: nil, argvFor: { argv[$0] ?? [] })
        #expect(info?.interpreter == "python")
        #expect(info?.scriptName == "app.py")
    }

    @Test func resolveFallsBackToNamedShellScriptWithoutDashC() {
        // `bash deploy.sh` is not a `-c` wrapper — detectScript names the script.
        let chain = [pn(1, "op"), pn(2, "bash")]
        let argv: [pid_t: [String]] = [1: ["op", "read", "x"], 2: ["bash", "deploy.sh"]]
        let info = ProcessTree.resolveScriptInfo(
            chain: chain, triggerPID: 1, claudePID: nil, argvFor: { argv[$0] ?? [] })
        #expect(info?.scriptName == "deploy.sh")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ProcessTree 2>&1 | tail -20`
Expected: FAIL — `resolveScriptInfo` is undefined (compile error).

- [ ] **Step 3: Add the implementation**

In `Sources/OpWhoLib/ProcessTree.swift`, add these functions immediately after `detectScript` ends (after line 337, before `private static let shellInterpreterNames`):

```swift
    /// Pick the command to surface as the popup subtitle for a chain.
    ///
    /// When the chain contains a shell invoked with an inline-command flag
    /// (`bash -c`, `sh -lc`, … — Claude Code's Bash-tool wrapper or a
    /// hand-typed one-liner), show the real process that shell invoked rather
    /// than parsing its `-c` string: the first non-shell process below the
    /// wrapper, walking toward the trigger. Returns nil when that process IS
    /// the trigger (the title already names it). With no wrapper, falls back to
    /// interpreter/named-script detection via `detectScript`.
    ///
    /// `argvFor` supplies argv per pid; injected so this is unit-testable.
    static func resolveScriptInfo(
        chain: [ProcessNode],
        triggerPID: pid_t?,
        claudePID: pid_t?,
        argvFor: (pid_t) -> [String]
    ) -> ScriptInfo? {
        if let w = outermostShellWrapperIndex(chain: chain, argvFor: argvFor) {
            var j = w - 1
            while j >= 0 {
                let node = chain[j]
                if node.pid != claudePID, !shellInterpreterNames.contains(node.name) {
                    if node.pid == triggerPID { return nil }
                    let argv = argvFor(node.pid)
                    if isInterpreter(name: node.name),
                       let info = detectScript(interpreter: node.name, argv: argv) {
                        return info
                    }
                    return invokedCommandScriptInfo(name: node.name, argv: argv)
                }
                j -= 1
            }
            return nil
        }

        for node in chain where node.pid != claudePID && isInterpreter(name: node.name) {
            if let info = detectScript(interpreter: node.name, argv: argvFor(node.pid)) {
                return info
            }
        }
        return nil
    }

    /// Index of the outermost (closest-to-terminal) shell node invoked with an
    /// inline-command flag, or nil if the chain has none. A forked subshell
    /// inherits the wrapper's `-c` argv, so several nodes may match; the highest
    /// index is the real wrapper and the lower ones are its subshells.
    private static func outermostShellWrapperIndex(
        chain: [ProcessNode],
        argvFor: (pid_t) -> [String]
    ) -> Int? {
        var result: Int? = nil
        for (i, node) in chain.enumerated() where shellInterpreterNames.contains(node.name) {
            if argvFor(node.pid).dropFirst().contains(where: shellFlagIsInlineCommand) {
                result = i
            }
        }
        return result
    }

    /// Render a plain (non-interpreter) invoked command — `git`, `uv`,
    /// `terraform`, … — as a ScriptInfo: process name as `interpreter`, the
    /// redacted argv tail (no argv[0]) as `scriptName`. Returns nil when the
    /// command carries no arguments (nothing useful beyond the title's name).
    private static func invokedCommandScriptInfo(name: String, argv: [String]) -> ScriptInfo? {
        let redacted = redactArgv(argv)
        guard redacted.count >= 2 else { return nil }
        let rest = redacted.dropFirst().joined(separator: " ")
        return ScriptInfo(interpreter: name, scriptName: truncateSnippet(rest), scriptPath: nil)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ProcessTree 2>&1 | tail -20`
Expected: PASS — all five new tests green, existing ProcessTree tests still green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/ProcessTree.swift Tests/ProcessTreeTests.swift
git commit -m "feat: resolve popup command from the invoked process, not the -c string"
```

---

### Task 2: Wire `buildChain` to `resolveScriptInfo`

Replace the inline interpreter scan with the new function.

**Files:**
- Modify: `Sources/OpWhoLib/ProcessTree.swift:204-217`

- [ ] **Step 1: Replace the inline scan**

In `buildChain`, replace this block (currently lines 204-217):

```swift
        // Find the closest-to-trigger interpreter in the chain and pull its
        // script name. Skip the Claude Code node — its argv is a long
        // bun/cli internal blob, and the Claude Code session label already
        // covers it more usefully.
        var scriptInfo: ScriptInfo? = nil
        for node in chain {
            if node.pid == claudePID { continue }
            guard Self.isInterpreter(name: node.name) else { continue }
            let argv = processArgv(pid: node.pid)
            if let info = Self.detectScript(interpreter: node.name, argv: argv) {
                scriptInfo = info
                break
            }
        }
```

with:

```swift
        // Pick the command to surface as the subtitle. For a shell `-c` wrapper
        // (Claude's Bash tool or a one-liner) this is the real process it
        // invoked; otherwise the interpreter/named-script it's running.
        let scriptInfo = Self.resolveScriptInfo(
            chain: chain,
            triggerPID: chain.first?.pid,
            claudePID: claudePID,
            argvFor: { processArgv(pid: $0) }
        )
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -20`
Expected: build succeeds (a warning about unused `detectScript` shell path may appear — removed in Task 3).

- [ ] **Step 3: Run the full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: PASS. (The old `detectScript` shell-inline tests still pass here — that code is removed in Task 3.)

- [ ] **Step 4: Commit**

```bash
git add Sources/OpWhoLib/ProcessTree.swift
git commit -m "refactor: buildChain uses resolveScriptInfo for the command subtitle"
```

---

### Task 3: Delete `claudeWrapperCommand`, `stripLeadingCd`, and the `detectScript` shell-inline branch

These are now dead for chain purposes — `resolveScriptInfo` handles every shell `-c` case.

**Files:**
- Modify: `Sources/OpWhoLib/ProcessTree.swift` (`detectScript` ~258-337, helpers 342-397)
- Modify: `Tests/ProcessTreeTests.swift` (remove tests 246-367)
- Modify: `Tests/SecretRedactionTests.swift:171-176`

- [ ] **Step 1: Remove the shell-inline branch from `detectScript`**

In `detectScript`, delete the `isShell` local and the inline-command block. Replace lines 260-285:

```swift
        let isShell = shellInterpreterNames.contains(interpreter)
        let isPython = interpreter == "python" || interpreter.hasPrefix("python")

        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a == "--" { i += 1; break }
            if !a.hasPrefix("-") { break }

            if isShell, shellFlagIsInlineCommand(a) {
                let snippet = i + 1 < argv.count ? argv[i + 1] : ""
                if let inner = claudeWrapperCommand(snippet) {
                    let cd = stripLeadingCd(inner)
                    return ScriptInfo(
                        interpreter: interpreter,
                        scriptName: truncateSnippet(redactString(cd?.command ?? inner)),
                        scriptPath: nil,
                        workingDirectory: cd?.directory
                    )
                }
                return ScriptInfo(
                    interpreter: interpreter,
                    scriptName: "-c " + truncateSnippet(redactString(snippet)),
                    scriptPath: nil
                )
            }
            if isPython {
```

with (drops `isShell` and the whole inline block; shell interpreters now fall through to the named-script path at the end of the function):

```swift
        let isPython = interpreter == "python" || interpreter.hasPrefix("python")

        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a == "--" { i += 1; break }
            if !a.hasPrefix("-") { break }

            if isPython {
```

- [ ] **Step 2: Delete the two helper functions and the wrapper doc comment**

Delete `claudeWrapperCommand` (lines 342-373, including its `///` doc block starting at 342) and `stripLeadingCd` (lines 375-397, including its `///` doc block). Leave `shellInterpreterNames` (339-340), `shellFlagIsInlineCommand` (399-404), and `truncateSnippet` (406-411) in place — all still used.

- [ ] **Step 3: Delete the obsolete tests**

In `Tests/ProcessTreeTests.swift`, delete these test functions in full (currently lines 246-367): `bashInlineDashC`, `bashLoginInlineDashLC`, `zshInlineDashC`, `claudeCodeWrapperExtractsEvalCommand`, `claudeCodeWrapperStripsLeadingCd`, `claudeCodeWrapperWithoutCdHasNoWorkingDirectory`, `claudeCodeWrapperUnescapesEmbeddedQuotes`, `claudeCodeWrapperWithoutEvalFallsBack`, `nonClaudeSourceSnippetFallsBack`, `stripLeadingCdRequiresAbsoluteDirAndRemainder`.

Keep `shNoArgsReturnsNil` and `bashInteractiveDashIReturnsNil` — both still return nil under the new `detectScript` and remain valid.

- [ ] **Step 4: Move the redaction test onto `resolveScriptInfo`**

In `Tests/SecretRedactionTests.swift`, replace `detectScriptRedactsSecretInInlineCommand` (lines 171-176) with a test that a secret in a distinct invoked command's argv is redacted through the new path:

```swift
    @Test func resolveScriptInfoRedactsSecretInInvokedCommand() {
        // A distinct invoked command below a `bash -c` wrapper gets its argv
        // redacted via redactArgv.
        let secret = "ghp_" + String(repeating: "a", count: 36)
        let chain = [
            ProcessNode(pid: 1, ppid: 0, name: "op", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
            ProcessNode(pid: 2, ppid: 0, name: "terraform", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
            ProcessNode(pid: 3, ppid: 0, name: "bash", tty: nil, executablePath: nil, isVerifiedOnePasswordCLI: false),
        ]
        let argv: [pid_t: [String]] = [
            1: ["op", "read", "x"],
            2: ["terraform", "apply", "-var", "token=" + secret],
            3: ["bash", "-c", "source /x/.claude/shell-snapshots/s.sh && eval 'terraform apply -var token=…'"],
        ]
        let info = ProcessTree.resolveScriptInfo(
            chain: chain, triggerPID: 1, claudePID: nil, argvFor: { argv[$0] ?? [] })
        #expect(info?.scriptName.contains(secretRedactionPlaceholder) == true)
        #expect(info?.scriptName.contains("ghp_") == false)
    }
```

- [ ] **Step 5: Run the full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: PASS — no references to the deleted functions remain, redaction test green.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpWhoLib/ProcessTree.swift Tests/ProcessTreeTests.swift Tests/SecretRedactionTests.swift
git commit -m "refactor: delete claudeWrapperCommand/stripLeadingCd and the detectScript shell branch"
```

---

### Task 4: Remove `ScriptInfo.workingDirectory` and the CWD override

The invoked process is a chain node, so `bestCWD` already recovers its directory — the override is redundant.

**Files:**
- Modify: `Sources/OpWhoLib/ProcessTree.swift:48-69` (`ScriptInfo`)
- Modify: `Sources/OpWhoLib/OnePasswordWatcher.swift:251-257`

- [ ] **Step 1: Drop the field from `ScriptInfo`**

Replace the `ScriptInfo` struct (lines 48-69) with:

```swift
/// What an interpreter or invoked command in the chain is running.
/// `interpreter` is the short process name (e.g. "python3", "git"),
/// `scriptName` is human-friendly — the script's basename, or the redacted
/// argv tail for a plain command.
public struct ScriptInfo: Equatable {
    public let interpreter: String
    public let scriptName: String
    /// Full path to the script when one was named on argv. nil for
    /// `-c`/`-m`/`-e` invocations and plain commands.
    public let scriptPath: String?

    public init(
        interpreter: String,
        scriptName: String,
        scriptPath: String?
    ) {
        self.interpreter = interpreter
        self.scriptName = scriptName
        self.scriptPath = scriptPath
    }
}
```

- [ ] **Step 2: Simplify the CWD in `OnePasswordWatcher`**

Replace lines 251-257:

```swift
            // Get CWD from the chain — the trigger process (op, ssh) often
            // has CWD of "/", so walk up to find the shell's CWD instead.
            // A Claude Code `cd /dir && cmd` wrapper names the directory
            // explicitly; trust that over the chain walk.
            let cwd = (result.scriptInfo?.workingDirectory
                ?? measure("bestCWD") { ProcessTree.bestCWD(chain: foldedChain) })
                .map(ProcessTree.tidyPath)
```

with:

```swift
            // Get CWD from the chain — the trigger process (op, ssh) often
            // has CWD "/", so bestCWD walks to the first ancestor with a real
            // directory (which is the dir a `cd /x && …` wrapper left behind).
            let cwd = measure("bestCWD") { ProcessTree.bestCWD(chain: foldedChain) }
                .map(ProcessTree.tidyPath)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build 2>&1 | tail -20`
Expected: build succeeds — no remaining references to `workingDirectory`.

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: PASS. (The `workingDirectory` assertions were already deleted in Task 3.)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/ProcessTree.swift Sources/OpWhoLib/OnePasswordWatcher.swift
git commit -m "refactor: drop ScriptInfo.workingDirectory, rely on bestCWD"
```

---

### Task 5: Verify rendering and update docs

Confirm the subtitle/who-line render correctly and refresh the CLAUDE.md design note that describes the deleted workarounds.

**Files:**
- Read-only: `Sources/OpWhoLib/RequestSummary.swift:115-119`, `Sources/OpWhoLib/PopupLayout.swift:47-48`
- Modify: `CLAUDE.md` (the "Claude Code's Bash-tool wrapper" design-decisions bullet)

- [ ] **Step 1: Confirm the renderers need no change**

Read `Sources/OpWhoLib/RequestSummary.swift:115-119` and `Sources/OpWhoLib/PopupLayout.swift:47-48`. Verify both still read `ScriptInfo.interpreter` / `.scriptName` (they do) and that neither referenced `.workingDirectory` (they don't). No code change expected — the `interpreter: scriptName` format now renders e.g. `git: commit -m msg`. If either references `.workingDirectory`, that is a compile error already caught in Task 4; there is nothing to fix here.

- [ ] **Step 2: Run the full suite once more**

Run: `swift test 2>&1 | tail -20`
Expected: PASS, full suite.

- [ ] **Step 3: Update the CLAUDE.md design note**

In `CLAUDE.md`, replace the design-decisions bullet that begins "Claude Code's Bash-tool wrapper (`bash -c source …`) is unwrapped by `ProcessTree.claudeWrapperCommand` …" with:

```markdown
- The popup command subtitle for a shell `-c` wrapper (Claude Code's Bash-tool wrapper `bash -c 'source ~/.claude/shell-snapshots/….sh … && eval '<cmd>' …'`, or a hand-typed one-liner) is read from the **real process the shell invoked**, not by parsing the `-c` string: `ProcessTree.resolveScriptInfo` walks the chain from the outermost shell `-c` node toward the trigger, skips nested subshells, and takes the first non-shell process — showing its redacted argv (`ScriptInfo.interpreter`/`scriptName`), or nothing when that process is the trigger itself (the title already names it). The wrapped command's real CWD is recovered by the ordinary `bestCWD` chain walk (the `cd /dir &&` left it as the invoked process's working directory).
```

- [ ] **Step 4: Build the app bundle and spot-check against real popups**

Run: `swift build 2>&1 | tail -5 && ./scripts/bundle.sh 2>&1 | tail -5`
Expected: build + bundle succeed. Then trigger a couple of real 1Password approvals from a Claude Code session (e.g. an `op item get` inside a script, and a `git commit` that signs via 1Password) and confirm in the popup:
- the boilerplate `bash: cd …` / `bash: set -euo pipefail…` subtitles are gone (dropped when the command is the trigger), and
- a distinct command like `git commit -m …` shows as `git: commit -m …`.

Cross-check the stored results afterward in `~/Library/Application Support/com.stigbakken.op-who/recent-requests.json` (the `subtitle` field).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update wrapper design note for command-from-process"
```

---

## Self-Review

**Spec coverage:**
- "Derive command from invoked process, all shell `-c` wrappers" → Task 1 (`resolveScriptInfo` + `outermostShellWrapperIndex`), wired in Task 2. ✓
- "Redundant case → drop the subtitle" → Task 1 `resolveDropsWhenInvokedCommandIsTrigger` + the `node.pid == triggerPID { return nil }` guard. ✓
- "Delete `claudeWrapperCommand`, `stripLeadingCd`, detectScript shell branch" → Task 3. ✓
- "Delete `ScriptInfo.workingDirectory`, rely on `bestCWD`" → Task 4. ✓
- "Keep `detectScript` for named scripts / non-shell inline" → preserved in Task 3 Step 1 (only the shell branch removed); tested by `resolveFallsBackToNamedScriptWithoutWrapper`, `resolveFallsBackToNamedShellScriptWithoutDashC`, and the retained python/perl/node tests. ✓
- "Reuse `redactArgv`" → `invokedCommandScriptInfo` (Task 1) + redaction test (Task 3 Step 4). ✓
- Testing items 1-6 in the spec → covered by Task 1 tests (drop, distinct, subshell, fallbacks) + Task 3 redaction + Task 5 manual CWD/real-popup check. ✓

**Placeholder scan:** none — every code step shows complete code.

**Type consistency:** `resolveScriptInfo(chain:triggerPID:claudePID:argvFor:)`, `outermostShellWrapperIndex(chain:argvFor:)`, `invokedCommandScriptInfo(name:argv:)`, and `ScriptInfo(interpreter:scriptName:scriptPath:)` are used identically across Tasks 1-4. `argvFor` is `(pid_t) -> [String]` everywhere. `shellFlagIsInlineCommand`, `shellInterpreterNames`, `truncateSnippet`, `redactArgv`, `bestCWD` are all pre-existing symbols left in place.
