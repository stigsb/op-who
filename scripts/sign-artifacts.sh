#!/bin/bash
set -euo pipefail

# Produce SHA256SUMS and SHA256SUMS.sig for release artifacts.
#
# Usage:
#   scripts/sign-artifacts.sh <output-dir>
#
# Hashes every regular file in the top level of <output-dir>, skipping any
# existing SHA256SUMS / SHA256SUMS.sig (so reruns are idempotent), writes
# the checksum manifest to <output-dir>/SHA256SUMS, and signs it with the
# developer's SSH key using `ssh-keygen -Y sign -n file`. The signing key
# is taken from $OP_WHO_SIGNING_KEY, falling back to git config
# user.signingkey. The value may be either a path to a private key file
# or an inline public-key blob ("ssh-rsa AAAA..."), in which case
# ssh-keygen consults ssh-agent for the corresponding private key.
#
# Recipients verify with the trust loop documented in SIGNING.md.

if [[ $# -ne 1 || ! -d "$1" ]]; then
    echo "Usage: scripts/sign-artifacts.sh <output-dir>" >&2
    exit 1
fi

OUT_DIR="$1"
SUMS="$OUT_DIR/SHA256SUMS"
SIG="$OUT_DIR/SHA256SUMS.sig"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_KEY="${OP_WHO_SIGNING_KEY:-$(git -C "$REPO_ROOT" config --get user.signingkey || true)}"
if [[ -z "$SIGNING_KEY" ]]; then
    echo "error: no signing key configured." >&2
    echo "Set OP_WHO_SIGNING_KEY=<path-or-inline-pubkey>, or 'git config user.signingkey'." >&2
    exit 1
fi

# Locate an ssh-agent socket holding the signing key. ssh-keygen does NOT
# read ~/.ssh/config, so IdentityAgent setups (e.g. 1Password) are invisible
# unless SSH_AUTH_SOCK is set explicitly. Probe in order: whatever the env
# already has (default macOS launchd / a user-managed agent), then known
# third-party agent paths.
if ! ssh-add -l >/dev/null 2>&1; then
    for candidate in \
        "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"; do
        if [[ -S "$candidate" ]]; then
            export SSH_AUTH_SOCK="$candidate"
            ssh-add -l >/dev/null 2>&1 && break
        fi
    done
fi
if ! ssh-add -l >/dev/null 2>&1; then
    echo "error: no ssh-agent holds the signing key." >&2
    echo "Make sure the key is loaded (e.g. open the 1Password app, or 'ssh-add')." >&2
    exit 1
fi

# Compute sha256 over every regular file at the top level of OUT_DIR,
# excluding the outputs themselves. Sort for stable ordering.
rm -f "$SUMS" "$SIG"
(
    cd "$OUT_DIR"
    find . -maxdepth 1 -type f \
        ! -name 'SHA256SUMS' ! -name 'SHA256SUMS.sig' \
        -print | sed 's|^\./||' | sort | xargs shasum -a 256
) > "$SUMS"

if [[ ! -s "$SUMS" ]]; then
    echo "error: no files to hash in $OUT_DIR" >&2
    rm -f "$SUMS"
    exit 1
fi

# Sign. If the configured value is a real file, treat it as a private-key
# path; otherwise write it to a temp file and let ssh-keygen look the
# private key up in ssh-agent.
if [[ -f "$SIGNING_KEY" ]]; then
    ssh-keygen -Y sign -n file -f "$SIGNING_KEY" "$SUMS"
else
    TMP_PUB=$(mktemp -t op-who-signing.XXXXXX)
    trap 'rm -f "$TMP_PUB"' EXIT
    printf '%s\n' "$SIGNING_KEY" > "$TMP_PUB"
    ssh-keygen -Y sign -n file -f "$TMP_PUB" -U "$SUMS"
fi

echo "Wrote: $SUMS"
echo "Wrote: $SIG"
