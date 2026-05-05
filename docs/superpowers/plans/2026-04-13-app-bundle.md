# op-who .app Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package op-who as a macOS .app bundle for Homebrew cask distribution, with correct permission prompts.

**Architecture:** SPM builds the binary, a shell script assembles the .app bundle structure, and release.sh signs/notarizes the .app instead of the bare binary.

**Tech Stack:** Swift Package Manager, codesign, notarytool, ditto

---

## File Map

- Create: `Sources/Info.plist` — bundle metadata and permission descriptions
- Create: `scripts/bundle.sh` — assembles .app from SPM build output
- Modify: `scripts/release.sh` — sign/notarize .app bundle instead of bare binary
- Modify: `Sources/main.swift:49` — remove `setActivationPolicy(.accessory)` (handled by LSUIElement)

---

### Task 1: Create Info.plist

**Files:**
- Create: `Sources/Info.plist`

- [ ] **Step 1: Create the Info.plist file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>ai.sunstoneinstitute.op-who</string>
    <key>CFBundleName</key>
    <string>op-who</string>
    <key>CFBundleExecutable</key>
    <string>op-who</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>op-who sends Apple Events to terminal apps to identify and activate the tab that triggered a 1Password approval.</string>
</dict>
</plist>
```

- [ ] **Step 2: Validate the plist**

Run: `plutil -lint Sources/Info.plist`
Expected: `Sources/Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add Sources/Info.plist
git commit -m "Add Info.plist for .app bundle"
```

---

### Task 2: Create bundle.sh

**Files:**
- Create: `scripts/bundle.sh`

- [ ] **Step 1: Create the bundle assembly script**

```bash
#!/bin/bash
set -euo pipefail

# Assemble op-who.app from SPM build output.
#
# Usage:
#   scripts/bundle.sh              # debug build
#   scripts/bundle.sh release      # release build

CONFIG="${1:-debug}"
PRODUCT="op-who"
APP_NAME="${PRODUCT}.app"

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
cp Sources/Info.plist "$APP_DIR/Contents/"

echo "Bundle assembled: $APP_DIR"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/bundle.sh`

- [ ] **Step 3: Test the bundle script**

Run: `scripts/bundle.sh`
Expected output:
```
Building (debug)...
...
Bundle assembled: .build/op-who.app
```

Then verify structure:

Run: `ls -R .build/op-who.app/Contents/`
Expected:
```
Info.plist  MacOS

.build/op-who.app/Contents/MacOS:
op-who
```

- [ ] **Step 4: Test the bundled app launches**

Run: `open .build/op-who.app`
Expected: "op?" appears in the menu bar. If Automation permission is needed for a terminal, macOS should prompt (not silently deny).

Quit via the menu bar icon > Quit.

- [ ] **Step 5: Commit**

```bash
git add scripts/bundle.sh
git commit -m "Add bundle.sh to assemble .app from SPM build"
```

---

### Task 3: Remove setActivationPolicy from main.swift

**Files:**
- Modify: `Sources/main.swift:49`

- [ ] **Step 1: Remove the activation policy line**

In `Sources/main.swift`, remove line 49:

```swift
app.setActivationPolicy(.accessory)
```

The final lines of main.swift should be:

```swift
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

`LSUIElement=true` in Info.plist handles this at the system level when running as a .app bundle.

- [ ] **Step 2: Build and verify**

Run: `scripts/bundle.sh`
Expected: builds and assembles successfully.

Run: `open .build/op-who.app`
Expected: "op?" in menu bar, no dock icon.

- [ ] **Step 3: Commit**

```bash
git add Sources/main.swift
git commit -m "Remove setActivationPolicy, handled by LSUIElement in Info.plist"
```

---

### Task 4: Update release.sh for .app bundle

**Files:**
- Modify: `scripts/release.sh`

- [ ] **Step 1: Rewrite release.sh**

Replace the entire contents of `scripts/release.sh` with:

```bash
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

# --- Done ---------------------------------------------------------------------

echo ""
echo "Release artifact: $ZIP_PATH"
echo "Install with: cp -R .build/${APP_NAME} /Applications/"
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/release.sh`
Expected: no output (no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add scripts/release.sh
git commit -m "Update release.sh to sign and notarize .app bundle"
```
