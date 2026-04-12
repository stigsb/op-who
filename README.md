# op-who

A macOS menu bar app that shows which process is requesting 1Password CLI (`op`) approval.

When 1Password shows its approval dialog, op-who pops up a companion overlay showing:

- The process chain from `op` up to the terminal (e.g. `op → bash → node → zsh`)
- Claude Code session name, if applicable
- Terminal tab title matched by TTY
- PID and TTY device
- Buttons to show the terminal tab or send a message to the TTY

## Building

```bash
swift build
```

## Running

```bash
.build/debug/op-who
```

On first launch, you'll be prompted to grant Accessibility permission in System Settings → Privacy & Security → Accessibility.

## How it works

1. Attaches to the 1Password process via the macOS Accessibility API
2. Watches for new windows (approval dialogs)
3. When a dialog appears, finds all running `op` processes via `sysctl`
4. Walks each `op` process's parent chain, stopping at macOS app boundaries
5. If the parent app is a known terminal, looks up the tab title via AppleScript (Terminal.app, iTerm2) or the Accessibility API (others)
6. If Claude Code is detected in the chain, extracts the project name from open file descriptors
7. Shows a floating overlay panel positioned near the 1Password dialog
8. Dismisses the overlay when the dialog closes or `op` processes exit

## Supported terminals

Tab title lookup works with:
- Terminal.app (AppleScript)
- iTerm2 (AppleScript)
- ghostty, Warp, cmux (Accessibility API fallback)

## Permissions

- **Accessibility** — required to detect 1Password dialogs and read window attributes
- **Automation** — prompted on first use of "Show Tab" (AppleScript to terminal apps)
