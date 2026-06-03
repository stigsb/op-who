# About + Check-for-Updates Menu Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add "About op-who" and "Check for Updates…" items to the status-bar menu.

**Architecture:** A new `UpdateChecker` enum in `OpWhoLib` holds the pure, testable logic (version parsing, numeric semver comparison, GitHub JSON evaluation) plus a thin `URLSession` fetch. `main.swift` gains the two menu items and their `@objc` action handlers, which build `NSAlert` dialogs. The current version is read live from `Bundle.main` so it is never hard-coded.

**Tech Stack:** Swift 5.9, AppKit, Foundation `URLSession`, Swift Testing (`import Testing`). macOS 13+.

---

## File Structure

- **Create** `Sources/OpWhoLib/UpdateChecker.swift` — `UpdateCheckResult` enum, `AppInfo` (version + repo URL), and `UpdateChecker` (pure parse/compare/evaluate functions + network fetch).
- **Create** `Tests/UpdateCheckerTests.swift` — unit tests for the pure logic.
- **Modify** `Sources/op-who/main.swift` — add two `NSMenuItem`s to the status-bar menu and the `showAbout(_:)` / `checkForUpdates(_:)` action handlers.

---

## Task 1: Version parsing and comparison (pure logic)

**Files:**
- Create: `Sources/OpWhoLib/UpdateChecker.swift`
- Test: `Tests/UpdateCheckerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/UpdateCheckerTests.swift`:

```swift
import Testing
import Foundation
@testable import OpWhoLib

@Suite("UpdateChecker version logic")
struct UpdateCheckerVersionTests {

    @Test func parsesBareVersion() {
        #expect(UpdateChecker.parseVersion("0.9.0") == [0, 9, 0])
    }

    @Test func stripsLeadingV() {
        #expect(UpdateChecker.parseVersion("v0.9.0") == [0, 9, 0])
        #expect(UpdateChecker.parseVersion("V1.2.3") == [1, 2, 3])
    }

    @Test func rejectsMalformedVersion() {
        #expect(UpdateChecker.parseVersion("") == nil)
        #expect(UpdateChecker.parseVersion("v") == nil)
        #expect(UpdateChecker.parseVersion("1.x.0") == nil)
        #expect(UpdateChecker.parseVersion("nightly") == nil)
    }

    @Test func comparesNumericallyNotLexically() {
        // Lexical compare would say "0.10.0" < "0.9.0"; numeric must not.
        #expect(UpdateChecker.compare([0, 10, 0], [0, 9, 0]) == .orderedDescending)
        #expect(UpdateChecker.compare([0, 9, 0], [0, 10, 0]) == .orderedAscending)
    }

    @Test func comparesEqualVersions() {
        #expect(UpdateChecker.compare([0, 8, 0], [0, 8, 0]) == .orderedSame)
    }

    @Test func comparesDifferentComponentCounts() {
        // Shorter version is zero-padded: 1.2 == 1.2.0, and 1.2.1 > 1.2.
        #expect(UpdateChecker.compare([1, 2], [1, 2, 0]) == .orderedSame)
        #expect(UpdateChecker.compare([1, 2, 1], [1, 2]) == .orderedDescending)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckerVersionTests`
Expected: FAIL — `UpdateChecker` is not defined (compile error).

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/OpWhoLib/UpdateChecker.swift`:

```swift
import Foundation

/// App metadata read live from the bundle, plus static repo links.
public enum AppInfo {
    /// The running app's marketing version (CFBundleShortVersionString).
    /// Falls back to "unknown" when read outside an app bundle (e.g. tests).
    public static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    /// The project's GitHub repository page.
    public static let repoURL = URL(string: "https://github.com/stigsb/op-who")!
}

/// Outcome of an update check.
public enum UpdateCheckResult: Equatable {
    case upToDate(current: String)
    case updateAvailable(latest: String, releaseURL: URL)
    case failed(message: String)
}

public enum UpdateChecker {

    /// GitHub REST endpoint for the most recent published (non-draft,
    /// non-prerelease) release.
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/stigsb/op-who/releases/latest")!

    /// Parse a version string into numeric components. Accepts an optional
    /// leading "v"/"V". Returns nil if any component is non-numeric or the
    /// string is empty.
    public static func parseVersion(_ string: String) -> [Int]? {
        var s = string
        if let first = s.first, first == "v" || first == "V" {
            s.removeFirst()
        }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var components: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            components.append(n)
        }
        return components.isEmpty ? nil : components
    }

    /// Compare two numeric version-component arrays, zero-padding the shorter.
    public static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateCheckerVersionTests`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/UpdateChecker.swift Tests/UpdateCheckerTests.swift
git commit -m "feat: add UpdateChecker version parsing and comparison"
```

