# op-who

macOS menu bar utility that identifies which process triggered a 1Password approval dialog (CLI or SSH agent).

## Architecture

Swift Package Manager executable, no Xcode project. Non-sandboxed (needs Accessibility API access).

### Source files

- `main.swift` — NSApplication setup, status bar item ("op?"), accessibility permission check
- `ProcessTree.swift` — Process discovery via `sysctl(KERN_PROC)`, parent chain walking, Mac app detection via NSWorkspace, Claude Code detection via `KERN_PROCARGS2` and `lsof`, CWD lookup via `proc_pidinfo`
- `OnePasswordWatcher.swift` — AXObserver watching 1Password for window creation/focus events, triggers on both `op` (CLI) and SSH client processes (ssh, git, scp, sftp, rsync), polls to detect dialog dismissal
- `OverlayPanel.swift` — Floating NSPanel showing process chain, CWD, session info, TTY, and action buttons
- `TerminalHelper.swift` — Tab title lookup (AppleScript for Terminal.app/iTerm2, AX API fallback), tab activation, TTY message writing

### Key design decisions

- Chain stops at any process registered as a macOS app (has bundle ID in NSWorkspace) since 1Password already shows the app name
- Trigger processes with no parent chain and no TTY are filtered out (1Password's own internal `op` helper)
- Dialog detection uses window title filtering (not content scanning) because 1Password's Electron web view loads asynchronously
- SSH agent dialogs detected by finding ssh/git/scp/sftp/rsync processes alongside 1Password's internal `op` helper
- Dialog dismissal detected by polling (500ms): checks AX element validity + whether trigger process PIDs still exist
- CWD walks the process chain to find the first non-`/` directory (trigger processes often have CWD `/`)
- Claude Code detected by checking `node` process args for "claude" or "@anthropic" strings

## Build & run

```bash
swift build
.build/debug/op-who
```
