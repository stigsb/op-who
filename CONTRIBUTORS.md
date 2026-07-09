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

### Running tests without full Xcode

With only the Command Line Tools installed (no `Xcode.app`), `swift test` fails — first with `no such module 'Testing'`, then, once the framework search path is supplied, with a `dlopen` failure for `@rpath/lib_TestingInterop.dylib`. The swift-testing framework ships with the CLT but isn't on the default import/rpath search paths. Point the compiler and linker at it:

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
INTEROP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$INTEROP"
```

`Testing.framework` lives under `$FW`; `lib_TestingInterop.dylib` (which the framework dlopens at load time) lives under `$INTEROP` — both directories must be on the runtime rpath. CI runs on `macos-latest` with full Xcode, so plain `swift test` works there and this workaround is only needed for local CLT-only setups.

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
- `op-who-dev-macos-<arch>.tar.gz` — the dev-build package (app + cert + `install.sh`), where `<arch>` is the host CPU (`arm64` or `x86_64` from `uname -m`)
- `SHA256SUMS` — checksums of every top-level file in `dist/`
- `SHA256SUMS.sig` — SSH signature over `SHA256SUMS`

### 4. Upload and publish

```bash
scripts/upload-dev.sh           # uploads dist/* and publishes the release
scripts/upload-dev.sh --draft   # uploads but leaves the release as a draft
```

The script defaults to publishing (`draft=false`). The draft release itself was opened by `.github/workflows/release.yml` on tag push, with `## Install` instructions (from `.github/release-install-template.md`) and a `## Changes` section auto-generated from PR/commit history. Pass `--draft` if you want to review or edit the notes in the GitHub UI before flipping the switch.

### Release artifacts: `.zip` (Homebrew) and `.pkg` (Fleet/MDM)

Each release produces two distributables from the same signed, notarized `op-who.app`:

- **`op-who.zip`** — drag-install artifact for the Homebrew cask (`stigsb/tap`). Signed with the **Developer ID Application** cert, notarized, stapled.
- **`op-who-<version>.pkg`** — installer for MDM/Fleet software distribution. Signed with the **Developer ID Installer** cert (and notarized). Fleet installs it non-interactively. Beyond dropping `op-who.app` into `/Applications`, the pkg installs a login LaunchAgent (`packaging/launchd/com.stigbakken.op-who.plist`) to `/Library/LaunchAgents` and runs `packaging/scripts/postinstall`, which boots the agent for the logged-in user so a silent push takes effect without a logout. Build it with `scripts/build-pkg.sh` (called automatically by `scripts/release.sh`).

  Accessibility (and Apple Events for Terminal/iTerm2) can be pre-granted on managed Macs via the PPPC profile in the `fleet-config` repo — keyed on Team ID `HZ76GWS9YM`, so it only matches Developer ID–signed builds.

### When the Apple Developer ID cert lands

`.github/workflows/release-notarized.yml` carries the full build → hardened-runtime sign → notarize → publish → Homebrew tap flow. It's gated behind `workflow_dispatch` until the maintainer has the Developer ID **Application** *and* **Installer** certificates plus the GitHub Actions secrets (`DEVELOPER_ID_CERTIFICATE_P12`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `DEVELOPER_ID_INSTALLER_P12`, `DEVELOPER_ID_INSTALLER_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, `NOTARY_TEAM_ID`, `TAP_GITHUB_TOKEN`).

For local notarization, store an app-specific-password credential once (the scripts use the `op-who` profile by default):

```bash
xcrun notarytool store-credentials "op-who" \
  --apple-id <your-apple-id> --team-id HZ76GWS9YM \
  --password <app-specific-password>   # from appleid.apple.com
```

When the secrets are ready:
1. Re-enable the tag trigger in `release-notarized.yml` (swap `workflow_dispatch:` back to `push: tags: ['v*']`).
2. Retire or repurpose `release.yml` so a single workflow handles each tag.
3. Use `scripts/release.sh` locally for full hardened-runtime + notarized + stapled builds (produces both the `.zip` and the `.pkg`).

The signed-checksums trust loop should stay in place even then — notarization addresses Gatekeeper, not artifact tampering at rest.

See [docs/cert-sign-guide.md](docs/cert-sign-guide.md) for cert setup and CI secret configuration.

## Install (end users)

Until the notarized Homebrew path is live, op-who is distributed as a self-signed dev build. End users verify against `https://github.com/stigsb.keys` per the recipient flow in [SIGNING.md](SIGNING.md), then run the installer from inside the unpacked tarball.

After the Developer ID cert and Homebrew tap are wired up, the install path will become:

```bash
brew tap stigsb/tap
brew install --cask stigsb/tap/op-who
```
