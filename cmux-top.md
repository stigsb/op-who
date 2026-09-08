# Running `cmux top --json` from a menu bar app

Notes for shelling out to `cmux top --json` from an `LSUIElement` app like this
one. `op-who` isn't sandboxed (see `release.entitlements`), so `Process` can
spawn `cmux` freely — but **spawning it is not the hard part.**

Verified against cmux 0.64.20 (100) on macOS 15 by running the CLI from a
simulated GUI context (`setsid`, no controlling tty, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`,
no `CMUX_*` env vars, cwd `/`).

## The blocker: the socket has an ancestry check

`cmux` is a thin IPC client that connects to a Unix domain socket at
`~/.local/state/cmux/cmux.sock` (mode `0600`). **The `0600` permissions are not
the only gate.** cmux's `automation.socketControlMode` setting defaults to
`cmuxOnly`, which authorizes each connection by:

1. reading the peer PID off the accepted socket (`getsockopt` `LOCAL_PEERPID`), then
2. walking that PID's parent chain (up to 128 levels) and requiring it to reach
   the running **cmux.app** process.

(`SocketTransport+Peer.swift`, `SocketClientAuthorization.swift` in
`manaflow-ai/cmux`.) A menu bar app launched by Finder, Login Items, or launchd
has the ancestry `launchd → op-who → cmux`, which never reaches cmux.app, so
**every call is refused under the default mode**:

```
Error: ERROR: Access denied - only processes started inside cmux can connect
```

This is not fixable from op-who's side. It does not depend on tty, cwd,
environment, or the socket password — a full-environment call from a shell that
merely *isn't a cmux descendant* (e.g. an iTerm2 session) is refused too.

## What makes it work: the user must opt in

`automation.socketControlMode` in `~/.config/cmux/cmux.json` (also in cmux
Settings → Automation):

| Mode | Behavior |
| --- | --- |
| `cmuxOnly` | **Default.** Ancestry check as above. op-who is always denied. |
| `automation` | Any local process of the same macOS user; no ancestry check. **This is the one that makes op-who work.** |
| `password` | Same-UID plus a password (`--password` → `CMUX_SOCKET_PASSWORD` → password in Settings). |
| `allowAll` | Any local process, any user, no auth. Unsafe; don't recommend it. |
| `off` | Socket disabled. |

Verified: with `{"automation": {"socketControlMode": "automation"}}` and
`cmux reload-config`, the simulated-GUI invocation above returns exit 0 and
~135 KB of JSON. Reverting the setting restores the denial immediately (cmux
watches the config file; no restart needed).

**Design consequence:** treat cmux data as opt-in and off by default. Whatever
UI surfaces it needs a "requires cmux automation mode" path, because most users
will never have flipped this. Don't ship a feature that silently shows nothing.

## Env vars

- `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` / `CMUX_TAB_ID` — injected into shells
  cmux spawns; only used as the *default* `--workspace`/`--surface`/`--tab`.
  `top --all` doesn't need them. Don't set them.
- `CMUX_SOCKET_PATH` — the built-in default is correct for a normal single-user
  install, but cmux falls back to a user-scoped path if it can't bind the
  default one. It records the live path in `~/.local/state/cmux/last-socket-path`;
  read that file if it exists and fall back to the default.
- `CMUX_SOCKET_PASSWORD` — only relevant in `password` mode.

## Locating the `cmux` binary

GUI apps launched via Finder/Login Items/launchd get a minimal PATH (typically
`/usr/bin:/bin:/usr/sbin:/sbin`), so Homebrew's `bin` is not on it — same
problem this repo already solved for the `op` CLI. Check absolute paths in
order. Note that `/opt/homebrew/bin/cmux` is only a symlink into the app
bundle, so the bundle path is the more reliable candidate and works without
Homebrew:

```swift
private func findCmuxExecutable() -> String? {
    let candidates = [
        "/Applications/cmux.app/Contents/Resources/bin/cmux",  // real binary
        "/opt/homebrew/bin/cmux",                              // symlink to the above
        "/usr/local/bin/cmux",                                 // Intel Homebrew
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
```

## Invocation pattern

Follow `runGit` in `Sources/OpWhoLib/GitContext.swift`: absolute `executableURL`,
capture stdout via `Pipe`, keep stderr off stdout, check `terminationStatus`,
run off the main thread since `waitUntilExit()` blocks.

```swift
import Foundation

enum CmuxTopError: Error {
    case notInstalled
    case accessDenied(String)   // ancestry/auth gate — permanent, stop polling
    case failed(String)         // cmux not running, etc. — retryable
}

func runCmuxTop() throws -> Data {
    guard let exe = findCmuxExecutable() else { throw CmuxTopError.notInstalled }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: exe)
    proc.arguments = ["top", "--all", "--json"]

    let stdout = Pipe(), stderr = Pipe()
    proc.standardOutput = stdout
    proc.standardError = stderr

    try proc.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    guard proc.terminationStatus == 0 else {
        let msg = (String(data: errData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Matched on substring, not equality: cmux uses both "-" and "—" in this
        // message across versions.
        if msg.contains("Access denied") { throw CmuxTopError.accessDenied(msg) }
        throw CmuxTopError.failed(msg)
    }
    return outData
}
```

`accessDenied` must latch — it means a user setting, not a transient failure,
so a periodic timer should stop polling rather than re-shell every tick.

## Output shape

Top-level keys of `cmux top --all --json`, as observed:

```
active, caller, coding_agents, memory_diagnostic, program_totals, sample, totals, windows
```

- `caller` is **`null`** for a GUI caller with no cmux env vars — it identifies
  the calling process's own workspace/surface, which a menu bar app doesn't have.
  Don't rely on it. `active` *is* populated (the focused surface) and carries
  `window_ref`/`workspace_ref`/`pane_ref`/`surface_ref`/`tab_ref`/`surface_type`.
- `windows[]` — the tree: window → workspace → pane → surface. Windows carry
  `ref`, `index`, `visible`, `workspace_count`, `resources`, `top_level_pids`,
  `app_process_pids`, `foreground_pgids`. Workspaces carry `ref`, `index`,
  `title`, `description`, `selected`, `pinned`, `tags`, `panes`, `resources`.
- `resources` (on every node, and on `totals`) — `cpu_percent`, `memory_bytes`,
  `resident_bytes`, `virtual_bytes`, `process_count`, `pids`, plus
  `*_fallback_*` / `unavailable_*` diagnostic arrays.
- `coding_agents[]` — per-agent aggregate (`id`, `display_name`, `asset_name`,
  `resources`), independent of the window tree.

Since `caller` is null, pass `--all`: the implicit "current window" default has
no caller context to resolve against. `--all` is the invocation verified here.

Decode a minimal `Codable` subset for whatever the UI shows. Re-run
`cmux top --all --json | python3 -m json.tool` before adding a field — this is a
third-party CLI's format, not something this repo controls.

## Failure modes

| Condition | Signal | Handling |
| --- | --- | --- |
| cmux not installed | `findCmuxExecutable()` → nil | Feature unavailable. |
| `socketControlMode` is `cmuxOnly` (default) | exit 1, stderr `Access denied - only processes started inside cmux can connect` | Permanent until the user changes a setting. Surface "requires cmux automation mode"; stop polling. |
| `password` mode configured | exit 1, auth-looking stderr | No way to discover the password from this app. Same handling as above. |
| cmux installed but not running | exit non-zero, connection error on stderr | Retryable; degrade quietly. |
