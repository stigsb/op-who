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
#   you'll have to `tccutil reset Accessibility com.stigbakken.op-who.dev`
#   and re-grant after every clean rebuild.
#
#   Override the cert name via OP_WHO_SIGN_IDENTITY=... if you've named yours
#   differently. See README.md for one-time setup instructions.
#
# Identity:
#   Debug bundles are `op-who-dev.app` with bundle ID com.stigbakken.op-who.dev
#   and name "op-who Dev", so they get their own TCC grants, preferences and
#   System Settings entries, separate from an installed (MDM-managed) release.
#   Release bundles keep op-who.app / com.stigbakken.op-who.

CONFIG="${1:-debug}"
PRODUCT="op-who"
if [[ "$CONFIG" == "release" ]]; then
    APP_NAME="${PRODUCT}.app"
else
    APP_NAME="${PRODUCT}-dev.app"
    BUNDLE_ID="com.stigbakken.op-who.dev"
    DISPLAY_NAME="op-who Dev"
fi
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
# Dev identity goes in before signing, like everything else in Info.plist.
if [[ "$CONFIG" != "release" ]]; then
    PLIST="$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME" "$PLIST"
fi

# SPM resource bundle (the popup alert sound). `Bundle.module` finds it via
# Bundle.main's resource directory, so it must land in Contents/Resources —
# and, like Info.plist, before signing, or the signature won't cover it.
RESOURCE_BUNDLE="OpWho_OpWhoLib.bundle"
if [[ -d "$BUILD_DIR/$RESOURCE_BUNDLE" ]]; then
    mkdir -p "$APP_DIR/Contents/Resources"
    cp -R "$BUILD_DIR/$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
else
    echo "Warning: $RESOURCE_BUNDLE not found in $BUILD_DIR — popup sound will be silent." >&2
fi

# Version stamping (must happen before signing so the signature binds the
# final Info.plist). On an exact vX.X.X release tag, keep the Info.plist
# version. On any other commit — a local dev build — overwrite
# CFBundleShortVersionString with `git describe --tags` (e.g.
# v0.12.2-8-g1cd02e5) so "About op-who" identifies the exact build instead of
# showing the last release's number. Outside a git repo, the plist value stands.
if EXACT_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null) \
   && [[ "$EXACT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    : # exact release tag — Info.plist already carries the right version
elif DESCRIBE=$(git describe --tags --always --dirty 2>/dev/null) && [[ -n "$DESCRIBE" ]]; then
    echo "Dev build — stamping version $DESCRIBE"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DESCRIBE" "$APP_DIR/Contents/Info.plist"
fi

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
