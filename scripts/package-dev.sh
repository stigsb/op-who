#!/bin/bash
set -euo pipefail

# Package a self-signed op-who.app for distribution to other Macs.
#
# Until we have an Apple Developer ID cert, this packages the bundle along
# with the public half of the local dev cert so a recipient can run install.sh
# and get a TCC-stable install (Accessibility grant survives rebuilds).
#
# The tarball is arch-tagged (uname -m, e.g. arm64, x86_64) so end users can
# tell at a glance whether an artifact matches their machine. macOS is in the
# name explicitly too — the .app format implies it, but explicit > implicit
# on a release page.
#
# Output: dist/op-who-dev-macos-<arch>.tar.gz containing
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
ARCH=$(uname -m)
SLUG="${PRODUCT}-dev-macos-${ARCH}"

cd "$(dirname "$0")/.."

if ! security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "error: certificate '$SIGN_IDENTITY' not found in login keychain." >&2
    echo "Set OP_WHO_SIGN_IDENTITY or create the cert per README.md." >&2
    exit 1
fi

# Build & sign the release bundle via the normal flow.
scripts/bundle.sh release

APP_DIR=".build/${APP_NAME}"
DIST_DIR="dist/${SLUG}"
TARBALL="dist/${SLUG}.tar.gz"

# Clean dist/ so stale artifacts from a previous arch or naming scheme don't
# slip into the next release upload by accident.
rm -rf dist
mkdir -p "$DIST_DIR"

# Copy the app.
ditto "$APP_DIR" "$DIST_DIR/${APP_NAME}"

# Export the public certificate as PEM (no private key).
security find-certificate -c "$SIGN_IDENTITY" -p > "$DIST_DIR/${PRODUCT}-dev-cert.pem"

# Stage the installer that the recipient runs — verbatim from scripts/install.sh.
# No patching: the installer is tarball-relative and doesn't need to know the
# release version.
cp scripts/install.sh "$DIST_DIR/install.sh"
chmod +x "$DIST_DIR/install.sh"

# Include a short README so recipients aren't guessing.
CERT_FINGERPRINT=$(security find-certificate -c "$SIGN_IDENTITY" -Z 2>/dev/null \
    | awk '/SHA-256 hash:/ {print $3}')
cat > "$DIST_DIR/README.txt" <<EOF
op-who (developer build, macOS ${ARCH})

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
tar -C dist -czf "$TARBALL" "${SLUG}"

# Remove the staging directory so dist/ contains only the artifacts that get
# uploaded to the release: the tarball, SHA256SUMS, and SHA256SUMS.sig.
rm -rf "$DIST_DIR"

# Sign every top-level file in dist/. Produces dist/SHA256SUMS and
# dist/SHA256SUMS.sig covering the tarball. The signed checksum file is the
# trust anchor end users verify against — see SIGNING.md for the recipient flow.
scripts/sign-artifacts.sh dist

echo ""
echo "Packaged:    $TARBALL"
echo "Checksums:   dist/SHA256SUMS"
echo "Signature:   dist/SHA256SUMS.sig"
echo "Cert fingerprint (SHA-256): $CERT_FINGERPRINT"
