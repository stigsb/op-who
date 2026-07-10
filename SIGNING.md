# Release signing

op-who releases are signed at two layers: the **app** is signed with an Apple **Developer ID Application** certificate and notarized by Apple, and release **tags** are signed with the maintainer's SSH key. Different audiences rely on different layers.

## End users (installing a release)

op-who is distributed as a notarized, Developer ID–signed app. The trust anchor for installation is **Apple notarization + Gatekeeper**: macOS verifies the Developer ID signature and the stapled notarization ticket before the app runs. The recommended install is Homebrew:

```bash
brew install --cask stigsb/tap/op-who
```

The cask downloads `op-who.zip` from the GitHub Release; Gatekeeper validates the signature and notarization on first launch. The `.pkg` installer (for MDM/Fleet) is signed with a **Developer ID Installer** certificate and notarized the same way.

You don't need to verify checksums by hand — a tampered or unsigned build won't pass Gatekeeper.

## Contributors / developers (verifying tags)

Release tags are SSH-signed with the maintainer's key. The trust root is **`https://github.com/stigsb.keys`** — GitHub serves the maintainer's public SSH keys over TLS, anchored to the `stigsb` account.

`.github/allowed_signers` is checked in for local `git verify-tag` convenience. Wire it up once per clone:

```bash
git config gpg.ssh.allowedSignersFile .github/allowed_signers
```

`git verify-tag vX.Y.Z` and `git log --show-signature` then validate signatures against that file. This is for working on the project — **not** an end-user trust anchor (the file lives in the same git history it would otherwise certify).

Maintainer signing-key fingerprint (for out-of-band verification):
```
SHA256:gVg1WOhQ87/Pw4XSx4juhF6OkocRYTaAG6Gy4M69PzY
```

## Producing a release

Releases are built and published by `.github/workflows/release-notarized.yml` on every `v*` tag push: it hardened-runtime signs the app (Developer ID Application), notarizes and staples it, builds the notarized `.pkg` (Developer ID Installer), publishes the GitHub Release, and updates the Homebrew cask. `scripts/release.sh` reproduces the same notarized artifacts locally. See [CONTRIBUTORS.md](CONTRIBUTORS.md#releasing) for the full flow and the required GitHub Actions secrets.
