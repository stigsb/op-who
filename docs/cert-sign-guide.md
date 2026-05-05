# Developer Certificate and Code Signing Guide

This guide walks through obtaining an Apple Developer ID certificate as an
Apple Business Manager user and configuring it for signing op-who releases,
both locally and in GitHub Actions.

## Prerequisites

- An [Apple Developer Program](https://developer.apple.com/programs/)
  membership ($99/year). Organization/company memberships work; individual
  memberships also work if you are the sole developer.
- A Mac with Xcode (or Xcode Command Line Tools) installed.
- Admin or Developer role in your Apple Developer team. If your organization
  uses Apple Business Manager (ABM), your ABM admin must grant you access to
  the developer portal or assign you the Developer role.

## Part 1: Obtain a Developer ID Application Certificate

### 1.1 Create a Certificate Signing Request (CSR)

1. Open **Keychain Access** on your Mac.
2. From the menu bar: **Keychain Access > Certificate Assistant > Request a
   Certificate from a Certificate Authority...**
3. Fill in:
   - **User Email Address**: your Apple ID email
   - **Common Name**: your name or organization name
   - **Request is**: Saved to disk
4. Click **Continue** and save the `.certSigningRequest` file.

This creates a private key in your login keychain and a CSR file on disk.

### 1.2 Create the Certificate in the Developer Portal

1. Go to [Certificates, Identifiers &
   Profiles](https://developer.apple.com/account/resources/certificates/list).
2. Click the **+** button to create a new certificate.
3. Under **Software**, select **Developer ID Application**. This is the
   certificate type used to sign software distributed outside the Mac App
   Store.
4. Click **Continue**.
5. Upload the `.certSigningRequest` file you saved in step 1.1.
6. Click **Continue**, then **Download** the `.cer` file.

### 1.3 Install the Certificate

1. Double-click the downloaded `.cer` file. Keychain Access opens and installs
   it into your login keychain.
2. Verify it appears under **My Certificates** in Keychain Access as
   `Developer ID Application: Your Name (TEAMID)`.
3. Verify from the terminal:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see output like:

```
1) ABCDEF1234... "Developer ID Application: Your Org (ABCDE12345)"
```

### 1.4 Apple Business Manager Notes

If your organization uses Apple Business Manager:

- Your ABM admin must ensure your Managed Apple ID has access to the Apple
  Developer portal. This is typically done by assigning the **Developer** or
  **Admin** role in [App Store Connect](https://appstoreconnect.apple.com)
  under Users and Access.
- Only **Account Holder** and **Admin** roles can create Developer ID
  certificates. If you have a Developer role, ask an Admin to create the
  certificate and export it for you (see section 2.2).
- Managed Apple IDs can sign in to the developer portal at
  `developer.apple.com` the same way as personal Apple IDs.
- Each team can have a limited number of Developer ID Application certificates
  (typically 5). Coordinate with your team to avoid hitting the limit.

## Part 2: Export the Certificate for CI

GitHub Actions runners do not have access to your local keychain. You need to
export the signing certificate and private key as a `.p12` file, then import
it on the runner.

### 2.1 Export as .p12

1. Open **Keychain Access**.
2. Under **My Certificates**, find your `Developer ID Application` certificate.
3. Right-click it and choose **Export...**
4. Choose **Personal Information Exchange (.p12)** format.
5. Set a strong password when prompted. You will need this password in CI.
6. Save the file (e.g., `developer-id.p12`).

### 2.2 Store in GitHub Secrets

In your repository's **Settings > Secrets and variables > Actions**, create
these secrets:

| Secret Name                     | Value                                                     |
| ------------------------------- | --------------------------------------------------------- |
| `DEVELOPER_ID_CERT_BASE64`     | Base64-encoded `.p12` file (see below)                    |
| `DEVELOPER_ID_CERT_PASSWORD`   | The password you set when exporting                       |
| `NOTARYTOOL_APPLE_ID`          | Your Apple ID email                                       |
| `NOTARYTOOL_PASSWORD`          | An app-specific password (see section 2.3)                |
| `NOTARYTOOL_TEAM_ID`           | Your 10-character Apple Team ID                           |

To base64-encode the `.p12` file:

```bash
base64 -i developer-id.p12 | pbcopy
```

Paste the clipboard contents into the `DEVELOPER_ID_CERT_BASE64` secret.

After creating the secrets, **securely delete** the `.p12` file from disk:

```bash
rm -P developer-id.p12
```

### 2.3 Create an App-Specific Password

Notarization requires authenticating with Apple. For CI, use an app-specific
password:

1. Go to [appleid.apple.com](https://appleid.apple.com) > **Sign-In and
   Security** > **App-Specific Passwords**.
2. Click **Generate an app-specific password**.
3. Name it something like `op-who-notarization`.
4. Copy the generated password and store it as the `NOTARYTOOL_PASSWORD`
   GitHub secret.

Note: If your organization uses Managed Apple IDs, app-specific passwords may
be disabled. In that case, use an **App Store Connect API Key** instead (see
section 2.4).

### 2.4 Alternative: App Store Connect API Key

If app-specific passwords are not available (common with Managed Apple IDs):

1. Go to [App Store Connect > Users and Access > Integrations > Team
   Keys](https://appstoreconnect.apple.com/access/integrations/api).
2. Click **Generate API Key**.
3. Name it (e.g., `op-who-ci`) and grant it **Developer** access.
4. Download the `.p8` key file. You can only download it once.
5. Note the **Key ID** and **Issuer ID** shown on the page.

Store these as GitHub secrets:

| Secret Name              | Value                                        |
| ------------------------ | -------------------------------------------- |
| `NOTARY_API_KEY`         | Contents of the `.p8` file                   |
| `NOTARY_API_KEY_ID`      | The Key ID from App Store Connect            |
| `NOTARY_API_ISSUER_ID`   | The Issuer ID from App Store Connect         |

The GitHub Actions workflow in Part 3 shows how to use both authentication
methods.

## Part 3: GitHub Actions Workflow

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

jobs:
  build-sign-notarize:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Import signing certificate
        env:
          CERT_BASE64: ${{ secrets.DEVELOPER_ID_CERT_BASE64 }}
          CERT_PASSWORD: ${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}
        run: |
          CERT_PATH="$RUNNER_TEMP/certificate.p12"
          KEYCHAIN_PATH="$RUNNER_TEMP/signing.keychain-db"
          KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"

          # Decode certificate
          echo "$CERT_BASE64" | base64 --decode > "$CERT_PATH"

          # Create a temporary keychain
          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

          # Import certificate into keychain
          security import "$CERT_PATH" \
            -P "$CERT_PASSWORD" \
            -A \
            -t cert \
            -f pkcs12 \
            -k "$KEYCHAIN_PATH"

          # Allow codesign to access the keychain
          security set-key-partition-list \
            -S apple-tool:,apple: \
            -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

          # Add temporary keychain to search list
          security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db

      - name: Build release
        run: swift build -c release

      - name: Sign with hardened runtime
        run: |
          IDENTITY=$(security find-identity -v -p codesigning \
            | grep "Developer ID Application" \
            | head -1 \
            | sed 's/.*"\(.*\)".*/\1/')

          codesign --force --options runtime \
            --entitlements release.entitlements \
            --sign "$IDENTITY" \
            .build/release/op-who

          codesign --verify --verbose=2 .build/release/op-who

      - name: Package
        run: |
          mkdir -p .build/release-stage
          cp .build/release/op-who .build/release-stage/
          ditto -c -k --keepParent .build/release-stage/op-who .build/op-who.zip

      - name: Notarize
        env:
          # Option A: App-specific password
          NOTARYTOOL_APPLE_ID: ${{ secrets.NOTARYTOOL_APPLE_ID }}
          NOTARYTOOL_PASSWORD: ${{ secrets.NOTARYTOOL_PASSWORD }}
          NOTARYTOOL_TEAM_ID: ${{ secrets.NOTARYTOOL_TEAM_ID }}
          # Option B: API key (uncomment and remove Option A if using API key)
          # NOTARY_API_KEY: ${{ secrets.NOTARY_API_KEY }}
          # NOTARY_API_KEY_ID: ${{ secrets.NOTARY_API_KEY_ID }}
          # NOTARY_API_ISSUER_ID: ${{ secrets.NOTARY_API_ISSUER_ID }}
        run: |
          # Option A: App-specific password
          xcrun notarytool submit .build/op-who.zip \
            --apple-id "$NOTARYTOOL_APPLE_ID" \
            --password "$NOTARYTOOL_PASSWORD" \
            --team-id "$NOTARYTOOL_TEAM_ID" \
            --wait

          # Option B: API key (uncomment and remove Option A if using API key)
          # API_KEY_PATH="$RUNNER_TEMP/api-key.p8"
          # echo "$NOTARY_API_KEY" > "$API_KEY_PATH"
          # xcrun notarytool submit .build/op-who.zip \
          #   --key "$API_KEY_PATH" \
          #   --key-id "$NOTARY_API_KEY_ID" \
          #   --issuer "$NOTARY_API_ISSUER_ID" \
          #   --wait

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          TAG="${GITHUB_REF#refs/tags/}"
          gh release create "$TAG" \
            --title "$TAG" \
            --generate-notes \
            .build/op-who.zip#op-who-macos.zip

      - name: Cleanup keychain
        if: always()
        run: |
          KEYCHAIN_PATH="$RUNNER_TEMP/signing.keychain-db"
          if [ -f "$KEYCHAIN_PATH" ]; then
            security delete-keychain "$KEYCHAIN_PATH"
          fi
```

## Part 4: Local Setup for `scripts/release.sh`

If you prefer to sign and notarize locally (instead of or in addition to CI):

### 4.1 Store Notarization Credentials

Run once to store credentials in your keychain:

```bash
# Option A: App-specific password
xcrun notarytool store-credentials "op-who" \
  --apple-id "your@email.com" \
  --team-id "ABCDE12345" \
  --password "your-app-specific-password"

# Option B: API key
xcrun notarytool store-credentials "op-who" \
  --key /path/to/AuthKey_XXXXX.p8 \
  --key-id "XXXXX" \
  --issuer "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### 4.2 Run the Release Script

```bash
# Auto-detect signing identity from keychain
scripts/release.sh

# Or specify explicitly
scripts/release.sh "Developer ID Application: Your Org (ABCDE12345)"
```

The script produces `.build/op-who.zip`, signed and notarized, ready for
distribution.

## Part 5: Verification

After building a signed release (locally or in CI), verify it:

```bash
# Check the code signature
codesign --verify --verbose=2 .build/release/op-who

# Check that hardened runtime is enabled
codesign -d --verbose=2 .build/release/op-who 2>&1 | grep flags
# Should include: flags=0x10000(runtime)

# Check there are no debug entitlements
codesign -d --entitlements - .build/release/op-who
# Should show empty or no entitlements (no com.apple.security.get-task-allow)

# Verify notarization status (requires internet)
spctl --assess --type execute --verbose=2 .build/release/op-who
# Should print: accepted / source=Notarized Developer ID

# Check notarization log (useful for debugging rejections)
xcrun notarytool log <submission-id> --keychain-profile "op-who"
```

## Troubleshooting

### "No Developer ID Application certificate found"

- Verify the certificate is installed: `security find-identity -v -p codesigning`
- Ensure you downloaded a **Developer ID Application** certificate, not an iOS
  or Mac App Store distribution certificate.

### Notarization rejected

Common causes:
- **Missing hardened runtime**: the `--options runtime` flag must be passed to
  `codesign`. The release script handles this.
- **Forbidden entitlements**: `com.apple.security.get-task-allow` is not
  allowed for notarized software. The `release.entitlements` file is empty
  to avoid this.
- **Unsigned nested code**: if you bundle frameworks or dylibs, each must be
  individually signed before the outer binary.

Run `xcrun notarytool log <submission-id> --keychain-profile "op-who"` to see
the detailed rejection reasons.

### "Developer ID Application" certificate not available in portal

- Only **Account Holder** and **Admin** roles can create this certificate type.
- Your organization may have hit the certificate limit (5 per type). Check
  existing certificates and revoke unused ones.

### Managed Apple ID restrictions

- App-specific passwords may be disabled for Managed Apple IDs. Use an App
  Store Connect API Key instead (section 2.4).
- If you cannot access the developer portal, ask your ABM admin to assign the
  appropriate role in App Store Connect.
