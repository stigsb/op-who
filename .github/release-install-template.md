## Install

> op-who is a self-signed dev build, distributed pending an Apple Developer ID certificate and notarization. Trust is anchored at `https://github.com/stigsb.keys`. See [SIGNING.md](https://github.com/__REPO__/blob/__TAG__/SIGNING.md) for the threat model.

The release ships one tarball per CPU arch (`arm64` for Apple Silicon, `x86_64` for Intel). Download all three artifacts, verify them, then install:

```bash
ARCH=$(uname -m)
BASE=https://github.com/__REPO__/releases/download/__TAG__

# 1. Download artifacts
curl -fsSLO "$BASE/op-who-dev-macos-${ARCH}.tar.gz"
curl -fsSLO "$BASE/SHA256SUMS"
curl -fsSLO "$BASE/SHA256SUMS.sig"

# 2. Verify signature against github.com/stigsb.keys
TMP=$(mktemp -d)
curl -sf https://github.com/stigsb.keys \
  | awk -v who="stig@stigbakken.com" '{print who, "namespaces=\"file\"", $0}' \
  > "$TMP/allowed_signers"
ssh-keygen -Y verify -f "$TMP/allowed_signers" -I stig@stigbakken.com -n file \
  -s SHA256SUMS.sig < SHA256SUMS

# 3. Verify the tarball matches the signed checksum
shasum -a 256 -c SHA256SUMS

# 4. Extract and install
tar xzf "op-who-dev-macos-${ARCH}.tar.gz"
cd "op-who-dev-macos-${ARCH}"
./install.sh
```

After install, grant Accessibility once: System Settings → Privacy & Security → Accessibility → enable "op-who".
