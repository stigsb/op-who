# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
