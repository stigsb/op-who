#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and package op-who.app for distribution.
#
# Prerequisites:
#   - A "Developer ID Application" certificate in your keychain
#   - An App Store Connect API key or app-specific password for notarytool
#     (configure via: xcrun notarytool store-credentials "op-who")
#
# Usage:
#   scripts/release.sh                        # auto-detect signing identity
#   scripts/release.sh "Developer ID Application: Your Name (TEAMID)"

IDENTITY="${1:-}"
ENTITLEMENTS="release.entitlements"
PRODUCT="op-who"
APP_NAME="${PRODUCT}.app"
APP_DIR=".build/${APP_NAME}"
ZIP_PATH=".build/${PRODUCT}.zip"

cd "$(dirname "$0")/.."

# --- Find signing identity ---------------------------------------------------

if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" \
        | head -1 \
        | sed 's/.*"\(.*\)".*/\1/')
    if [[ -z "$IDENTITY" ]]; then
        echo "error: No Developer ID Application certificate found in keychain." >&2
        echo "Install one from https://developer.apple.com/account/resources/certificates" >&2
        exit 1
    fi
    echo "Using identity: $IDENTITY"
fi

# --- Build & assemble .app ---------------------------------------------------

scripts/bundle.sh release

# --- Sign with hardened runtime -----------------------------------------------

echo "Signing with hardened runtime..."
codesign --deep --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP_DIR"

echo "Verifying signature..."
codesign --verify --deep --verbose=2 "$APP_DIR"

# --- Package for notarization ------------------------------------------------

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

# --- Notarize -----------------------------------------------------------------

echo "Submitting for notarization..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$PRODUCT" \
    --wait

echo "Stapling..."
xcrun stapler staple "$APP_DIR"

# Re-zip with stapled ticket
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

# --- Build Fleet installer pkg -----------------------------------------------
# The .zip above is the drag-install / Homebrew-cask artifact. The .pkg is for
# MDM/Fleet software distribution (installs the app + a login LaunchAgent
# non-interactively). It reuses the now-notarized+stapled app and notarizes the
# pkg itself under the same "op-who" keychain profile.

echo "Building Fleet installer pkg..."
PKG_PATH=$(scripts/build-pkg.sh | tail -1 | sed 's/^Installer package: //')

# --- Done ---------------------------------------------------------------------

echo ""
echo "Release artifacts:"
echo "  zip (drag-install / Homebrew cask): $ZIP_PATH"
echo "  pkg (MDM / Fleet):                  ${PKG_PATH}"
echo "Install with: cp -R .build/${APP_NAME} /Applications/"
