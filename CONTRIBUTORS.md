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

Always launch the assembled bundle (`.build/op-who.app`), not the raw binary at `.build/debug/op-who` or `swift run op-who`. `scripts/bundle.sh` re-signs the bundle so the signature carries the stable `CFBundleIdentifier` (`com.stigbakken.op-who`) instead of the per-build hash (`op-who-<sha1>`) `swift build` assigns. Without that step, TCC treats each rebuild as a fresh app and re-prompts every time.

### Keeping the Accessibility grant across rebuilds

On macOS Sonoma and later, TCC pins ad-hoc-signed apps by *cdhash* as well as identifier. Every clean rebuild changes the cdhash, so the grant is silently invalidated even though the System Settings entry still shows "Granted" — `op-who` then reports "Accessibility: Not Granted" and the only fix is `tccutil reset` plus a re-grant.

A one-time self-signed code-signing certificate makes the cert leaf the stable anchor and the grant survives every rebuild. Setup:

1. Open **Keychain Access**.
2. **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: **`op-who Local Dev`** (this exact name is what `scripts/bundle.sh` looks for; override with `OP_WHO_SIGN_IDENTITY=...` if you prefer a different name).
4. Identity Type: **Self Signed Root**.
5. Certificate Type: **Code Signing**.
6. Click **Create**, then **Done**. The cert lands in your *login* keychain and is automatically trusted for code signing for your user.

From the next `scripts/bundle.sh` run onward, the bundle is signed with that cert. Verify with `codesign -dvv .build/op-who.app` — output should include `Authority=op-who Local Dev` and no longer say `Signature=adhoc`. Then **launch op-who once and grant Accessibility one final time**; subsequent rebuilds will keep the grant.

If the cert is missing, `scripts/bundle.sh` falls back to ad-hoc signing and prints a warning. The bundle still works; you just have to re-grant after every clean rebuild.

#### If Accessibility still breaks after rebuild

Some macOS versions require the self-signed cert to be a *trusted* root for code signing:

1. In **Keychain Access**, find the `op-who Local Dev` certificate (login keychain → My Certificates).
2. Double-click it → expand **Trust** → set **Code Signing** to **Always Trust**.
3. Close the window (you'll be asked for your login password to write the change).
4. `tccutil reset Accessibility com.stigbakken.op-who`, rebuild, relaunch, re-grant once.

## Testing

```bash
swift test
```

Tests use Swift Testing (`import Testing`). Covers pure logic: ProcessNode display names, chain formatting, path tidying, TTY validation, process enumeration.

## Releasing

A release flows through four steps: cut a signed tag, push, build local artifacts, upload + publish. Until a Developer ID Application certificate is in place, releases are self-signed dev builds anchored at `https://github.com/stigsb.keys` — see [SIGNING.md](SIGNING.md) for the trust model.

### 1. Cut the release commit and signed tag

Easiest: run `/release` in Claude Code (handles changelog drafting and confirmation). Manually:

```bash
echo "changelog text" | scripts/release-version.sh --bump minor
# Or, when you want a specific version (e.g. matching the current Info.plist):
echo "changelog text" | scripts/release-version.sh --set 0.6.0
```

The script bumps or sets `CFBundleShortVersionString` and `CFBundleVersion` in `Sources/OpWhoLib/Info.plist`, prepends the entry to `CHANGELOG.md`, commits as `release: vX.Y.Z`, and creates an **SSH-signed** annotated tag (`git tag -s`). It refuses to re-tag an existing version. `--dry-run` previews without writing.

Prerequisites:
- `user.signingkey` and (for SSH) `gpg.format=ssh` configured in git.
- The signing key must be reachable through an ssh-agent. 1Password's agent works — `scripts/sign-artifacts.sh` auto-discovers its socket if `SSH_AUTH_SOCK` doesn't already hold the key.

One-time setup so `git verify-tag` works locally:

```bash
git config gpg.ssh.allowedSignersFile .github/allowed_signers
```

### 2. Push

```bash
git push && git push --tags
```

The push triggers `.github/workflows/release.yml`, which opens a **draft** GitHub Release titled `op-who X.Y.Z` with auto-generated notes. The workflow does not build or upload anything — artifact assembly happens locally in step 3.

### 3. Build and sign artifacts

```bash
scripts/package-dev.sh
```

This produces three files in `dist/`:
- `op-who-dev.tar.gz` — the dev-build package (app + cert + `install.sh`)
- `SHA256SUMS` — checksums of every top-level file in `dist/`
- `SHA256SUMS.sig` — SSH signature over `SHA256SUMS`

### 4. Upload and publish

```bash
gh release upload "vX.Y.Z" \
    dist/op-who-dev.tar.gz \
    dist/SHA256SUMS \
    dist/SHA256SUMS.sig

# Review the draft notes in the GitHub UI, edit if needed, then publish:
gh release edit "vX.Y.Z" --draft=false
```

### When the Apple Developer ID cert lands

`.github/workflows/release-notarized.yml` carries the full build → hardened-runtime sign → notarize → publish → Homebrew tap flow. It's gated behind `workflow_dispatch` until the maintainer has a Developer ID Application certificate plus the GitHub Actions secrets (`DEVELOPER_ID_CERTIFICATE_P12`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, `NOTARY_TEAM_ID`, `TAP_GITHUB_TOKEN`).

When those are ready:
1. Re-enable the tag trigger in `release-notarized.yml` (swap `workflow_dispatch:` back to `push: tags: ['v*']`).
2. Retire or repurpose `release.yml` so a single workflow handles each tag.
3. Use `scripts/release.sh` locally for full hardened-runtime + notarized + stapled builds.

The signed-checksums trust loop should stay in place even then — notarization addresses Gatekeeper, not artifact tampering at rest.

See [docs/cert-sign-guide.md](docs/cert-sign-guide.md) for cert setup and CI secret configuration.

## Install (end users)

Until the notarized Homebrew path is live, op-who is distributed as a self-signed dev build. End users verify against `https://github.com/stigsb.keys` per the recipient flow in [SIGNING.md](SIGNING.md), then run the installer from inside the unpacked tarball.

After the Developer ID cert and Homebrew tap are wired up, the install path will become:

```bash
brew tap stigsb/tap
brew install --cask stigsb/tap/op-who
```
