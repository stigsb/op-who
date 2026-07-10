# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.10.0] - 2026-07-10

- Added: Secrets in captured argv, inline command snippets, and Claude Code context are redacted before display, logging, or storage.
- Added: Signed, notarized `.pkg` installer (Developer ID) for MDM/Fleet distribution, alongside the Homebrew `.zip`.

- Added: Secrets in captured argv, inline-command snippets, and Claude Code context are redacted (`op` password fields, known token shapes, high-entropy blobs) before display, logging, rule matching, or storage.
- Added: Signed `.pkg` installer (Developer ID Installer, notarized) for MDM/Fleet software distribution, alongside the Homebrew `.zip`. The pkg installs a login LaunchAgent and boots it via a postinstall so a silent push takes effect without a logout.

## [0.9.0] - 2026-06-16

- Added: "About op-who" menu item showing the running version.
- Added: "Check for Updates…" menu item that compares against the latest GitHub release.
- Fixed: Overlay timer now starts at 0 when the popup appears, measuring how long the approval has been pending rather than the trigger process's age (previously a long-lived ssh session started the timer at its full age).
- Fixed: Only bare "1Password" windows are treated as approval prompts, avoiding spurious overlays from other 1Password windows.

## [0.8.0] - 2026-05-30

- Added: Overlay names the script driving the trigger when a shell or interpreter is in the chain (e.g. `python deploy.py`).
- Fixed: Overlay now dismisses correctly when 1Password's main window is the tracked window.
- Fixed: Overlay no longer shows the wrong workspace name when two cmux sessions collide on a tty.

## [0.7.1] - 2026-05-26

- Fixed: Overlay no longer stays pinned during long-lived SSH sessions after the 1Password prompt is dismissed.

## [0.7.0] - 2026-05-21

- Added: Rules now use NSPredicate-format expressions — full Boolean logic over trigger fields; all 17 built-ins rewritten.
- Added: Rule editor with syntax highlighting, keyword and identifier completion, and inline error reporting.
- Added: Test Predicate window replays the predicate against captured recent requests so you can verify matches before saving.
- Added: Live template preview renders the draft rule against a random recent request as you type.
- Added: Tilde expansion in predicate string literals (`triggerCwd BEGINSWITH "~/git/foo"` now matches).
- Added: `docs/rules.md` walks through the rule format; linked from README.
- Changed: Settings gains drag handles between the rule list, predicate editor, and detail form; Test Predicate is a free-floating window.
- Changed: Standard editing shortcuts (Cmd-C/V/X/Z) now work in Settings via an installed Edit menu.
- Changed: "From recent" rule prefill now populates the cwd-prefix and argv tokens from the picked record.
- Removed: Old structured-matcher UI replaced by the single predicate editor.
- Changed: User-authored `rules.json` from 0.6.x will not load — re-author user rules in the new predicate syntax; built-ins still seed normally.

## [0.6.0] - 2026-05-18

- Added: Configurable rule engine — user-editable rules with matchers and templates override or extend the built-in detectors.
- Added: Settings window (Cmd-,) — enable/disable built-in rules, clone them, or build new rules from recent triggered requests.
- Added: Free-form comment field on rules for personal notes.
- Changed: "Run on startup" moved from the menu-bar menu into Settings → Options.
- Changed: Menu-bar menu pared down to Accessibility status, Settings…, and "Quit op-who" (now self-identified).
- Fixed: Stray off-state glyphs no longer appear next to non-toggleable menu items.
- Fixed: Process argv buffer now sized to ARG_MAX instead of a 4 KB cap, so very long command lines are no longer truncated.

## [0.5.2] - 2026-05-12

- Changed: Menu-bar icon is now a "?" in a double-circle, paired visually with the 1Password app icon.
- Changed: Overlay's terminal row leads with the workspace/tab name (bright) and trails with the terminal app name (dim).
- Fixed: install.sh in v0.5.1 was unconditionally refusing to run.
- Changed: Release tarballs are now arch-tagged (`op-who-dev-macos-<arch>.tar.gz`); install.sh ships inside the tarball, not as a separate artifact.
- Added: GitHub release pages lead with an `## Install` walkthrough above the auto-generated changes list.
- Added: `scripts/upload-dev.sh` for one-step "upload dist/ and publish" during release.

## [0.5.1] - 2026-05-12

- Changed: `install.sh` is now a release-pinned dual-mode installer — runs standalone (downloads + verifies the tarball via signed checksums) or from inside an unpacked tarball.
- Changed: README now leads with early-access install; build/release details moved to `CONTRIBUTORS.md`.

## [0.5.0] - 2026-05-12

- Added: macOS menu-bar utility that identifies which process triggered a 1Password approval dialog (CLI or SSH agent), driven by the Accessibility API and shown as an overlay near the 1Password window.
- Added: Process-chain detection for `op` CLI, ssh/git/scp/sftp/rsync clients, and SSH commit-signing flows; noise filters drop 1Password's internal `op` helper and non-network `git` subcommands.
- Added: Claude Code awareness — purple highlight on the trigger row, last user prompt (wrapped at ~40% screen width), last relevant command, and Claude session ID.
- Added: Detect Claude Code background plugin/marketplace update fetches (`git` under `~/.claude/plugins/`) and label the approval as "plugin update check from <remote>" so the user can see it's housekeeping rather than their own command.
- Added: cmux integration surfaces workspace and tab names from the cmux session file; iTerm tab title/shortcut probe and Terminal.app tab title via AppleScript.
- Added: Code-signature verification of the 1Password app and `op` CLI binaries before trusting any identity reported in the overlay; TTY-path validation and confirmation alert before writing any message back to a terminal.
- Added: Hardened-runtime release packaging (`scripts/release.sh`) with codesign + notarization plus a notarized-release GitHub Actions workflow (parked until an Apple Developer ID cert is configured).
- Added: Self-signed dev-build distribution: `scripts/package-dev.sh` produces a tarball with the app, the public cert, and `scripts/install.sh` for one-shot install on another Mac.
- Added: Draft-release GitHub Actions workflow that opens a draft release on every `v*` tag push for manual artifact upload.
- Added: Release tags are signed by default (`git tag -s`), using the maintainer's SSH key via whatever `gpg.format` is configured.
- Added: Signed-checksums trust loop for release artifacts — `scripts/package-dev.sh` produces `SHA256SUMS` and `SHA256SUMS.sig` alongside the tarball; recipients verify against `https://github.com/stigsb.keys` over TLS. See `SIGNING.md`.
- Added: `.github/allowed_signers` for `git verify-tag` developer convenience (one-time `git config gpg.ssh.allowedSignersFile .github/allowed_signers`).
- Fixed: Overlay no longer tears down prematurely when short-lived SSH siblings exit while the 1Password approval window is still visible — dismissal now requires both the AX window to be gone and all trigger processes to have exited.
