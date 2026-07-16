# Derive the popup command from the process tree, not the `-c` string — Design

**Date:** 2026-07-16
**Status:** Approved for planning

## Goal

The popup subtitle for Claude-driven (and other `bash -c`) requests shows
`bash: <first 40 chars of the eval'd shell body>` — usually boilerplate
(`cd … &&`, `set -euo pipefail`, `for V in …`, `echo "…"`) with the operative
command truncated off the end. Two string-parsers, `claudeWrapperCommand` and
`stripLeadingCd`, exist only to reverse-engineer that shell body, and they
partially fail (the `cd` stripper doesn't fire on compound scripts).

Replace this with the real process the shell actually invoked — its argv and CWD
read straight from the OS, using the process chain op-who already walks — and
delete the string-parsing workarounds.

## Evidence

`~/Library/Application Support/com.stigbakken.op-who/recent-requests.json`
(20 most-recent popups) shows the pattern. Titles are correct (built from the
trigger argv via the rule engine); the **subtitle** is the problem:

| Title (good) | Subtitle today (bad) |
|---|---|
| `…op item get` | `bash: cd /Users/stig/git/sunstone/provisioning…` |
| `…op item edit` | `bash: set -euo pipefail\nHZ=$(openssl rand -hex…` |
| `…op item get` | `bash: for V in ‹redacted› admin-cluster-platfo…` |
| `…op run` | `bash: cd /Users/stig/git/sunstone/provisioning…` |
| `is signing a commit` | `bash: git commit -m "feat: migrate LinkedIn qu…` |

Representative chains (trigger-first, as stored in `chainNames`):

- `[op, bash, claude.exe, bash, login]` — the `op` trigger is the wrapper's own
  child; the shell body is a script whose operative line is that same `op`.
- `[op-ssh-sign, git, bash, claude.exe, git, bash, login]` — the real command is
  `git commit`, one non-shell hop below the wrapper, distinct from the trigger.
- `[op, Python, uv, bash, bash, claude.exe, …]` — a `(uv run …)` subshell; the
  first non-shell below the wrapper is `uv`.

## Decisions (from brainstorming)

- **Redundant case → drop the subtitle.** When the invoked command process is
  the trigger process itself (the `set -euo pipefail…` / `cd …` script cases),
  show no command subtitle — the title already names the operation. Keep the CWD.
- **Scope → all shell `-c` wrappers**, not just Claude. Any `sh/bash/zsh/…`
  node invoked with an inline-command flag defers to the process it spawned.

## Design

### The chain walk

For a chain that contains a **shell wrapper** — a shell interpreter
(`shellInterpreterNames`) whose argv carries an inline-command flag
(`shellFlagIsInlineCommand`, i.e. `-c`/`-lc`/`-ic`/…) — identify the
**invoked command process**: starting at that wrapper node, walk the chain
**toward the trigger** (chain is stored trigger-first, so this is toward index
0), skip any further shell nodes, and take the first non-shell process.

- In practice a shell `-c` wrapper that appears as a chain node has forked
  children (a compound command; a simple `bash -c 'op …'` exec-replaces into
  `op`, leaving no bash node), so an invoked-command process always exists —
  it is at worst the trigger itself.
- The invoked-command process is an ancestor of the live trigger, so it is
  alive at capture time.

### Subtitle

- invoked process **==** trigger → **no command subtitle** (keep CWD).
- invoked process **≠** trigger → subtitle is its **redacted argv**
  (`redactArgv`, same treatment as the trigger argv), rendered without the
  `bash:` interpreter prefix. Examples: `git commit -m "feat: migrate…"`,
  `uv run scripts/generate-notifications.py …`.

The existing suppression condition stays: the command subtitle is only shown
when there is no richer Claude **session** label to show instead. Only the
*content* of the line changes.

### CWD

Delete the `stripLeadingCd`-derived `ScriptInfo.workingDirectory` override
outright and rely on the existing `bestCWD` chain walk. The invoked-command
process is already a node in the chain, and `bestCWD` returns the first chain
node with a non-`/` CWD — which is the directory that process inherited from the
`cd /dir &&`. So `stripLeadingCd`'s reconstructed directory is recovered for free
with no replacement code. (Confirmed against `recent-requests.json`: every
Claude case already has a correct non-`/` `triggerCwd`.)

### Deletions

- `ProcessTree.claudeWrapperCommand`
- `ProcessTree.stripLeadingCd`
- `ScriptInfo.workingDirectory` field and its consumer in
  `OnePasswordWatcher` (the `result.scriptInfo?.workingDirectory ?? bestCWD`
  override)
- the shell-inline branch of `ProcessTree.detectScript` (the code that produced
  `-c <snippet>` and the Claude unwrap)

### Kept unchanged

- `detectScript` for **named scripts** (`python foo.py`) and **non-shell inline
  code** (`python -c`, `python -m`, `perl -e`/`-E`, `node -e`/`--eval`/`-p`) —
  these have no child process to defer to, so the interpreter string is still
  the only available signal.
- The rule engine / title derivation (built from trigger argv) — untouched.
- `SecretRedaction` (`redactArgv`) — reused for the invoked-command argv.

## Data-flow after the change

`findTriggerProcesses` → per-trigger `buildChain` (unchanged: walks ppid, stops
at app/helper/launchd). New step: locate the shell `-c` wrapper in the chain and
resolve the **invoked-command process** (first non-shell toward the trigger).
`OnePasswordWatcher.handleWindowEvent` uses that process's argv for the command
subtitle (dropped when it is the trigger) and its CWD (non-`/`) as the CWD,
falling back to `bestCWD`. `makeRequestSummary` renders the redacted argv in
place of `interpreter: scriptName`.

## Testing

Build fixtures from the real chains in `recent-requests.json`:

1. **Redundant drop** — `[op, bash(-c), claude.exe, …]` where the first
   non-shell below the wrapper is the `op` trigger → no command subtitle, CWD
   retained.
2. **Distinct command** — `[op-ssh-sign, git, bash(-c), claude.exe, …]` → subtitle
   is the `git commit` argv, redacted, no `bash:` prefix.
3. **Subshell skip** — `[op, Python, uv, bash, bash(-c), claude.exe, …]` →
   invoked-command process is the first non-shell below the wrapper (`uv`), not
   the intervening subshell.
4. **CWD** — invoked process CWD non-`/` is used; when it is `/`, falls back to
   `bestCWD` and does **not** regress to `/` or Claude's launch dir.
5. **Non-shell interpreters unchanged** — `python foo.py`, `python -c`,
   `perl -e`, `node -e` still resolve via `detectScript` exactly as before.
6. **Plain `bash -c` (non-Claude)** hand-typed one-liner → same child-deference
   behavior (scope decision: all shell `-c` wrappers).
