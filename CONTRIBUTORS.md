# Contributing to op-who

## Architecture

Swift Package Manager project with a library target (`OpWhoLib`) and thin executable (`op-who`). Non-sandboxed (needs Accessibility API access). Distributed as a signed/notarized `.app` bundle.

For the full architecture overview — components, data flow, dialog lifecycle state machine, process-chain walking algorithm, and design rationale — see [docs/architecture.md](docs/architecture.md).

Source layout:

```
Sources/
  OpWhoLib/           — library target (all logic)
  op-who/main.swift   — NSApplication setup, status bar item, accessibility check
Tests/                — Swift Testing unit tests
```

## Build & run

```bash
swift build
scripts/bundle.sh              # assemble .app bundle (debug)
open .build/op-who.app
```

## Testing

```bash
swift test
```

Tests use Swift Testing (`import Testing`). Covers pure logic: ProcessNode display names, chain formatting, path tidying, TTY validation, process enumeration.

## Releasing

### Version bump, changelog, and tag

Use the `/release` slash command (if using Claude Code), or manually:

```bash
echo "changelog text" | scripts/release-version.sh --bump minor
```

This reads a changelog entry from stdin, bumps the version in `Sources/OpWhoLib/Info.plist`, prepends the entry to `CHANGELOG.md`, commits, and creates a git tag.

The `--bump` flag accepts `major`, `minor`, or `patch`. Use `--dry-run` to preview without making changes.

### Signed release builds

Signed, notarized release builds are created automatically when a version tag is pushed. The GitHub Actions workflow builds the `.app` bundle, signs and notarizes it, creates a GitHub Release, and updates the Homebrew cask.

To build a signed release locally:

```bash
scripts/release.sh                        # auto-detect signing identity
scripts/release.sh "Developer ID Application: Your Name (TEAMID)"
```

Prerequisites:
- A "Developer ID Application" certificate in your keychain
- Notarization credentials stored via `xcrun notarytool store-credentials "op-who"`

The script builds, assembles the `.app` bundle, signs with hardened runtime, notarizes, staples, and produces `.build/op-who.zip`.

### Certificate and signing setup

See [docs/cert-sign-guide.md](docs/cert-sign-guide.md) for full instructions on obtaining a Developer ID certificate, exporting it for CI, and configuring GitHub Actions secrets.

## Install (end users)

```bash
brew tap stigsb/tap
brew install --cask stigsb/tap/op-who
```
