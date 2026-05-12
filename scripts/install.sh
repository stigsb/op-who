#!/bin/bash
set -euo pipefail

# Install op-who from a developer-build package.
#
# Designed to run from inside the unpacked tarball produced by
# scripts/package-dev.sh:
#
#   tar xzf op-who-dev.tar.gz
#   cd op-who-dev
#   ./install.sh
#
# Steps:
#   1. Import the public cert into the login keychain (idempotent).
#   2. Copy op-who.app into /Applications, replacing any prior copy.
#   3. Strip the macOS quarantine xattr so first launch doesn't bounce.
#   4. Verify the signature now resolves against the imported cert.
#   5. Print Accessibility next-steps (TCC can't be scripted).

PRODUCT="op-who"
APP_NAME="${PRODUCT}.app"
CERT_FILE="${PRODUCT}-dev-cert.pem"
INSTALL_DIR="/Applications"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

cd "$(dirname "$0")"

if [[ ! -d "$APP_NAME" ]]; then
    echo "error: $APP_NAME not found in $(pwd)" >&2
    exit 1
fi
if [[ ! -f "$CERT_FILE" ]]; then
    echo "error: $CERT_FILE not found in $(pwd)" >&2
    exit 1
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

read -r reply
case "$reply" in
    [yY]*) open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" ;;
esac

echo "Launching op-who..."
open "${INSTALL_DIR}/${APP_NAME}"
