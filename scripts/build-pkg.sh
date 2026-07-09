#!/bin/bash
set -euo pipefail

# Build a signed (and, if credentials exist, notarized) installer .pkg for
# op-who, suitable for MDM/Fleet software distribution.
#
# Unlike the .zip/.dmg (drag-install) path, the .pkg installs op-who
# non-interactively — Fleet runs it with `installer -pkg`. It lays down:
#   /Applications/op-who.app
#   /Library/LaunchAgents/com.stigbakken.op-who.plist   (auto-start at login)
# and a postinstall script that boots the agent for the current user so a
# silent push takes effect without a logout.
#
# Prerequisites:
#   - .build/op-who.app already built and signed with a "Developer ID
#     Application" identity + hardened runtime (scripts/release.sh does this).
#   - A "Developer ID Installer" certificate in the keychain.
#   - Optional: a notarytool credential profile (default name "op-who") for
#     notarization. Without it the pkg is signed but not notarized.
#
# Usage:
#   scripts/build-pkg.sh                                  # auto-detect identity
#   scripts/build-pkg.sh "Developer ID Installer: Name (TEAMID)"
#   OP_WHO_NOTARY_PROFILE=op-who scripts/build-pkg.sh     # override profile
#   scripts/build-pkg.sh --no-notarize                    # sign only

cd "$(dirname "$0")/.."

PRODUCT="op-who"
APP_NAME="${PRODUCT}.app"
APP_DIR=".build/${APP_NAME}"
BUNDLE_ID="com.stigbakken.op-who"
LAUNCH_AGENT="packaging/launchd/${BUNDLE_ID}.plist"
PKG_SCRIPTS="packaging/scripts"
NOTARY_PROFILE="${OP_WHO_NOTARY_PROFILE:-op-who}"

IDENTITY=""
NOTARIZE=true
for arg in "$@"; do
    case "$arg" in
        --no-notarize) NOTARIZE=false ;;
        *) IDENTITY="$arg" ;;
    esac
done

# --- Preconditions -----------------------------------------------------------

if [[ ! -d "$APP_DIR" ]]; then
    echo "error: $APP_DIR not found. Build & sign the app first (scripts/release.sh)." >&2
    exit 1
fi

# Refuse to package an unsigned / ad-hoc app — an unsigned app inside a signed
# pkg fails notarization and Gatekeeper anyway. Capture first, then grep: piping
# straight into `grep -q` makes grep close the pipe on first match, codesign
# dies with SIGPIPE, and `set -o pipefail` would flip the test to a false error.
APP_SIG=$(codesign -dvv "$APP_DIR" 2>&1 || true)
if ! grep -q "Authority=Developer ID Application" <<<"$APP_SIG"; then
    echo "error: $APP_DIR is not signed with a Developer ID Application identity." >&2
    echo "       Run scripts/release.sh (or codesign it) before packaging." >&2
    exit 1
fi

# --- Find Developer ID Installer identity ------------------------------------

if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -v \
        | grep "Developer ID Installer" \
        | head -1 \
        | sed 's/.*"\(.*\)".*/\1/')
    if [[ -z "$IDENTITY" ]]; then
        echo "error: No Developer ID Installer certificate found in keychain." >&2
        echo "Create one at https://developer.apple.com/account/resources/certificates" >&2
        exit 1
    fi
fi
echo "Installer identity: $IDENTITY"

# --- Version (read from the built app's Info.plist) --------------------------

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP_DIR/Contents/Info.plist")
echo "Version: $VERSION"

PKG_PATH=".build/${PRODUCT}-${VERSION}.pkg"

# --- Stage payload -----------------------------------------------------------

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$STAGING/Applications" "$STAGING/Library/LaunchAgents"
cp -R "$APP_DIR" "$STAGING/Applications/"
cp "$LAUNCH_AGENT" "$STAGING/Library/LaunchAgents/${BUNDLE_ID}.plist"

chmod +x "$PKG_SCRIPTS/postinstall"

# --- Build the component pkg (signed) ----------------------------------------
# --ownership recommended: installed files land as root:wheel, not the
# staging user. --sign embeds the Developer ID Installer signature.

echo "Building signed pkg -> $PKG_PATH"
rm -f "$PKG_PATH"
pkgbuild \
    --root "$STAGING" \
    --scripts "$PKG_SCRIPTS" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    --ownership recommended \
    --sign "$IDENTITY" \
    "$PKG_PATH"

echo "Verifying pkg signature..."
pkgutil --check-signature "$PKG_PATH"

# --- Notarize + staple (best effort) -----------------------------------------

if [[ "$NOTARIZE" == true ]]; then
    # Notary auth: prefer explicit Apple-ID creds from the environment (CI),
    # otherwise fall back to the stored keychain profile (local dev).
    if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
        notary_auth=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
        echo "Notarizing (Apple-ID creds from environment)..."
    else
        notary_auth=(--keychain-profile "$NOTARY_PROFILE")
        echo "Notarizing (keychain profile: $NOTARY_PROFILE)..."
    fi
    if xcrun notarytool submit "$PKG_PATH" "${notary_auth[@]}" --wait; then
        xcrun stapler staple "$PKG_PATH"
        echo "Notarized + stapled."
    else
        echo "" >&2
        echo "warning: notarization skipped/failed — pkg is SIGNED but NOT notarized." >&2
        echo "  Set up credentials once with:" >&2
        echo "    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
        echo "      --apple-id <appleid> --team-id HZ76GWS9YM --password <app-specific-pw>" >&2
        echo "  then re-run. (Fleet-pushed installs work unnotarized; direct downloads won't.)" >&2
    fi
else
    echo "Notarization disabled (--no-notarize). Pkg is signed only."
fi

echo ""
echo "Installer package: $PKG_PATH"
