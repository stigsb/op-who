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

# Stage the installer that the recipient runs.
cp scripts/install.sh "$DIST_DIR/install.sh"
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

echo ""
echo "Packaged: $TARBALL"
echo "Staged:   $DIST_DIR/"
echo "Cert fingerprint (SHA-256): $CERT_FINGERPRINT"
