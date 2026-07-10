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

### 2.2 Store the secrets in the `release` environment

The release workflow reads its secrets from a GitHub Actions **Environment**
named `release`, whose deployment policy only permits the `v*` tag and the
`main` branch — so a pull request (from a fork or an in-repo branch) can never
run a workflow that reads them. Export the **Installer** cert the same way as
the Application cert in Part 1 (it signs the `.pkg`).

| Secret Name                         | Value                                                       |
| ----------------------------------- | ----------------------------------------------------------- |
| `DEVELOPER_ID_CERTIFICATE_P12`      | Base64-encoded Developer ID **Application** `.p12`          |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for that `.p12`                                    |
| `DEVELOPER_ID_INSTALLER_P12`        | Base64-encoded Developer ID **Installer** `.p12`            |
| `DEVELOPER_ID_INSTALLER_PASSWORD`   | Password for that `.p12`                                    |
| `NOTARY_APPLE_ID`                   | Your Apple ID email                                         |
| `NOTARY_PASSWORD`                   | App-specific password (see section 2.3)                     |
| `TAP_GITHUB_TOKEN`                  | Fine-grained PAT, `stigsb/homebrew-tap` only, Contents: R/W |

The Apple **Team ID** (`HZ76GWS9YM`) is *not* a secret — it's embedded in every Developer ID–signed binary and in the public certificate — so it lives as the `env.NOTARY_TEAM_ID` literal in the workflow, not in the environment.

Create the environment and its deployment policy once (needs repo admin):

```bash
gh api --method PUT repos/stigsb/op-who/environments/release --input - <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
gh api --method POST repos/stigsb/op-who/environments/release/deployment-branch-policies -f name='v*' -f type='tag'
gh api --method POST repos/stigsb/op-who/environments/release/deployment-branch-policies -f name='main' -f type='branch'
```

Then store each secret **in the environment** (`--env release`):

```bash
gh secret set DEVELOPER_ID_CERTIFICATE_P12   --env release < <(base64 -i DeveloperIDApplication.p12)
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD --env release
gh secret set DEVELOPER_ID_INSTALLER_P12     --env release < <(base64 -i DeveloperIDInstaller.p12)
gh secret set DEVELOPER_ID_INSTALLER_PASSWORD --env release
gh secret set NOTARY_APPLE_ID  --env release
gh secret set NOTARY_PASSWORD  --env release
gh secret set TAP_GITHUB_TOKEN --env release
```

After storing them, **securely delete** the exported `.p12` files:

```bash
rm -P DeveloperIDApplication.p12 DeveloperIDInstaller.p12
```

### 2.3 Create an App-Specific Password

Notarization requires authenticating with Apple. For CI, use an app-specific
password:

1. Go to [appleid.apple.com](https://appleid.apple.com) > **Sign-In and
   Security** > **App-Specific Passwords**.
2. Click **Generate an app-specific password**.
3. Name it something like `op-who-notarization`.
4. Copy the generated password and store it as the `NOTARY_PASSWORD`
   secret in the `release` environment (`gh secret set NOTARY_PASSWORD --env release`).

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

The release workflow is [`.github/workflows/release-notarized.yml`](../.github/workflows/release-notarized.yml) — the source of truth, so it isn't duplicated here. It runs on every `v*` tag push, reads its secrets from the `release` environment (§2.2), and imports the Application + Installer certs, signs with a hardened runtime, notarizes and staples the `.app`, builds the notarized `.pkg`, publishes the release, and updates the Homebrew cask.

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