---

## Task 2: Evaluate GitHub release JSON

**Files:**
- Modify: `Sources/OpWhoLib/UpdateChecker.swift`
- Test: `Tests/UpdateCheckerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/UpdateCheckerTests.swift`:

```swift
@Suite("UpdateChecker release evaluation")
struct UpdateCheckerEvaluateTests {

    private func releaseJSON(tag: String, url: String = "https://github.com/stigsb/op-who/releases/tag/x") -> Data {
        """
        {"tag_name": "\(tag)", "html_url": "\(url)", "name": "ignored"}
        """.data(using: .utf8)!
    }

    @Test func reportsUpdateAvailableWhenRemoteNewer() {
        let url = "https://github.com/stigsb/op-who/releases/tag/v0.9.0"
        let result = UpdateChecker.evaluate(responseData: releaseJSON(tag: "v0.9.0", url: url),
                                            currentVersion: "0.8.0")
        #expect(result == .updateAvailable(latest: "0.9.0", releaseURL: URL(string: url)!))
    }

    @Test func reportsUpToDateWhenEqual() {
        let result = UpdateChecker.evaluate(responseData: releaseJSON(tag: "v0.8.0"),
                                            currentVersion: "0.8.0")
        #expect(result == .upToDate(current: "0.8.0"))
    }

    @Test func reportsUpToDateWhenRemoteOlder() {
        let result = UpdateChecker.evaluate(responseData: releaseJSON(tag: "v0.7.0"),
                                            currentVersion: "0.8.0")
        #expect(result == .upToDate(current: "0.8.0"))
    }

    @Test func failsOnMalformedTag() {
        let result = UpdateChecker.evaluate(responseData: releaseJSON(tag: "nightly"),
                                            currentVersion: "0.8.0")
        if case .failed = result { } else { Issue.record("expected .failed, got \(result)") }
    }

    @Test func failsOnGarbageJSON() {
        let result = UpdateChecker.evaluate(responseData: Data("not json".utf8),
                                            currentVersion: "0.8.0")
        if case .failed = result { } else { Issue.record("expected .failed, got \(result)") }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckerEvaluateTests`
Expected: FAIL — `evaluate(responseData:currentVersion:)` is not defined.

- [ ] **Step 3: Write the implementation**

Add to the `UpdateChecker` enum in `Sources/OpWhoLib/UpdateChecker.swift` (above the closing brace):

```swift
    private struct ReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Decode a GitHub `/releases/latest` response body and decide whether an
    /// update is available relative to `currentVersion`. Pure — no network.
    public static func evaluate(responseData: Data, currentVersion: String) -> UpdateCheckResult {
        let release: ReleaseResponse
        do {
            release = try JSONDecoder().decode(ReleaseResponse.self, from: responseData)
        } catch {
            return .failed(message: "Unexpected response from GitHub.")
        }

        guard let latestComponents = parseVersion(release.tagName),
              let releaseURL = URL(string: release.htmlURL) else {
            return .failed(message: "Could not read the latest release info.")
        }

        // Normalized (v-stripped) string for display.
        let latestDisplay = latestComponents.map(String.init).joined(separator: ".")

        guard let currentComponents = parseVersion(currentVersion) else {
            // Can't compare against an unknown local version; surface the
            // available release rather than claiming up-to-date.
            return .updateAvailable(latest: latestDisplay, releaseURL: releaseURL)
        }

        switch compare(latestComponents, currentComponents) {
        case .orderedDescending:
            return .updateAvailable(latest: latestDisplay, releaseURL: releaseURL)
        case .orderedSame, .orderedAscending:
            return .upToDate(current: currentVersion)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateCheckerEvaluateTests`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/UpdateChecker.swift Tests/UpdateCheckerTests.swift
