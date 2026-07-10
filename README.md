# op-who

A macOS menu bar utility that shows which process triggered a [1Password](https://1password.com) approval dialog — whether from the CLI (`op`) or the SSH agent.

When 1Password shows its approval dialog, op-who pops up a floating overlay showing:

- The full process chain from the trigger up to the terminal (e.g. `op → bash → node → zsh`)
- Working directory of the requesting process
- Claude Code session name and last prompt, if applicable
- Terminal tab title matched by TTY
- PID and TTY device
- Buttons to jump to the terminal tab or send a notification to the TTY

## Why?

1Password's approval dialog tells you *which app* is requesting access, but not *which terminal session* or *which command* started it. If you have multiple terminals open running builds, git operations, or Claude Code sessions, you're left guessing. op-who fills in the missing context so you can approve (or deny) with confidence.

## Install

op-who is a notarized, Developer ID–signed macOS app. Install it with [Homebrew](https://brew.sh):

```bash
brew install --cask stigsb/tap/op-who
```

`brew upgrade --cask op-who` keeps it current.

Prefer a manual install? Download `op-who.zip` from the [latest release](https://github.com/stigsb/op-who/releases/latest), unzip it, and drag `op-who.app` to `/Applications`. For MDM/Fleet deployment, each release also ships a signed `op-who-<version>.pkg` installer.

After install, look for the op-who icon in your menu bar and grant Accessibility once when prompted (System Settings → Privacy & Security → Accessibility). When 1Password shows an approval dialog, the overlay appears next to it.

## Requirements

- macOS 13+
- 1Password 8 with CLI or SSH agent integration enabled

## How it works

1. Watches for the 1Password process and verifies its code signature (Apple Team ID `2BUA8C4S2C`)
2. Attaches an AX observer to detect new windows (approval dialogs)
3. Validates that detected windows are actual approval dialogs (not just any 1Password window)
4. Finds trigger processes: `op` CLI processes (signature-verified) or SSH client processes (`ssh`, `git`, `scp`, `sftp`, `rsync`)
5. Walks each trigger's parent chain, stopping at macOS app boundaries (since 1Password already shows the app name)
6. Looks up terminal tab titles via AppleScript (Terminal.app, iTerm2) or the Accessibility API (Ghostty, Warp, and others)
7. If Claude Code is detected in the chain, extracts the session/project name and last prompt
8. Shows a floating overlay positioned near the 1Password dialog
9. Automatically dismisses the overlay when the dialog closes or trigger processes exit

## Supported terminals

| Terminal | Tab title lookup | Tab activation |
|----------|-----------------|----------------|
| Terminal.app | AppleScript | AppleScript |
| iTerm2 | AppleScript | AppleScript |
| Ghostty, Warp, others | Accessibility API | App activation |

## Rules

The overlay's one-line description is produced by a configurable rules engine. A default set of built-ins covers common cases (`git push`, `op read`, SSH key signing, Claude plugin update checks, etc.); you can disable any built-in or add your own user rules from Settings. See [docs/rules.md](docs/rules.md) for the rule anatomy, NSPredicate cheatsheet, and worked examples.

## Security

op-who validates the identity of processes it interacts with:

- **1Password app** — code signature verified before attaching the AX observer
- **`op` CLI** — executable path resolved and code signature checked; verified binaries shown in green, unverified in orange
- **TTY paths** — validated against `/dev/ttys[0-9]+` before any read/write operations
- **TTY messages** — only written when you explicitly click "Send Message" in the overlay

Release-artifact trust is documented in [SIGNING.md](SIGNING.md).

## Permissions

- **Accessibility** — required to detect 1Password dialogs and read window attributes
- **Automation** — prompted on first use of "Show Tab" (sends AppleScript to terminal apps)

### Resetting permissions

```bash
tccutil reset Accessibility com.stigbakken.op-who
```

Use `tccutil reset All com.stigbakken.op-who` to clear every TCC permission op-who has been granted.

## Contributing

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for architecture, build instructions, local-signing setup, and the release process.

## License

MIT
