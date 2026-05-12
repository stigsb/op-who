#!/bin/bash
set -euo pipefail

# Package a self-signed op-who.app for distribution to other Macs.
#
# Until we have an Apple Developer ID cert, this packages the bundle along
# with the public half of the local dev cert so a recipient can run install.sh
# and get a TCC-stable install (Accessibility grant survives rebuilds).
#
# Output: dist/op-who-dev.tar.gz containing
#   - op-who.app (release build, signed with the local dev cert)
#   - op-who-dev-cert.pem (public certificate only, no private key)
#   - install.sh
#   - README.txt
#
# Usage:
#   scripts/package-dev.sh

SIGN_IDENTITY="${OP_WHO_SIGN_IDENTITY:-op-who Local Dev}"
PRODUCT="op-who"
APP_NAME="${PRODUCT}.app"

cd "$(dirname "$0")/.."

if ! security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "error: certificate '$SIGN_IDENTITY' not found in login keychain." >&2
    echo "Set OP_WHO_SIGN_IDENTITY or create the cert per README.md." >&2
    exit 1
fi

# Build & sign the release bundle via the normal flow.
scripts/bundle.sh release

APP_DIR=".build/${APP_NAME}"
DIST_DIR="dist/${PRODUCT}-dev"
TARBALL="dist/${PRODUCT}-dev.tar.gz"

rm -rf "$DIST_DIR" "$TARBALL"
mkdir -p "$DIST_DIR"

# Copy the app.
ditto "$APP_DIR" "$DIST_DIR/${APP_NAME}"

# Export the public certificate as PEM (no private key).
security find-certificate -c "$SIGN_IDENTITY" -p > "$DIST_DIR/${PRODUCT}-dev-cert.pem"

# Stage the installer that the recipient runs. Pin the VERSION placeholder
# to the value currently in Info.plist so the script's standalone-download
# mode targets the matching release. The same patched copy goes into both
# the tarball and (later) dist/install.sh.
#
# The pattern is anchored to the full assignment line so the unpatched-copy
# sentinel (a second `__VERSION__` literal inside the equality check) stays
# put. Patching both would make the check tautological.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/OpWhoLib/Info.plist)
sed "s/^VERSION=\"__VERSION__\"\$/VERSION=\"v${VERSION}\"/" scripts/install.sh > "$DIST_DIR/install.sh"
if ! grep -q "^VERSION=\"v${VERSION}\"\$" "$DIST_DIR/install.sh"; then
    echo "error: failed to patch VERSION in install.sh" >&2
    exit 1
fi
chmod +x "$DIST_DIR/install.sh"

# Include a short README so recipients aren't guessing.
CERT_FINGERPRINT=$(security find-certificate -c "$SIGN_IDENTITY" -Z 2>/dev/null \
    | awk '/SHA-256 hash:/ {print $3}')
cat > "$DIST_DIR/README.txt" <<EOF
op-who (developer build)

This is a self-signed build distributed before an Apple Developer ID cert is
available. The certificate is local to the developer's machine, not issued by
Apple — Gatekeeper and notarization do not apply.

To install on a Mac:

  ./install.sh

That will:
  1. Import op-who-dev-cert.pem into your login keychain (no private key).
  2. Copy op-who.app to /Applications.
  3. Remove the quarantine attribute so it can launch.

After install, grant Accessibility once:
  System Settings → Privacy & Security → Accessibility → enable "op-who".

Certificate SHA-256 fingerprint:
  ${CERT_FINGERPRINT}

Verify the cert before running install.sh if the package didn't come from a
trusted channel:
  openssl x509 -in op-who-dev-cert.pem -noout -fingerprint -sha256
EOF

# Final tarball.
tar -C dist -czf "$TARBALL" "${PRODUCT}-dev"

# Also expose install.sh as a top-level artifact so recipients can read
# (and trust-verify) the installer logic before extracting the tarball.
# The copy is byte-identical to the one inside the tarball.
cp "$DIST_DIR/install.sh" "dist/install.sh"

# Sign every top-level file in dist/. Produces dist/SHA256SUMS and
# dist/SHA256SUMS.sig covering the tarball and install.sh. The signed
# checksum file is the trust anchor end users verify against — see
# SIGNING.md for the recipient flow.
scripts/sign-artifacts.sh dist

echo ""
echo "Packaged:    $TARBALL"
echo "Installer:   dist/install.sh"
echo "Checksums:   dist/SHA256SUMS"
echo "Signature:   dist/SHA256SUMS.sig"
echo "Staged dir:  $DIST_DIR/"
echo "Cert fingerprint (SHA-256): $CERT_FINGERPRINT"