git commit -m "feat: evaluate GitHub release JSON against current version"
```

---

## Task 3: Network fetch (thin wrapper)

**Files:**
- Modify: `Sources/OpWhoLib/UpdateChecker.swift`

No unit test: this method only performs the live `URLSession` request and
delegates all decision logic to the already-tested `evaluate(...)`. Verified by
a clean build.

- [ ] **Step 1: Add the fetch method**

Add to the `UpdateChecker` enum in `Sources/OpWhoLib/UpdateChecker.swift` (above the closing brace):

```swift
    /// Fetch the latest release from GitHub and evaluate it against
    /// `currentVersion`. The completion handler is always invoked on the main
    /// thread. Network and decoding failures map to `.failed`.
    public static func checkForUpdates(
        currentVersion: String,
        session: URLSession = .shared,
        completion: @escaping (UpdateCheckResult) -> Void
    ) {
        func finish(_ result: UpdateCheckResult) {
            DispatchQueue.main.async { completion(result) }
        }

        var request = URLRequest(url: latestReleaseAPI)
        // GitHub's API rejects requests without a User-Agent.
        request.setValue("op-who/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                finish(.failed(message: error.localizedDescription))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                finish(.failed(message: "GitHub returned HTTP \(http.statusCode)."))
                return
            }
            guard let data = data else {
                finish(.failed(message: "No data received from GitHub."))
                return
            }
            finish(evaluate(responseData: data, currentVersion: currentVersion))
        }
        task.resume()
    }
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Run the full test suite (no regressions)**

Run: `swift test`
Expected: PASS — all existing tests plus the new `UpdateChecker` suites.

- [ ] **Step 4: Commit**

```bash
git add Sources/OpWhoLib/UpdateChecker.swift
git commit -m "feat: add UpdateChecker network fetch"
```

---

## Task 4: Menu items and dialogs in main.swift

**Files:**
- Modify: `Sources/op-who/main.swift`

This task wires UI (menu items + `NSAlert` dialogs). It is verified by build and
by running the assembled app — there is no unit test for AppKit dialog code.

- [ ] **Step 1: Add the two menu items**

In `Sources/op-who/main.swift`, inside `applicationDidFinishLaunching`, locate the block that adds `configItem` (the "Settings…" item) to `menu`. Immediately **after** `menu.addItem(configItem)` and **before** the `quitItem` is constructed, insert:

```swift
        let aboutItem = NSMenuItem(
            title: "About op-who",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = self
        menu.addItem(updatesItem)
        menu.addItem(.separator())
```

Note: the existing code already adds a `.separator()` *before* `configItem`. The
new `.separator()` above sits between "Check for Updates…" and "Quit op-who".

- [ ] **Step 2: Add the action handlers**

In `Sources/op-who/main.swift`, add these two methods to the `AppDelegate` class (e.g. immediately after the existing `@objc func quitAction(_:)` method):

```swift
    /// Bring the (LSUIElement) app to the front so a modal alert is visible
    /// and key. Mirrors the activation done in openConfigure(_:).
    private func activateForDialog() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout(_ sender: Any?) {
        activateForDialog()
        let alert = NSAlert()
        alert.messageText = "op-who \(AppInfo.version)"
        alert.informativeText =
            "Identifies which app/process/tab/tty triggered a 1Password approval dialog."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(AppInfo.repoURL)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.checkForUpdates(currentVersion: AppInfo.version) { [weak self] result in
            guard let self = self else { return }
            self.activateForDialog()
            let alert = NSAlert()
            switch result {
            case .upToDate(let current):
                alert.messageText = "You're up to date"
                alert.informativeText = "You're on the latest version (\(current))."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            case .updateAvailable(let latest, let releaseURL):
                alert.messageText = "Update available"
                alert.informativeText =
                    "op-who \(latest) is available (you have \(AppInfo.version))."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(releaseURL)
                }
            case .failed(let message):
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
```

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 4: Run the full test suite (no regressions)**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Manual smoke test**

Run: `scripts/bundle.sh && open .build/op-who.app`
Then click the menu-bar "?" icon and verify:
- "About op-who" and "Check for Updates…" appear between "Settings…" and "Quit op-who".
- "About op-who" shows `op-who <version>` + the description; "View on GitHub" opens the repo.
- "Check for Updates…" shows "You're up to date" (current release is 0.8.0) — or "Update available" if a newer release exists.

- [ ] **Step 6: Commit**

```bash
git add Sources/op-who/main.swift
git commit -m "feat: add About and Check-for-Updates menu items"
```

---

## Self-Review Notes

- **Spec coverage:** About dialog (Task 4), version read live from `Bundle.main` via `AppInfo.version` (Task 1), GitHub link (Task 4), update check query/compare/notify (Tasks 1–3), three result states incl. manual up-to-date confirmation (Task 4), `Download` opens releases page not auto-download (Task 4), tests for compare/normalize/parse (Tasks 1–2). All covered.
- **Type consistency:** `UpdateCheckResult` cases (`upToDate(current:)`, `updateAvailable(latest:releaseURL:)`, `failed(message:)`), `AppInfo.version`, `AppInfo.repoURL`, `UpdateChecker.parseVersion`, `.compare`, `.evaluate`, `.checkForUpdates` are used identically across tasks.
- **No placeholders:** every code step contains complete code; commands have expected output.
