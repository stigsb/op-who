# op-who

A macOS menu bar utility that shows which process triggered a [1Password](https://1password.com) approval dialog — whether from the CLI (`op`) or the SSH agent.

When 1Password shows its approval dialog, op-who pops up a floating overlay showing:

- The full process chain from the trigger up to the terminal (e.g. `op → bash → node → zsh`)
- Working directory of the requesting process
- Claude Code session name, if applicable
- Terminal tab title matched by TTY
- PID and TTY device
- Buttons to jump to the terminal tab or send a notification to the TTY

## Why?

1Password's approval dialog tells you *which app* is requesting access, but not *which terminal session* or *which command* started it. If you have multiple terminals open running builds, git operations, or Claude Code sessions, you're left guessing. op-who fills in the missing context so you can approve (or deny) with confidence.

## Install

```bash
brew tap stigsb/tap
brew install --cask stigsb/tap/op-who
```

Or build from source:

```bash
swift build
scripts/bundle.sh
open .build/op-who.app
```

Always launch the assembled bundle (`.build/op-who.app`), not the raw binary at `.build/debug/op-who` or `swift run op-who`. `scripts/bundle.sh` re-signs the bundle so the signature carries the stable `CFBundleIdentifier` (`com.stigbakken.op-who`) instead of the per-build hash (`op-who-<sha1>`) that `swift build` assigns. Without that step, TCC treats each rebuild as a fresh app and re-prompts every time.

To make the Accessibility grant survive *clean* rebuilds (where the binary's cdhash changes), see the [Permissions](#permissions) section — ad-hoc signing alone isn't enough on modern macOS, but a one-time self-signed cert is.

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
7. If Claude Code is detected in the chain, extracts the session/project name
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

## Permissions

- **Accessibility** — required to detect 1Password dialogs and read window attributes
- **Automation** — prompted on first use of "Show Tab" (sends AppleScript to terminal apps)

### Making the Accessibility grant persist across rebuilds

On macOS Sonoma and later, TCC pins ad-hoc signed apps by *cdhash* as well as identifier. Every clean rebuild changes the cdhash, so the grant gets silently invalidated even though the System Settings entry still shows "Granted". `op-who` then reports "Accessibility: Not Granted" and the only fix is `tccutil reset` followed by a re-grant.

A one-time self-signed code-signing certificate fixes this — the cert's leaf hash becomes the stable anchor and the grant survives every rebuild. Setup:

1. Open **Keychain Access**.
2. **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: **`op-who Local Dev`** (this exact name is what `scripts/bundle.sh` looks for; override with `OP_WHO_SIGN_IDENTITY=...` if you prefer a different name).
4. Identity Type: **Self Signed Root**.
5. Certificate Type: **Code Signing**.
6. Click **Create**, then **Done**. The cert lands in your *login* keychain and is automatically trusted for code signing for your user.

From the next `scripts/bundle.sh` run onward, the bundle is signed with that cert. Verify with `codesign -dvv .build/op-who.app` — output should include `Authority=op-who Local Dev` and no longer say `Signature=adhoc`. After that, **launch op-who once and grant Accessibility one final time**; subsequent rebuilds will keep the grant.

#### If Accessibility *still* breaks after rebuild

Some macOS versions also require the self-signed cert to be a *trusted* root for code signing. To set that up:

1. In **Keychain Access**, find the `op-who Local Dev` certificate (login keychain → My Certificates).
2. Double-click it → expand **Trust** → set **Code Signing** to **Always Trust**.
3. Close the window (you'll be asked for your login password to write the change).
4. `tccutil reset Accessibility com.stigbakken.op-who`, rebuild, relaunch, re-grant once.

If the cert is missing (or you're a contributor who hasn't set one up yet), `bundle.sh` falls back to ad-hoc signing and prints a warning. The bundle still works; you just have to re-grant after every clean rebuild.

### Resetting permissions

To reset op-who's Accessibility grant (e.g. after a signing-identity change):

```bash
tccutil reset Accessibility com.stigbakken.op-who
```

Use `tccutil reset All com.stigbakken.op-who` to clear every TCC permission op-who has been granted.

## Testing

```bash
swift test
```

## Contributing

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for architecture details, build instructions, and the release process.

## License

MIT
