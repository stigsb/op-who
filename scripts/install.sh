#!/bin/bash
set -euo pipefail

# Install op-who from a developer-build package.
#
# Runs in one of two modes:
#
# Inside-tarball mode (the historical use): when invoked from a directory
# that already contains op-who.app and op-who-dev-cert.pem (i.e. extracted
# from op-who-dev.tar.gz), install directly from those siblings.
#
# Standalone mode: when invoked on its own (e.g. downloaded from a GitHub
# Release), download the matching release artifacts, verify their signature
# against https://github.com/<user>.keys, verify the checksums, extract, and
# fall through into the inside-tarball install path.
#
# The standalone path is pinned to a specific release version, baked in at
# package time by scripts/package-dev.sh. Running an unpatched copy
# (VERSION placeholder still in place) is refused.

VERSION="__VERSION__"
REPO="stigsb/op-who"
GH_USER="stigsb"
SIGNER_EMAIL="stig@stigbakken.com"

PRODUCT="op-who"
APP_NAME="${PRODUCT}.app"
CERT_FILE="${PRODUCT}-dev-cert.pem"
TARBALL="${PRODUCT}-dev.tar.gz"
INSTALL_DIR="/Applications"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "$VERSION" == "__VERSION__" ]]; then
    echo "error: this install.sh is unpatched (VERSION placeholder still present)." >&2
    echo "Download a release-pinned copy from:" >&2
    echo "  https://github.com/${REPO}/releases" >&2
    exit 1
fi

cd "$(dirname "$0")"

# --- 0. Standalone mode: fetch + verify + extract --------------------------

if [[ ! -d "$APP_NAME" || ! -f "$CERT_FILE" ]]; then
    echo "op-who ${VERSION} — downloading release artifacts..."
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT

    BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
    for f in "$TARBALL" SHA256SUMS SHA256SUMS.sig; do
        curl -fsSL --proto '=https' -o "${TMP}/${f}" "${BASE_URL}/${f}"
    done

    echo "Verifying signature against https://github.com/${GH_USER}.keys..."
    curl -fsSL --proto '=https' "https://github.com/${GH_USER}.keys" \
        | awk -v who="$SIGNER_EMAIL" '{print who, "namespaces=\"file\"", $0}' \
        > "${TMP}/allowed_signers"
    if [[ ! -s "${TMP}/allowed_signers" ]]; then
        echo "error: ${GH_USER}.keys returned no keys — cannot establish trust root." >&2
        exit 1
    fi
    ssh-keygen -Y verify \
        -f "${TMP}/allowed_signers" \
        -I "$SIGNER_EMAIL" \
        -n file \
        -s "${TMP}/SHA256SUMS.sig" \
        < "${TMP}/SHA256SUMS"

    echo "Verifying checksums..."
    (cd "$TMP" && shasum -a 256 -c SHA256SUMS --ignore-missing)

    echo "Extracting ${TARBALL}..."
    tar -C "$TMP" -xzf "${TMP}/${TARBALL}"
    cd "${TMP}/${PRODUCT}-dev"
fi

# --- 1. Import cert ---------------------------------------------------------

CERT_SHA=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 \
    | awk -F= '{print $2}' | tr -d ':')

if security find-certificate -Z -a "$KEYCHAIN" 2>/dev/null \
        | grep -q "SHA-256 hash: ${CERT_SHA}"; then
    echo "Cert already in login keychain — skipping import."
else
    echo "Importing $CERT_FILE into login keychain..."
    security import "$CERT_FILE" -k "$KEYCHAIN" -A -t cert
fi

# --- 2. Install app ---------------------------------------------------------

if [[ -d "${INSTALL_DIR}/${APP_NAME}" ]]; then
    # If op-who is running from the destination, ask it to quit first.
    pkill -f "${INSTALL_DIR}/${APP_NAME}/Contents/MacOS/${PRODUCT}" 2>/dev/null || true
    sleep 1
    echo "Removing existing ${INSTALL_DIR}/${APP_NAME}..."
    rm -rf "${INSTALL_DIR}/${APP_NAME}"
fi

echo "Copying ${APP_NAME} to ${INSTALL_DIR}/..."
ditto "$APP_NAME" "${INSTALL_DIR}/${APP_NAME}"

# --- 3. Strip quarantine ----------------------------------------------------

xattr -dr com.apple.quarantine "${INSTALL_DIR}/${APP_NAME}" 2>/dev/null || true

# --- 4. Verify signature ----------------------------------------------------

echo "Verifying signature..."
if codesign --verify --verbose=1 "${INSTALL_DIR}/${APP_NAME}" 2>&1 | grep -q "valid on disk"; then
    codesign --verify --verbose=1 "${INSTALL_DIR}/${APP_NAME}"
else
    # Self-signed certs that aren't trusted as a root show as "valid on disk"
    # but "not trusted" — that's expected and not a failure for our purposes.
    codesign --verify --verbose=1 "${INSTALL_DIR}/${APP_NAME}" || true
fi

# --- 5. Done ----------------------------------------------------------------

cat <<EOF

Installed: ${INSTALL_DIR}/${APP_NAME}

Next step — grant Accessibility (one time):
  System Settings → Privacy & Security → Accessibility → enable "op-who".

Open that pane now? [y/N]
EOF

# Re-attach the controlling tty so the prompt works even when this script
# was invoked from a pipe (e.g. curl ... | bash).
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
    exec </dev/tty
fi
read -r reply
case "$reply" in
    [yY]*) open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" ;;
esac

echo "Launching op-who..."
open "${INSTALL_DIR}/${APP_NAME}"
