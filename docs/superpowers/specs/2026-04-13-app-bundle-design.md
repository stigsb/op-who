# op-who .app Bundle

## Goal

Package op-who as a proper macOS .app bundle so it can be distributed via Homebrew cask and gets the correct macOS permission prompts (Automation/AppleScript).

## Bundle Structure

```
op-who.app/
  Contents/
    Info.plist
    MacOS/
      op-who
```

No Resources directory or icon for now.

## Info.plist

Key entries:

| Key | Value | Purpose |
|-----|-------|---------|
| CFBundleIdentifier | ai.sunstoneinstitute.op-who | Bundle ID |
| CFBundleName | op-who | Display name |
| CFBundleExecutable | op-who | Binary name |
| CFBundleVersion | 1.0.0 | Build version |
| CFBundleShortVersionString | 1.0.0 | Marketing version |
| CFBundlePackageType | APPL | Application bundle |
| LSUIElement | true | Menu bar app, no dock icon |
| LSMinimumSystemVersion | 13.0 | macOS Ventura+ |
| NSAppleEventsUsageDescription | op-who sends Apple Events to terminal apps to identify and activate the tab that triggered a 1Password approval. | Automation permission prompt |

## Scripts

### scripts/bundle.sh

Assembles `.app` from SPM build output. Accepts build configuration (debug/release, default debug).

1. Run `swift build [-c release]`
2. Create `op-who.app/Contents/MacOS/`
3. Copy binary into `MacOS/`
4. Copy `Info.plist` into `Contents/`
5. Output path to assembled bundle

### scripts/release.sh (updated)

Replace bare binary signing with .app bundle signing:

1. Call `scripts/bundle.sh release` to build and assemble
2. Sign the `.app` bundle with `codesign --deep --force --options runtime`
3. Verify signature
4. Zip the `.app` bundle with `ditto`
5. Submit zip for notarization
6. Staple the `.app` (stapling works on .app bundles, unlike bare binaries)
7. Re-zip the stapled `.app` for distribution

## Code Changes

### main.swift

Remove `app.setActivationPolicy(.accessory)` — `LSUIElement=true` in Info.plist handles this at the system level.

## Files Changed

- `Sources/Info.plist` (new) — plist template
- `scripts/bundle.sh` (new) — assembles .app bundle
- `scripts/release.sh` (modified) — sign/notarize .app instead of bare binary
- `Sources/main.swift` (modified) — remove setActivationPolicy line
