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

## Install (early access)

> op-who is currently distributed as a **self-signed dev build** pending an Apple Developer ID certificate and notarization. Trust is anchored at `https://github.com/stigsb.keys` (TLS + GitHub account integrity). See [SIGNING.md](SIGNING.md) for the threat model.

Each release ships a tarball named for your CPU — `op-who-dev-macos-arm64.tar.gz` for Apple Silicon, `op-who-dev-macos-x86_64.tar.gz` for Intel — alongside `SHA256SUMS` and `SHA256SUMS.sig`. Download all three from the [latest release](https://github.com/stigsb/op-who/releases/latest), verify the signature and checksums per [SIGNING.md](SIGNING.md), then:

```bash
ARCH=$(uname -m)
tar xzf "op-who-dev-macos-${ARCH}.tar.gz"
cd "op-who-dev-macos-${ARCH}"
./install.sh
```

The bundled `install.sh` imports the developer certificate into your login keychain, copies `op-who.app` to `/Applications`, strips the quarantine attribute, and prompts you to grant Accessibility — a one-time manual step macOS does not allow to be scripted.

After install, look for the op-who icon in your menu bar. When 1Password shows an approval dialog, the overlay appears next to it.

When Apple-notarized builds are available, the install path will move to a Homebrew tap.

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
