#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and package op-who for distribution.
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
BUILD_DIR=".build/release"
STAGE_DIR=".build/release-stage"
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

# --- Build --------------------------------------------------------------------

echo "Building release..."
swift build -c release

# --- Sign with hardened runtime -----------------------------------------------

echo "Signing with hardened runtime..."
codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$BUILD_DIR/$PRODUCT"

echo "Verifying signature..."
codesign --verify --verbose=2 "$BUILD_DIR/$PRODUCT"

# --- Package for notarization ------------------------------------------------

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp "$BUILD_DIR/$PRODUCT" "$STAGE_DIR/"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$STAGE_DIR/$PRODUCT" "$ZIP_PATH"

# --- Notarize -----------------------------------------------------------------

echo "Submitting for notarization..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$PRODUCT" \
    --wait

echo "Stapling..."
# Staple works on app bundles and disk images but not bare Mach-O executables.
# For a standalone binary, notarization is verified online by Gatekeeper on
# first launch. We skip staple here; distribute the signed zip.
echo "(Stapling skipped — standalone executables rely on online notarization check)"

# --- Done ---------------------------------------------------------------------

echo ""
echo "Release artifact: $ZIP_PATH"
echo "Distribute this zip. Gatekeeper will verify notarization on first launch."
