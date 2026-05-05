#!/bin/bash
set -euo pipefail

# Assemble op-who.app from SPM build output.
#
# Usage:
#   scripts/bundle.sh              # debug build
#   scripts/bundle.sh release      # release build
#
# Signing identity:
#   By default the script looks for a self-signed code-signing certificate
#   named "op-who Local Dev" in the login keychain and signs with it. That
#   gives the bundle a stable signing anchor — TCC keeps the Accessibility
#   grant across rebuilds (binary cdhash changes, but the cert leaf doesn't).
#
#   If the cert is not found, the script falls back to ad-hoc signing. That
#   still produces a valid bundle, but on modern macOS (Sonoma+) TCC will
#   silently invalidate the grant whenever the binary's cdhash changes, so
#   you'll have to `tccutil reset Accessibility com.stigbakken.op-who`
#   and re-grant after every clean rebuild.
#
#   Override the cert name via OP_WHO_SIGN_IDENTITY=... if you've named yours
#   differently. See README.md for one-time setup instructions.

CONFIG="${1:-debug}"
PRODUCT="op-who"
APP_NAME="${PRODUCT}.app"
SIGN_IDENTITY="${OP_WHO_SIGN_IDENTITY:-op-who Local Dev}"

cd "$(dirname "$0")/.."

# Build
echo "Building ($CONFIG)..."
swift build -c "$CONFIG"

BUILD_DIR=".build/${CONFIG}"
APP_DIR=".build/${APP_NAME}"

# Assemble .app bundle
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$BUILD_DIR/$PRODUCT" "$APP_DIR/Contents/MacOS/"
cp Sources/OpWhoLib/Info.plist "$APP_DIR/Contents/"

# Re-sign so the signature's identifier matches CFBundleIdentifier (not the
# per-build hash `swift build` assigns) and Info.plist is bound to the
# signature. Prefer the configured dev cert if present; fall back to ad-hoc.
# Drop -v: a self-signed dev cert that isn't a trusted root will show up
# as CSSMERR_TP_NOT_TRUSTED in `find-identity -v`, but `codesign` itself
# can still use it — and TCC matches on the cert leaf, not on root trust.
if security find-identity -p codesigning 2>/dev/null | grep -F -q "\"$SIGN_IDENTITY\""; then
    echo "Signing with '$SIGN_IDENTITY' (TCC grants persist across rebuilds)"
    codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "Signing ad-hoc — '$SIGN_IDENTITY' not found in login keychain."
    echo "  Heads-up: TCC Accessibility grants will NOT survive rebuilds."
    echo "  See README.md → Permissions for one-time self-signed cert setup."
    codesign --force --sign - "$APP_DIR"
fi

echo "Bundle assembled: $APP_DIR"
