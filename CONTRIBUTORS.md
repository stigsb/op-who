# Contributing to op-who

## Architecture

Swift Package Manager project with three targets: an Objective-C shim (`OpWhoObjCShim`) that traps NSPredicate parse exceptions, a library (`OpWhoLib`) holding all logic, and a thin executable (`op-who`) that wires up `NSApplication` and the Settings UI. Non-sandboxed (needs Accessibility API access). Distributed as a signed/notarized `.app` bundle.

For the full architecture overview — components, data flow, dialog lifecycle state machine, process-chain walking algorithm, and design rationale — see [docs/architecture.md](docs/architecture.md).

Source layout:

```
Sources/
  OpWhoObjCShim/      — ObjC shim: NSPredicate exception trapping
  OpWhoLib/           — library target (all logic)
  op-who/main.swift   — NSApplication setup, status bar item + menu, accessibility check
  op-who/*.swift      — Settings UI (ConfigWindowController, RulesPane, GeneralPane, …)
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

Tests use Swift Testing (`import Testing`). Coverage centers on the pure logic: the rule engine and template rendering, predicate parsing/lexing/completion, candidate folding and ranking, approval-window classification and the dismissal decision, update-version comparison, Claude/cmux context, process-chain formatting, and TTY validation. See [docs/architecture.md §8](docs/architecture.md#8-testing-strategy) for the full breakdown and what's deliberately left to manual validation.

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

Releases are notarized, Developer ID–signed builds published by CI. The flow: cut a signed tag, push it, and `.github/workflows/release-notarized.yml` builds, signs, notarizes, publishes the GitHub Release (`.zip` + `.pkg`), and updates the Homebrew cask — no manual artifact upload.

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
- The signing key must be reachable through an ssh-agent (`git tag -s` signs via `SSH_AUTH_SOCK`). 1Password's agent works — point `SSH_AUTH_SOCK` at the agent that holds the key.

One-time setup so `git verify-tag` works locally:

```bash
git config gpg.ssh.allowedSignersFile .github/allowed_signers
```

### 2. Push

```bash
git push && git push --tags
```

The tag push triggers `.github/workflows/release-notarized.yml`, which runs on `macos-latest` and:

- builds and hardened-runtime signs `op-who.app` with the **Developer ID Application** cert,
- notarizes + staples it and zips it to `op-who.zip`,
- builds the notarized `op-who-<version>.pkg` (**Developer ID Installer** cert) via `scripts/build-pkg.sh`,
- publishes the GitHub Release with both artifacts and an `## Install` section from `.github/release-install-template.md`,
- updates the `op-who` cask in `stigsb/homebrew-tap`.

That's the whole release — there's no manual build or upload step.

#### Required GitHub Actions secrets

These live in the **`release` GitHub Environment**, not as repo-level secrets. The environment's deployment policy only permits the `v*` tag and the `main` branch, so a pull request — from a fork or an in-repo branch — can never run a workflow that reads them. Set each with `gh secret set <NAME> --env release`:

`DEVELOPER_ID_CERTIFICATE_P12` (+ `_PASSWORD`) for the app, `DEVELOPER_ID_INSTALLER_P12` (+ `_PASSWORD`) for the pkg, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, and `TAP_GITHUB_TOKEN` (push access to `stigsb/homebrew-tap`). The Apple Team ID isn't a secret — it's a public `env.NOTARY_TEAM_ID` literal in the workflow. See [docs/cert-sign-guide.md](docs/cert-sign-guide.md) for how these are produced and configured.

### Building a release locally (optional)

CI is the source of truth, but you can produce the exact notarized artifacts on your own Mac — handy for testing before you tag:

```bash
scripts/release.sh
```

It builds, hardened-runtime signs, notarizes, staples, and zips `op-who.app`, and builds the notarized `.pkg`. Store the notary credential once (the scripts use the `op-who` profile by default):

```bash
xcrun notarytool store-credentials "op-who" \
  --apple-id <your-apple-id> --team-id HZ76GWS9YM \
  --password <app-specific-password>   # from appleid.apple.com
```

### Release artifacts: `.zip` (Homebrew) and `.pkg` (Fleet/MDM)

Each release produces two distributables from the same signed, notarized `op-who.app`:

- **`op-who.zip`** — drag-install artifact for the Homebrew cask (`stigsb/homebrew-tap`, installed as `stigsb/tap`). Signed with the **Developer ID Application** cert, notarized, stapled. CI regenerates the cask on each tag.
- **`op-who-<version>.pkg`** — installer for MDM/Fleet software distribution. Signed with the **Developer ID Installer** cert (and notarized). Fleet installs it non-interactively. Beyond dropping `op-who.app` into `/Applications`, the pkg installs a login LaunchAgent (`packaging/launchd/com.stigbakken.op-who.plist`) to `/Library/LaunchAgents` and runs `packaging/scripts/postinstall`, which boots the agent for the logged-in user so a silent push takes effect without a logout. Built by `scripts/build-pkg.sh` (invoked by both `release-notarized.yml` and `scripts/release.sh`).

  Accessibility (and Apple Events for Terminal/iTerm2) can be pre-granted on managed Macs via the PPPC profile in the `fleet-config` repo — keyed on Team ID `HZ76GWS9YM`, so it only matches Developer ID–signed builds.

See [docs/cert-sign-guide.md](docs/cert-sign-guide.md) for certificate setup and how the CI secrets are produced.

## Install (end users)

op-who is a notarized, Developer ID–signed app installed via Homebrew:

```bash
brew install --cask stigsb/tap/op-who
```

See the [README](README.md#install) for the manual `.zip` / `.pkg` alternatives.
