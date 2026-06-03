# Design: "About op-who" and "Check for Updates…" menu items

## Goal

Add two items to the status-bar menu:

1. **About op-who** — a dialog showing the app name, current version, a short
   description, and a link to the GitHub repository.
2. **Check for Updates…** — queries GitHub for the latest release, compares it
   against the running version, and reports the result.

## Menu placement

Both items go in the status-bar menu built in `Sources/op-who/main.swift`,
inserted above the existing separator that precedes `Quit op-who`:

```
Accessibility: Granted / Not Granted
─────────────────
Settings…              ⌘,
About op-who
Check for Updates…
─────────────────
Quit op-who            ⌘Q
```

## Component 1 — About dialog

`@objc func showAbout(_:)` in `main.swift` builds an `NSAlert`:

- **messageText:** `op-who <version>`, where `<version>` is read live from
  `Bundle.main.infoDictionary["CFBundleShortVersionString"]`. Never hard-coded.
- **informativeText:** "Identifies which app/process/tab/tty triggered a
  1Password approval dialog."
- **Buttons:** `OK` (default) and `View on GitHub`, which opens
  `https://github.com/stigsb/op-who` via `NSWorkspace.shared.open(_:)`.
- Activates the app first via `NSApp.activate(ignoringOtherApps:)` (the same
  pattern `openConfigure(_:)` already uses), because `LSUIElement` apps are not
  frontmost when a menu item fires.

## Component 2 — Update check

### `UpdateChecker` (new type in `OpWhoLib`)

The pure logic lives in the library so it is unit-testable; the network call is
thin.

- **Network:** `URLSession` GET to
  `https://api.github.com/repos/stigsb/op-who/releases/latest` with a
  `User-Agent` header (GitHub rejects API requests without one). Runs on a
  background queue; the completion handler hops back to the main thread.
  `/releases/latest` already excludes drafts and pre-releases.
- **Parse:** decode `tag_name` (e.g. `"v0.9.0"`) and `html_url` from the JSON
  response. Strip a leading `v` from the tag.
- **Compare:** component-wise numeric semver comparison against the running
  version (NOT lexical string compare, so `0.10.0 > 0.9.0`). Tag normalization
  and comparison are pure functions.
- **Result:** an enum with three cases:
  - `.upToDate(current: String)`
  - `.updateAvailable(latest: String, releaseURL: URL)`
  - `.failed(message: String)`

The parse/compare entry points are exposed so tests can feed canned JSON `Data`
without hitting the network.

### `@objc func checkForUpdates(_:)` (in `main.swift`)

Calls `UpdateChecker`, then shows an `NSAlert` based on the result (activating
the app first, as above):

- **`.updateAvailable`:** "op-who <latest> is available (you have <current>)."
  Buttons: `Download` → opens the release `html_url` via `NSWorkspace`
  (intentionally the releases page, not an auto-download — the README documents
  a tarball + signature-verification install flow); and `Later`.
- **`.upToDate`:** "You're on the latest version (<current>)." Button: `OK`.
  A manual click always confirms, even when up to date.
- **`.failed`:** "Couldn't check for updates: <reason>." Button: `OK`.

## Testing

Swift Testing (`import Testing`) tests for the pure logic in `UpdateChecker`:

- **Version comparison:** `0.8.0 < 0.9.0`; equal versions; `0.10.0 > 0.9.0`
  (numeric, not lexical); remote older than local.
- **Tag normalization:** `v0.9.0` → `0.9.0`; already-bare `0.9.0`; malformed
  tag handled gracefully (→ `.failed`).
- **Response parsing:** canned GitHub JSON → correct `tag_name` / `html_url`;
  missing or malformed fields → `.failed`.

The live `URLSession` request is not unit-tested.

## Non-goals

- No Sparkle framework; no auto-download or auto-install.
- No periodic/background update checks ("don't spam" — only the explicit menu
  click triggers a check). The `.upToDate` confirmation is acceptable because it
  is user-initiated.
