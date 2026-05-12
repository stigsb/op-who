# Release signing

Tags and release artifacts for op-who are signed with the maintainer's SSH key. Two verification paths apply depending on who you are.

## End users (installing a release)

The trust root is **`https://github.com/stigsb.keys`** — GitHub serves the maintainer's public SSH keys over TLS, anchored to the `stigsb` account. Every other key file (including any `allowed_signers` that may appear in the repo or in a release) is convenience only; **do not** treat them as authoritative.

Each release ships three artifacts:
- `op-who-dev.tar.gz` — the package
- `SHA256SUMS` — checksums of the package
- `SHA256SUMS.sig` — SSH signature over `SHA256SUMS`

Before extracting the tarball:

```bash
TMP=$(mktemp -d)
curl -sf https://github.com/stigsb.keys \
  | awk -v who="stig@stigbakken.com" '{print who, "namespaces=\"file\"", $0}' \
  > "$TMP/allowed_signers"

ssh-keygen -Y verify -f "$TMP/allowed_signers" -I stig@stigbakken.com -n file \
  -s SHA256SUMS.sig < SHA256SUMS

shasum -a 256 -c SHA256SUMS
rm -rf "$TMP"
```

If the first command prints `Good "file" signature for stig@stigbakken.com` and the second prints `op-who-dev.tar.gz: OK`, the tarball is authentic to the maintainer's GitHub-listed key.

Threat model: GitHub TLS + integrity of the `stigsb` GitHub account vouch for the signing key. An attacker who replaces the release page cannot make the signature verify unless they also compromise the GitHub account. If you don't trust GitHub or this account, no signature on a release page can help — you would need the key fingerprint out of band.

Maintainer signing-key fingerprint (for out-of-band verification):
```
SHA256:gVg1WOhQ87/Pw4XSx4juhF6OkocRYTaAG6Gy4M69PzY
```

## Contributors / developers

`.github/allowed_signers` is checked in for local `git verify-tag` convenience. Wire it up once per clone:

```bash
git config gpg.ssh.allowedSignersFile .github/allowed_signers
```

`git verify-tag v0.5.0` and `git log --show-signature` will then validate signatures against that file. This is for working on the project — **not** a trust anchor for end users (the file is in the same git history it would otherwise certify).

## Producing a signed release

`scripts/package-dev.sh` builds the tarball and invokes `scripts/sign-artifacts.sh`, which writes `SHA256SUMS` and `SHA256SUMS.sig` into `dist/`. Signing requires the maintainer's key to be reachable through an ssh-agent; the script auto-discovers 1Password's agent socket if `SSH_AUTH_SOCK` doesn't already point at an agent that holds the key.

Then upload all three artifacts to the GitHub Release:

```bash
gh release upload v0.5.0 \
    dist/op-who-dev.tar.gz \
    dist/SHA256SUMS \
    dist/SHA256SUMS.sig
```
