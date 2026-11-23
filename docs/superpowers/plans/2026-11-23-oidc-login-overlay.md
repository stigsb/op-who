# OIDC Login Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show op-who's overlay inside the browser window when kubelogin starts an OIDC login, naming the command and app that needed it.

**Architecture:** `oidc-browser` (repo `sunstoneinstitute/cli-tools`) posts a distributed notification with kubelogin's PID and the browser window frame. A new `OidcLoginWatcher` in op-who checks through `proc_pidpath` that the PID runs kubelogin, builds the process chain, drops the kubelogin nodes, builds an overlay entry through a `TriggerEntryBuilder` extracted from `OnePasswordWatcher`, shows it in its own reused `OverlayPanel`, and dismisses when kubelogin exits. `ProcessTree.buildChain` records the macOS app the chain stopped at so the overlay can name it.

**Tech Stack:** Swift, AppKit, `DistributedNotificationCenter`, Swift Testing, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-23-oidc-login-overlay-design.md` (op-who repo). The spec wins over this plan on any detail.

## Global Constraints

- Two repos. Tasks 1–8: op-who. Task 9: cli-tools at `~/git/sunstone/cli-tools`.
- Notification name: `com.stigbakken.op-who.oidc-login`. userInfo keys `requesterPID` (decimal string) and optional `frame` (`"x,y,w,h"`, CG global coordinates, top-left origin). All values are strings.
- A process is a kubelogin helper when the basename of its `proc_pidpath` executable path is `kubectl-oidc_login` or `kubelogin`. Never decide this from argv[0], the `KERN_PROCARGS2` exec path (`ProcessTree.executablePath` is that, do not use it), or `ProcessNode.name`.
- 1Password overlays must not change: same text, same rows, same placement. Every OIDC-specific branch is gated on `RequestSource.oidcLogin` or on a parameter that defaults to the 1Password behavior.
- `PopupLayout.swift` builders stay pure (no AppKit). `OverlayColors.swift` stays the only home of default colors. Trigger argv passes through `redactArgv` at capture.
- op-who tests: `swift test` (Swift Testing, `import Testing`, `@testable import OpWhoLib`). All test files live flat in `Tests/`. See `CONTRIBUTORS.md` if on a CommandLineTools-only Mac.
- cli-tools verification: `make && make test` from repo root.
- Commit messages: no Co-authored-by or tool attribution.

---

### Task 1: `RequestKind.oidcLogin` and the `oidcLogin` color role (op-who)

**Files:**
- Modify: `Sources/OpWhoLib/RequestSummary.swift` (`enum RequestKind`, top of file)
- Modify: `Sources/OpWhoLib/CandidateSelection.swift` (`kindRank`, bottom of file)
- Modify: `Sources/OpWhoLib/OverlayColors.swift`
- Modify: `Sources/OpWhoLib/PopupStyle.swift` (`enum PopupColorRole`)
- Modify: `Sources/OpWhoLib/OverlayPanel.swift` (`bodyActionColor`)
- Modify: `Sources/op-who/RulesPane.swift` (comment only, at `kindPopup.addItems`)
- Modify: `Tests/OverlayColorsTests.swift`
- Test: `Tests/OidcKindColorTests.swift`

**Interfaces:**
- Produces:
  - `RequestKind.oidcLogin` (raw value `"oidcLogin"`)
  - `PopupColorRole.oidcLogin` (raw value `"oidcLogin"`)
  - `OverlayColors.oidcLogin: NSColor`

- [ ] **Step 1: Write the failing tests**

`Tests/OidcKindColorTests.swift`:

```swift
import AppKit
import Testing
@testable import OpWhoLib

@Suite("oidcLogin kind and color role")
struct OidcKindColorTests {
    @Test func kindRawValueIsStable() {
        #expect(RequestKind.oidcLogin.rawValue == "oidcLogin")
    }

    @Test func roleDefaultsToOverlayColor() {
        let a = OverlayColors.srgb(PopupColorRole.oidcLogin.defaultColor)
        let b = OverlayColors.srgb(OverlayColors.oidcLogin)
        #expect(a == b)
    }

    @Test func roleIsOverridablePerAppearance() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overrides: [PopupStyle.overrideKey(.oidcLogin, .light): "#112233"]
        )
        #expect(style.color(.oidcLogin, variant: .light).popupHexString == "#112233")
        let dark = OverlayColors.srgb(style.color(.oidcLogin, variant: .dark))
        let defaultDark = OverlayColors.srgb(
            OverlayColors.resolved(OverlayColors.oidcLogin, in: .darkAqua))
        #expect(dark == defaultDark)
    }
}
```

In `Tests/OverlayColorsTests.swift`, change the `bodyColors` array so the contrast tests cover the new color:

```swift
    private let bodyColors: [NSColor] = [
        OverlayColors.claude, OverlayColors.editor,
        OverlayColors.verifiedOp, OverlayColors.unverifiedOp,
        OverlayColors.ssh, OverlayColors.oidcLogin, OverlayColors.dimLabel,
        OverlayColors.gitRoot, OverlayColors.branch, OverlayColors.worktree,
    ]
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OidcKindColorTests`
Expected: compile failure, `type 'RequestKind' has no member 'oidcLogin'`.

- [ ] **Step 3: Add the kind**

In `RequestSummary.swift`, add a case to `RequestKind` after `ssh`:

```swift
    /// OIDC login started by kubelogin. Used only by `OidcLogin.rules`.
    case oidcLogin
```

In `CandidateSelection.swift`, replace `kindRank`:

```swift
private func kindRank(_ kind: RequestKind) -> Int {
    switch kind {
    case .onePasswordCLI: return 0
    case .ssh:            return 1
    // OIDC entries never reach candidate ranking; the value only keeps the switch exhaustive.
    case .unknown, .oidcLogin: return 2
    case .unverifiedOp:   return 3
    }
}
```

- [ ] **Step 4: Add the color**

In `OverlayColors.swift`, after the `ssh` pair:

```swift
    // Yellow-green (hue ~85°), in the widest gap between existing hues
    // (gold 45°, green 147°).
    public static let oidcLogin = dynamic(
        light: NSColor(srgbRed: 0.24, green: 0.44, blue: 0.0, alpha: 1),
        dark:  NSColor(srgbRed: 0.66, green: 0.88, blue: 0.28, alpha: 1))
```

In `PopupStyle.swift`, change the first `case` line of `PopupColorRole` to:

```swift
    case claude, editor, verifiedOp, unverifiedOp, ssh, oidcLogin
```

and add to `defaultColor`, after the `.ssh` line:

```swift
        case .oidcLogin:    return OverlayColors.oidcLogin
```

`AppearancePane` builds its color wells from `PopupColorRole.allCases`, so the new role appears there and is overridable with no further change.

In `OverlayPanel.swift`, add to `bodyActionColor`, after the `.ssh` line:

```swift
        case .oidcLogin:      return style.color(.oidcLogin)
```

- [ ] **Step 5: Keep the Rules pane picker closed**

In `Sources/op-who/RulesPane.swift`, directly above `kindPopup.addItems(withTitles: [`, add this comment and do not add an item:

```swift
        // RequestKind.oidcLogin is deliberately absent: OIDC rules are fixed
        // (OidcLogin.rules), not user-editable.
```

- [ ] **Step 6: Run all tests**

Run: `swift build && swift test`
Expected: build succeeds with no "switch must be exhaustive" errors, all tests PASS including both `OverlayColors contrast` tests. If a contrast test fails for `oidcLogin`, darken the light value or lighten the dark value in `OverlayColors.swift` (keep the hue), never loosen the test.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpWhoLib/RequestSummary.swift Sources/OpWhoLib/CandidateSelection.swift \
  Sources/OpWhoLib/OverlayColors.swift Sources/OpWhoLib/PopupStyle.swift \
  Sources/OpWhoLib/OverlayPanel.swift Sources/op-who/RulesPane.swift \
  Tests/OverlayColorsTests.swift Tests/OidcKindColorTests.swift
git commit -m "Add oidcLogin request kind and color role"
```

---

### Task 2: Requesting app and kernel executable path in `ProcessTree` (op-who)

`buildChain` stops at the first macOS app without recording it unless it is a terminal. Record it for every app, and add the `proc_pidpath` lookup the OIDC trust check needs.

**Files:**
- Modify: `Sources/OpWhoLib/ProcessTree.swift` (`ChainResult`, `buildChain`, `macAppPIDs`)
- Test: `Tests/RequestingAppTests.swift`

**Interfaces:**
- Produces:
  - `ChainResult.appBundleID: String?`, `ChainResult.appPID: pid_t?` (`public var`, default `nil`, declared last)
  - `ProcessTree.kernelExecutablePath(pid: pid_t) -> String?` (public)
  - `ProcessTree.appDisplayName(bundleID: String) -> String` (public)
  - `ProcessTree.appDisplayName(bundleID: String, bundlePath: String?) -> String` (internal, pure)
  - `ProcessTree.outermostAppBundlePath(_ path: String) -> String?` (internal, pure)
  - `ProcessTree.RunningApp { pid: pid_t; bundleID: String; bundlePath: String? }` (internal)
  - `ProcessTree.outermostApp(stoppedAt: RunningApp, apps: [pid_t: RunningApp], bundleIDAt: (String) -> String?) -> (bundleID: String, pid: pid_t)` (internal, pure)

- [ ] **Step 1: Write the failing tests**

`Tests/RequestingAppTests.swift`:

```swift
import Testing
import Foundation
import Darwin
@testable import OpWhoLib

@Suite("ProcessTree requesting app")
struct RequestingAppTests {
    private let outer = "/Applications/Visual Studio Code.app"
    private let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app"

    @Test func kernelExecutablePathOfSelf() {
        let path = ProcessTree.kernelExecutablePath(pid: getpid())
        #expect(path?.hasPrefix("/") == true)
    }

    @Test func kernelExecutablePathOfMissingProcess() {
        #expect(ProcessTree.kernelExecutablePath(pid: 99_999_999) == nil)
    }

    @Test func outermostBundlePath() {
        #expect(ProcessTree.outermostAppBundlePath(helper) == outer)
        #expect(ProcessTree.outermostAppBundlePath(helper + "/Contents/MacOS/Code Helper (Plugin)") == outer)
        #expect(ProcessTree.outermostAppBundlePath(outer) == outer)
        #expect(ProcessTree.outermostAppBundlePath("/usr/local/bin/kubectl") == nil)
    }

    @Test func nestedAppReportsOutermostBundleAndItsPID() {
        let main = ProcessTree.RunningApp(pid: 50, bundleID: "com.microsoft.VSCode", bundlePath: outer)
        let nested = ProcessTree.RunningApp(pid: 70, bundleID: "com.microsoft.VSCode.helper", bundlePath: helper)
        let got = ProcessTree.outermostApp(stoppedAt: nested, apps: [50: main, 70: nested]) { path in
            path == outer ? "com.microsoft.VSCode" : nil
        }
        #expect(got.bundleID == "com.microsoft.VSCode")
        #expect(got.pid == 50)
    }

    @Test func nestedAppWithoutRunningOuterKeepsStoppedPID() {
        let nested = ProcessTree.RunningApp(pid: 70, bundleID: "com.microsoft.VSCode.helper", bundlePath: helper)
        let got = ProcessTree.outermostApp(stoppedAt: nested, apps: [70: nested]) { _ in "com.microsoft.VSCode" }
        #expect(got.bundleID == "com.microsoft.VSCode")
        #expect(got.pid == 70)
    }

    @Test func topLevelAppIsReportedAsIs() {
        let app = ProcessTree.RunningApp(pid: 50, bundleID: "com.microsoft.VSCode", bundlePath: outer)
        let got = ProcessTree.outermostApp(stoppedAt: app, apps: [50: app]) { _ in "wrong" }
        #expect(got.bundleID == "com.microsoft.VSCode")
        #expect(got.pid == 50)
    }

    @Test func unreadableOuterBundleFallsBackToStoppedApp() {
        let nested = ProcessTree.RunningApp(pid: 70, bundleID: "com.microsoft.VSCode.helper", bundlePath: helper)
        let got = ProcessTree.outermostApp(stoppedAt: nested, apps: [70: nested]) { _ in nil }
        #expect(got.bundleID == "com.microsoft.VSCode.helper")
        #expect(got.pid == 70)
    }

    @Test func displayNames() {
        #expect(ProcessTree.appDisplayName(bundleID: "com.googlecode.iterm2", bundlePath: "/Applications/iTerm.app") == "iTerm")
        #expect(ProcessTree.appDisplayName(bundleID: "com.microsoft.VSCode", bundlePath: outer) == "Visual Studio Code")
        #expect(ProcessTree.appDisplayName(bundleID: "com.example.gone", bundlePath: nil) == "com.example.gone")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter RequestingAppTests`
Expected: compile failure, `type 'ProcessTree' has no member 'kernelExecutablePath'`.

- [ ] **Step 3: Extend `ChainResult`**

In `ProcessTree.swift`, add to `ChainResult` after `scriptInfo`:

```swift
    /// Bundle ID and PID of the macOS app the chain stopped at. For a bundle
    /// nested inside another `.app` (Electron/Chromium helpers) this is the
    /// outermost one. A terminal helper counts as its terminal app. nil when
    /// the walk ended at launchd. `var` with a default so the memberwise
    /// initializer keeps these parameters optional.
    public var appBundleID: String? = nil
    public var appPID: pid_t? = nil
```

- [ ] **Step 4: Add the pure helpers and the kernel path lookup**

Add inside `enum ProcessTree`, directly above `// MARK: - Private`:

```swift
    /// Executable path the kernel recorded at exec time (`proc_pidpath`).
    /// Unlike argv[0] and the KERN_PROCARGS2 exec path, the process cannot
    /// rewrite it, and unlike the kinfo name it is not truncated.
    public static func kernelExecutablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// A running macOS app, as far as chain walking cares.
    struct RunningApp: Equatable {
        let pid: pid_t
        let bundleID: String
        let bundlePath: String?
    }

    /// Path of the outermost `.app` bundle containing `path`, or nil.
    static func outermostAppBundlePath(_ path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }

    /// The app to report for a chain that stopped at `app`: the outermost
    /// enclosing bundle when `app` is nested, else `app` itself. The PID is
    /// the running instance of the outermost bundle when there is one.
    /// `bundleIDAt` reads a bundle's identifier from its path (injected for tests).
    static func outermostApp(
        stoppedAt app: RunningApp,
        apps: [pid_t: RunningApp],
        bundleIDAt: (String) -> String?
    ) -> (bundleID: String, pid: pid_t) {
        guard let path = app.bundlePath,
              let outerPath = outermostAppBundlePath(path),
              outerPath != path,
              let outerID = bundleIDAt(outerPath) else {
            return (app.bundleID, app.pid)
        }
        let outerPID = apps.values.filter { $0.bundlePath == outerPath }.map(\.pid).min() ?? app.pid
        return (outerID, outerPID)
    }

    /// Name to show for an app: the short terminal name when known, else the
    /// bundle's file name without `.app`, else the bundle ID.
    static func appDisplayName(bundleID: String, bundlePath: String?) -> String {
        if let terminal = humanTerminalName(bundleID: bundleID), terminal != bundleID {
            return terminal
        }
        if let path = bundlePath {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if !name.isEmpty { return name }
        }
        return bundleID
    }

    public static func appDisplayName(bundleID: String) -> String {
        appDisplayName(
            bundleID: bundleID,
            bundlePath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        )
    }
```

- [ ] **Step 5: Record the app in `buildChain`**

Replace the private `macAppPIDs()` function with:

```swift
    /// Running Mac apps keyed by PID.
    private static func runningApps() -> [pid_t: RunningApp] {
        var result: [pid_t: RunningApp] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier {
                result[app.processIdentifier] = RunningApp(
                    pid: app.processIdentifier, bundleID: bid, bundlePath: app.bundleURL?.path
                )
            }
        }
        return result
    }
```

In `buildChain(from:)`:

1. Replace the two lines `// Build a set of PIDs that are Mac apps, mapped to their bundle IDs` / `let appPIDs = macAppPIDs()` with `let apps = runningApps()`.
2. After `var claudePID: pid_t? = nil` add:

```swift
        var appBundleID: String? = nil
        var appPID: pid_t? = nil
```

3. Replace the whole `// Check if this is a Mac app` block (`if let bundleID = appPIDs[current] { … break }`) with:

```swift
            // Check if this is a Mac app
            if let app = apps[current] {
                if terminalBundleIDs.contains(app.bundleID) {
                    terminalBundleID = app.bundleID
                    terminalPID = current
                }
                let outer = Self.outermostApp(stoppedAt: app, apps: apps) {
                    Bundle(path: $0)?.bundleIdentifier
                }
                appBundleID = outer.bundleID
                appPID = outer.pid
                // The app is recorded but not added to the chain.
                break
            }
```

4. In the terminal-helper block, add two lines before its `break`:

```swift
                appBundleID = helperBundle
                appPID = current
```

5. In the `return ChainResult(` call, add two arguments after `scriptInfo: scriptInfo`:

```swift
            scriptInfo: scriptInfo,
            appBundleID: appBundleID,
            appPID: appPID
```

- [ ] **Step 6: Run all tests**

Run: `swift test`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpWhoLib/ProcessTree.swift Tests/RequestingAppTests.swift
git commit -m "Record the requesting app in ChainResult and add proc_pidpath lookup"
```

---

### Task 3: Extract `TriggerEntryBuilder`, add `RequestSource` and the app-name actor (op-who)

Refactor of `OnePasswordWatcher.handleWindowEvent` so the OIDC watcher can reuse it. No behavior change for 1Password.

**Files:**
- Create: `Sources/OpWhoLib/RequestSource.swift`
- Create: `Sources/OpWhoLib/TriggerEntryBuilder.swift`
- Modify: `Sources/OpWhoLib/OnePasswordWatcher.swift` (loop body in `handleWindowEvent`)
- Modify: `Sources/OpWhoLib/OverlayPanel.swift` (`ProcessEntry`, "Send Message" button, `sendTTYMessage`)
- Modify: `Sources/OpWhoLib/RequestSummary.swift` (`makeRequestSummary`, `describeActor`)
- Test: `Tests/TriggerEntryBuilderTests.swift`

**Interfaces:**
- Consumes: `RequestKind.oidcLogin` (Task 1); `ChainResult.appBundleID/appPID`, `ProcessTree.appDisplayName(bundleID:)` (Task 2).
- Produces:
  - `public enum RequestSource: String { case onePassword, oidcLogin }` with `var ttyMessage: String`
  - `OverlayPanel.ProcessEntry` new defaulted fields, declared last in this order: `source: RequestSource = .onePassword`, `appBundleID: String? = nil`, `appPID: pid_t? = nil`, `appName: String? = nil`
  - `makeRequestSummary(..., rules: [RequestRule]? = nil, appName: String? = nil)` — `appName` is the actor when `chain` is empty
  - `enum TriggerEntryBuilder { static func makeEntry(foldedChain: [ProcessNode], fallbackNode: ProcessNode, chainResult: ChainResult, triggerArgv: [String], rules: [RequestRule], source: RequestSource) -> OverlayPanel.ProcessEntry }`. `foldedChain` may be empty; `fallbackNode` then supplies PID, environment and CWD.

- [ ] **Step 1: Write the failing tests**

`Tests/TriggerEntryBuilderTests.swift`:

```swift
import Testing
import Foundation
import Darwin
@testable import OpWhoLib

@Suite("TriggerEntryBuilder")
struct TriggerEntryBuilderTests {
    // Synthetic chain with no TTY/terminal/Claude so the builder never
    // calls AppleScript or reads cmux state during tests.
    private func selfNode(_ name: String) -> ProcessNode {
        ProcessNode(pid: getpid(), ppid: 1, name: name, tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: false)
    }

    private func result(chain: [ProcessNode], appBundleID: String? = nil) -> ChainResult {
        ChainResult(
            chain: chain, tty: nil, terminalBundleID: nil, terminalPID: nil,
            hasClaudeCode: false, claudePID: nil, scriptInfo: nil,
            appBundleID: appBundleID, appPID: appBundleID == nil ? nil : 77
        )
    }

    private let emptyChainRule = RequestRule(
        name: "empty", predicate: #"triggerName == """#, template: "needs a login", kind: .oidcLogin
    )

    @Test func usesGivenRulesAndSource() {
        let node = selfNode("kubectl")
        let rules = [RequestRule(
            name: "t", predicate: "TRUEPREDICATE", template: "did {process}", kind: .unknown
        )]
        let entry = TriggerEntryBuilder.makeEntry(
            foldedChain: [node], fallbackNode: node, chainResult: result(chain: [node]),
            triggerArgv: ["kubectl", "get", "pods"], rules: rules, source: .oidcLogin
        )
        #expect(entry.pid == getpid())
        #expect(entry.source == .oidcLogin)
        #expect(entry.summary.title.hasSuffix("did kubectl"))
        #expect(entry.matchedRuleName == "t")
    }

    @Test func emptyChainUsesFallbackNodeAndAppActor() {
        let helper = selfNode("kubelogin")
        // A bundle ID that is not installed displays as itself.
        let bundleID = "com.example.op-who-tests.not-installed"
        let entry = TriggerEntryBuilder.makeEntry(
            foldedChain: [], fallbackNode: helper,
            chainResult: result(chain: [helper], appBundleID: bundleID),
            triggerArgv: [], rules: [emptyChainRule], source: .oidcLogin
        )
        #expect(entry.pid == getpid())
        #expect(entry.chain.isEmpty)
        #expect(entry.appBundleID == bundleID)
        #expect(entry.appPID == 77)
        #expect(entry.appName == bundleID)
        #expect(entry.summary.title == "\(bundleID) needs a login")
        #expect(entry.summary.kind == .oidcLogin)
    }

    @Test func onePasswordEntriesCarryNoAppName() {
        let node = selfNode("ssh")
        let entry = TriggerEntryBuilder.makeEntry(
            foldedChain: [node], fallbackNode: node,
            chainResult: result(chain: [node], appBundleID: "com.example.op-who-tests.not-installed"),
            triggerArgv: ["ssh", "host"], rules: RequestRule.builtIns, source: .onePassword
        )
        #expect(entry.source == .onePassword)
        #expect(entry.appName == nil)
    }

    @Test func appNameIsActorOnlyForEmptyChain() {
        let rule = RequestRule(name: "t", predicate: "TRUEPREDICATE", template: "x", kind: .unknown)
        let empty = makeRequestSummary(
            chain: [], triggerArgv: [], tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil, rules: [rule], appName: "Visual Studio Code"
        )
        #expect(empty.title == "Visual Studio Code x")

        let noApp = makeRequestSummary(
            chain: [], triggerArgv: [], tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil, rules: [rule]
        )
        #expect(noApp.title == "An unknown process x")

        let withChain = makeRequestSummary(
            chain: [selfNode("zsh")], triggerArgv: [], tabTitle: nil, claudeSession: nil,
            terminalBundleID: nil, cwd: nil, rules: [rule], appName: "Visual Studio Code"
        )
        #expect(withChain.title == "Your zsh shell x")
    }

    @Test func ttyMessageNamesTheSource() {
        #expect(RequestSource.onePassword.ttyMessage.contains("1Password approval"))
        #expect(RequestSource.oidcLogin.ttyMessage.contains("OIDC login"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TriggerEntryBuilderTests`
Expected: compile failure, `cannot find 'TriggerEntryBuilder'` / `RequestSource`.

- [ ] **Step 3: Add `RequestSource`**

`Sources/OpWhoLib/RequestSource.swift`:

```swift
/// What kind of prompt an overlay entry belongs to.
public enum RequestSource: String {
    case onePassword
    case oidcLogin

    /// Line written to the trigger's TTY by the overlay's "Send Message" button.
    var ttyMessage: String {
        switch self {
        case .onePassword: return "\n[op-who] 1Password approval requested from this session\n"
        case .oidcLogin: return "\n[op-who] OIDC login requested from this session\n"
        }
    }
}
```

- [ ] **Step 4: Extend `ProcessEntry` and the TTY message**

In `OverlayPanel.ProcessEntry`, after `var soundID: String? = nil`, add:

```swift
        /// Which prompt this entry explains. Drives the "Send Message" text
        /// and the OIDC-only rendering branches.
        var source: RequestSource = .onePassword
        /// The macOS app the chain stopped at (`ChainResult.appBundleID/appPID`).
        var appBundleID: String? = nil
        var appPID: pid_t? = nil
        /// Display name of that app. Set for OIDC entries only.
        var appName: String? = nil
```

In `buildEntryView`, change `msgBtn.cell?.representedObject = tty` to:

```swift
            msgBtn.cell?.representedObject = [tty, entry.source.rawValue]
```

Replace `sendTTYMessage` with:

```swift
    @objc private func sendTTYMessage(_ sender: NSButton) {
        guard let info = sender.cell?.representedObject as? [String],
              info.count == 2,
              let source = RequestSource(rawValue: info[1]) else { return }
        TerminalHelper.writeMessage(to: info[0], message: source.ttyMessage)
    }
```

- [ ] **Step 5: Add the `appName` actor to `RequestSummary.swift`**

1. In `makeRequestSummary`'s parameter list, change `rules: [RequestRule]? = nil` to:

```swift
    rules: [RequestRule]? = nil,
    appName: String? = nil
```

2. In its doc comment, add: `/// `appName` names the requesting app and is used as the actor only when `chain` is empty (OIDC logins started by an app). 1Password callers leave it nil.`
3. In its `describeActor(` call, add `appName: appName` as the last argument (after `terminalBundleID: terminalBundleID`).
4. Change the `describeActor` signature to:

```swift
private func describeActor(
    chain: [ProcessNode],
    tabTitle: String?,
    claudeSession: String?,
    terminalBundleID: String?,
    appName: String? = nil
) -> String {
```

and make these the first lines of its body:

```swift
    // No command in the chain: the app itself asked.
    if chain.isEmpty, let appName = appName { return appName }
```

Do not change the `describeActor` call in `previewTitle`.

- [ ] **Step 6: Create `TriggerEntryBuilder`**

`Sources/OpWhoLib/TriggerEntryBuilder.swift`:

```swift
import Foundation

/// Gathers terminal, Claude, cmux, git and rule context for one trigger
/// process. Shared by the 1Password and OIDC watchers so both overlays
/// carry the same context and the same secret redaction.
enum TriggerEntryBuilder {
    /// `foldedChain` is trigger-first and may be empty (an app ran kubelogin
    /// itself). `fallbackNode` then supplies the PID, environment and CWD;
    /// 1Password callers pass the trigger node. `triggerArgv` must already
    /// be redacted.
    static func makeEntry(
        foldedChain: [ProcessNode],
        fallbackNode: ProcessNode,
        chainResult result: ChainResult,
        triggerArgv: [String],
        rules: [RequestRule],
        source: RequestSource
    ) -> OverlayPanel.ProcessEntry {
        let contextChain = foldedChain.isEmpty ? [fallbackNode] : foldedChain
        let triggerPID = contextChain[0].pid

        let tabInfo: TerminalHelper.TabInfo = result.tty.map { tty in
            measure("tabInfo[\(tty)]") {
                TerminalHelper.tabInfo(
                    forTTY: tty,
                    terminalBundleID: result.terminalBundleID,
                    terminalPID: result.terminalPID
                )
            }
        } ?? .empty
        let tabTitle = tabInfo.name

        let claudeSession: String?
        let claudeCtx: ClaudeContext?
        if let claudePID = result.claudePID {
            claudeSession = measure("claudeSessionInfo") { ProcessTree.claudeSessionInfo(pid: claudePID) }
            if let claudeCWD = measure("claudeCWD", { ProcessTree.processCWD(pid: claudePID) }) {
                claudeCtx = measure("claudeContext") { claudeContext(forCWD: claudeCWD) }
            } else {
                claudeCtx = nil
            }
        } else {
            claudeSession = nil
            claudeCtx = nil
        }

        // The trigger process often has CWD "/", so bestCWD walks to the
        // first ancestor with a real directory.
        let cwd = measure("bestCWD") { ProcessTree.bestCWD(chain: contextChain) }
            .map(ProcessTree.tidyPath)

        // The trigger's own (untidied) CWD feeds plugin-update detection and
        // the `triggerCwd` predicate key.
        let triggerCWD = measure("processCWD[\(triggerPID)]") { ProcessTree.processCWD(pid: triggerPID) }

        // Claude Code background plugin/marketplace update: a `git` trigger
        // whose own CWD lives under ~/.claude/plugins/.
        let pluginUpdate: ClaudePluginUpdate? = {
            guard foldedChain.first?.name == "git" else { return nil }
            return measure("claudePluginUpdate") {
                claudePluginUpdate(forCWD: triggerCWD)
            }
        }()

        // cmux: workspace / tab IDs from the env block, and CMUX_SURFACE_ID
        // resolved against the session file for the user-facing names.
        var cmuxWorkspaceID: String? = nil
        var cmuxTabID: String? = nil
        var cmuxSurface: CmuxSurfaceInfo? = nil
        if isCmuxBundleID(result.terminalBundleID) {
            let env = measure("processEnvironment[\(triggerPID)]") {
                ProcessTree.processEnvironment(
                    pid: triggerPID,
                    names: ["CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID"]
                )
            }
            cmuxWorkspaceID = env["CMUX_WORKSPACE_ID"]
            cmuxTabID = env["CMUX_TAB_ID"]

            // Env vars are inherited, so a node lacking the ID is covered by
            // an ancestor. Env reads plus one cached file read, nothing spawns.
            let uuid = measure("cmuxSurfaceUUID[\(triggerPID)]") {
                CmuxHelper.surfaceUUID(forChain: contextChain) { pid in
                    pid == triggerPID
                        ? env["CMUX_SURFACE_ID"]
                        : ProcessTree.processEnvironment(
                              pid: pid, names: ["CMUX_SURFACE_ID"])["CMUX_SURFACE_ID"]
                }
            }
            cmuxSurface = uuid.flatMap { id in
                measure("cmuxSurfaceInfo[uuid]") { CmuxHelper.surfaceInfo(forSurfaceID: id) }
            }

            Log.cmux.info("trigger pid=\(triggerPID, privacy: .public) CMUX_SURFACE_ID=\(uuid ?? "<none>", privacy: .public) sessionHit=\(cmuxSurface != nil, privacy: .public) CMUX_WORKSPACE_ID=\(cmuxWorkspaceID ?? "<unset>", privacy: .public)")
        }

        // The app name is the actor for OIDC entries with an empty chain.
        // 1Password entries never use it (the 1Password dialog names the app).
        let appName: String? = source == .oidcLogin
            ? result.appBundleID.map { ProcessTree.appDisplayName(bundleID: $0) }
            : nil

        // Rules are evaluated here, once. The matched rule's id/name and the
        // rendered text are stored on the entry for every downstream consumer.
        let matchContext = MatchContext(
            chain: foldedChain,
            triggerArgv: triggerArgv,
            cwd: cwd,
            triggerCwd: triggerCWD,
            claudeSession: claudeSession,
            pluginUpdate: pluginUpdate,
            terminalBundleID: result.terminalBundleID
        )
        let summary = makeRequestSummary(
            chain: foldedChain,
            triggerArgv: triggerArgv,
            tabTitle: tabTitle,
            claudeSession: claudeSession,
            scriptInfo: result.scriptInfo,
            terminalBundleID: result.terminalBundleID,
            cwd: cwd,
            triggerCwd: triggerCWD,
            pluginUpdate: pluginUpdate,
            rules: rules,
            appName: appName
        )
        let matchResult = RequestRuleEngine.evaluate(rules: rules, context: matchContext)

        let gitCtx: GitContext? = cwd.flatMap { gitContext(forCwd: $0) }

        return OverlayPanel.ProcessEntry(
            pid: triggerPID,
            chain: foldedChain,
            triggerArgv: triggerArgv,
            tty: result.tty,
            tabTitle: tabTitle,
            tabShortcut: tabInfo.shortcut,
            claudeSession: claudeSession,
            claudeContext: claudeCtx,
            scriptInfo: result.scriptInfo,
            terminalBundleID: result.terminalBundleID,
            terminalPID: result.terminalPID,
            cwd: cwd,
            triggerCwd: triggerCWD,
            cmuxWorkspaceID: cmuxWorkspaceID,
            cmuxTabID: cmuxTabID,
            cmuxSurface: cmuxSurface,
            pluginUpdate: pluginUpdate,
            summary: summary,
            matchedRuleID: matchResult?.rule.id,
            matchedRuleName: matchResult?.rule.name,
            matchedBuiltInID: matchResult?.rule.builtInID,
            gitContext: gitCtx,
            soundID: matchResult?.rule.soundID,
            source: source,
            appBundleID: result.appBundleID,
            appPID: result.appPID,
            appName: appName
        )
    }
}
```

- [ ] **Step 7: Call the builder from `OnePasswordWatcher`**

In `handleWindowEvent`'s `for proc in triggerProcs` loop, delete everything from the line `let tabInfo: TerminalHelper.TabInfo = result.tty.map { tty in` through the end of the `candidates.append(TriggerCandidate(...))` call, and put this in its place:

```swift
            let entry = TriggerEntryBuilder.makeEntry(
                foldedChain: foldedChain,
                fallbackNode: triggerNode,
                chainResult: result,
                triggerArgv: triggerArgv,
                rules: OpWhoConfig.rules,
                source: .onePassword
            )

            candidates.append(TriggerCandidate(
                entry: entry,
                kind: entry.summary.kind,
                startTime: ProcessTree.processStartTime(pid: triggerPID)
            ))
```

Everything above the deleted block (chain build, short-chain filter, `foldOpHelper`, `triggerNode`, `triggerPID`, `triggerArgv`, the non-network `git` filter) and everything after the loop stays as is.

- [ ] **Step 8: Run all tests**

Run: `swift build && swift test`
Expected: no warnings about unused variables in `OnePasswordWatcher.swift`, all tests PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/OpWhoLib/RequestSource.swift Sources/OpWhoLib/TriggerEntryBuilder.swift \
  Sources/OpWhoLib/OnePasswordWatcher.swift Sources/OpWhoLib/OverlayPanel.swift \
  Sources/OpWhoLib/RequestSummary.swift Tests/TriggerEntryBuilderTests.swift
git commit -m "Extract TriggerEntryBuilder from OnePasswordWatcher"
```

---

### Task 4: `OidcLogin` parsing, helper detection and rules (op-who, pure logic)

**Files:**
- Create: `Sources/OpWhoLib/OidcLogin.swift`
- Test: `Tests/OidcLoginTests.swift`

**Interfaces:**
- Consumes: `RequestKind.oidcLogin` (Task 1); `makeRequestSummary(..., rules:, appName:)` (Task 3).
- Produces:
  - `public enum OidcLogin`
  - `public static let notificationName: Notification.Name`
  - `public static func isHelper(executablePath: String) -> Bool`
  - `static func dropHelpers(chain: [ProcessNode], pathFor: (pid_t) -> String?) -> [ProcessNode]` (may return an empty chain)
  - `public struct Request: Equatable { public let requesterPID: pid_t; public let frame: CGRect? }`
  - `static func parse(userInfo: [AnyHashable: Any]?) -> Request?`
  - `public static let rules: [RequestRule]` (three rules, all `kind: .oidcLogin`)

No new predicate key is needed for "empty chain": `MatchContext.triggerName` is `""` exactly when the chain is empty, so the rule uses `triggerName == ""`.

- [ ] **Step 1: Write the failing tests**

`Tests/OidcLoginTests.swift`:

```swift
import Testing
import Foundation
import Darwin
@testable import OpWhoLib

private func node(_ name: String, pid: pid_t) -> ProcessNode {
    ProcessNode(pid: pid, ppid: 1, name: name, tty: nil,
                executablePath: nil, isVerifiedOnePasswordCLI: false)
}

@Suite("OidcLogin")
struct OidcLoginTests {
    @Test func helperMatchesExecutableBasename() {
        #expect(OidcLogin.isHelper(executablePath: "/opt/homebrew/bin/kubectl-oidc_login"))
        #expect(OidcLogin.isHelper(executablePath: "/usr/local/bin/kubelogin"))
        #expect(!OidcLogin.isHelper(executablePath: "/usr/local/bin/kubectl"))
        #expect(!OidcLogin.isHelper(executablePath: "/tmp/kubectl-oidc_log"))
        #expect(!OidcLogin.isHelper(executablePath: "/tmp/kubelogin/evil"))
    }

    @Test func dropRemovesLeadingHelpers() {
        let chain = [node("kubectl-oidc_log", pid: 10), node("kubectl", pid: 9), node("bash", pid: 8)]
        let paths: [pid_t: String] = [
            10: "/opt/homebrew/bin/kubectl-oidc_login", 9: "/opt/homebrew/bin/kubectl", 8: "/bin/bash",
        ]
        let rest = OidcLogin.dropHelpers(chain: chain) { paths[$0] }
        #expect(rest.map(\.pid) == [9, 8])
    }

    @Test func dropStopsAtFirstNonHelper() {
        let chain = [node("kubelogin", pid: 10), node("zsh", pid: 9), node("kubelogin", pid: 8)]
        let paths: [pid_t: String] = [10: "/x/kubelogin", 9: "/bin/zsh", 8: "/x/kubelogin"]
        let rest = OidcLogin.dropHelpers(chain: chain) { paths[$0] }
        #expect(rest.map(\.pid) == [9, 8])
    }

    @Test func dropCanEmptyTheChain() {
        let chain = [node("kubelogin", pid: 10)]
        #expect(OidcLogin.dropHelpers(chain: chain) { _ in "/x/kubelogin" }.isEmpty)
    }

    @Test func dropKeepsNodesWithUnknownPath() {
        let chain = [node("kubelogin", pid: 10)]
        #expect(OidcLogin.dropHelpers(chain: chain) { _ in nil }.map(\.pid) == [10])
    }

    @Test func parseReadsPIDAndFrame() {
        let req = OidcLogin.parse(userInfo: ["requesterPID": "4242", "frame": "10,20,800,600"])
        #expect(req == OidcLogin.Request(requesterPID: 4242, frame: CGRect(x: 10, y: 20, width: 800, height: 600)))
    }

    @Test func parseWithoutFrame() {
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "4242"])?.frame == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "4242", "frame": "garbage"])?.frame == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "4242", "frame": "0,0,0,600"])?.frame == nil)
    }

    @Test func parseRejectsBadPID() {
        #expect(OidcLogin.parse(userInfo: nil) == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "abc"]) == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "1"]) == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": 4242]) == nil)
    }

    private func summary(chain: [ProcessNode], argv: [String], appName: String? = nil) -> RequestSummary {
        makeRequestSummary(
            chain: chain, triggerArgv: argv,
            tabTitle: nil, claudeSession: nil, terminalBundleID: nil, cwd: nil,
            rules: OidcLogin.rules, appName: appName
        )
    }

    @Test func kubectlRuleRendersCommand() {
        let s = summary(chain: [node("kubectl", pid: 9)],
                        argv: ["/opt/homebrew/bin/kubectl", "get", "pods", "-n", "demo"])
        #expect(s.title.hasSuffix("needs a Kubernetes login for ‘kubectl get pods -n demo’"))
        #expect(s.kind == .oidcLogin)
        #expect(!s.isWarning)
    }

    @Test func emptyChainNamesTheApp() {
        let s = summary(chain: [], argv: [], appName: "Visual Studio Code")
        #expect(s.title == "Visual Studio Code needs an OIDC login")
        #expect(s.kind == .oidcLogin)
    }

    @Test func emptyChainWithoutApp() {
        #expect(summary(chain: [], argv: []).title == "An unknown process needs an OIDC login")
    }

    @Test func otherTriggerUsesFallback() {
        let s = summary(chain: [node("helm", pid: 9)], argv: ["helm", "list"])
        #expect(s.title.hasSuffix("needs an OIDC login (via ‘helm’)"))
        #expect(s.kind == .oidcLogin)
    }

    @Test func kubectlWithoutArgvUsesFallback() {
        let s = summary(chain: [node("kubectl", pid: 9)], argv: [])
        #expect(s.title.hasSuffix("needs an OIDC login (via ‘kubectl’)"))
    }

    @Test func rulesAreThreeAndParse() throws {
        #expect(OidcLogin.rules.count == 3)
        for rule in OidcLogin.rules {
            _ = try PredicateParser.parse(rule.predicate)
            #expect(rule.kind == .oidcLogin)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OidcLoginTests`
Expected: compile failure, `cannot find 'OidcLogin'`.

- [ ] **Step 3: Implement**

`Sources/OpWhoLib/OidcLogin.swift`:

```swift
import Foundation

/// Protocol and pure logic for OIDC login requests posted by `oidc-browser`
/// (sunstoneinstitute/cli-tools). See
/// docs/superpowers/specs/2026-11-23-oidc-login-overlay-design.md.
public enum OidcLogin {
    public static let notificationName = Notification.Name("com.stigbakken.op-who.oidc-login")

    /// Executable basenames of kubelogin.
    static let helperNames: Set<String> = ["kubectl-oidc_login", "kubelogin"]

    /// `executablePath` must come from `ProcessTree.kernelExecutablePath`
    /// (`proc_pidpath`). argv[0] and the KERN_PROCARGS2 exec path can be
    /// rewritten by the process; the kinfo name is truncated to 16 chars.
    public static func isHelper(executablePath: String) -> Bool {
        helperNames.contains((executablePath as NSString).lastPathComponent)
    }

    /// Drops leading kubelogin nodes so the first node is the command that
    /// needed the login. Returns an empty chain when an app ran kubelogin
    /// itself. `pathFor` is the kernel executable path lookup (injected).
    static func dropHelpers(chain: [ProcessNode], pathFor: (pid_t) -> String?) -> [ProcessNode] {
        var rest = chain[...]
        while let first = rest.first,
              let path = pathFor(first.pid), isHelper(executablePath: path) {
            rest = rest.dropFirst()
        }
        return Array(rest)
    }

    public struct Request: Equatable {
        public let requesterPID: pid_t
        /// Browser window frame in CG global coordinates (top-left origin).
        public let frame: CGRect?
    }

    static func parse(userInfo: [AnyHashable: Any]?) -> Request? {
        guard let pidString = userInfo?["requesterPID"] as? String,
              let pid = pid_t(pidString), pid > 1 else { return nil }
        var frame: CGRect? = nil
        if let f = userInfo?["frame"] as? String {
            let n = f.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            if n.count == 4, n[2] > 0, n[3] > 0 {
                frame = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
            }
        }
        return Request(requesterPID: pid, frame: frame)
    }

    /// Fixed ruleset for OIDC entries. Not user-editable. Order matters:
    /// `{process}` renders "?" on an empty chain, so the empty-chain rule
    /// must precede the catch-all.
    public static let rules: [RequestRule] = [
        RequestRule(
            name: "kubectl login",
            predicate: #"triggerName == "kubectl""#,
            template: "needs a Kubernetes login for ‘{argv}’",
            kind: .oidcLogin
        ),
        RequestRule(
            name: "OIDC login (app)",
            predicate: #"triggerName == """#,
            template: "needs an OIDC login",
            kind: .oidcLogin
        ),
        RequestRule(
            name: "OIDC login",
            predicate: "TRUEPREDICATE",
            template: "needs an OIDC login (via ‘{process}’)",
            kind: .oidcLogin
        ),
    ]
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter OidcLoginTests`
Expected: PASS. If a rule test fails only on the text before the suffix, the template is wrong. Fix the template, not the test.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/OidcLogin.swift Tests/OidcLoginTests.swift
git commit -m "Add OIDC login request parsing, helper detection and rules"
```

---

### Task 5: Render OIDC entries in the overlay (op-who)

The panel shows no row for `summary.title` today; the action row shows the trigger's command line. For OIDC entries the action row shows the summary title (the sentence from `OidcLogin.rules`, e.g. "Claude Code in cmux workspace ‘infra’ needs a Kubernetes login for ‘kubectl get pods -n demo’"), and the lead row names the requesting app when it is not a terminal. 1Password entries render exactly as before.

**Files:**
- Modify: `Sources/OpWhoLib/PopupLayout.swift` (`bodyRows`)
- Modify: `Sources/OpWhoLib/OverlayPanel.swift` (`makeTerminalRow`, `makeProcessTreeLabel`, two new static helpers)
- Test: `Tests/OidcOverlayRenderingTests.swift`

**Interfaces:**
- Consumes: `ProcessEntry.source/appBundleID/appPID/appName` (Task 3); `RequestKind.oidcLogin` (Task 1).
- Produces:
  - `OverlayPanel.leadRowApp(entry:) -> (bundleID: String?, name: String)` (static, pure)
  - `OverlayPanel.treeRoot(entry:) -> (name: String?, pid: pid_t?)` (static, pure)

- [ ] **Step 1: Write the failing tests**

`Tests/OidcOverlayRenderingTests.swift`:

```swift
import Foundation
import Testing
@testable import OpWhoLib

@Suite("OIDC overlay rendering")
struct OidcOverlayRenderingTests {
    private func node(_ name: String, pid: pid_t = 100) -> ProcessNode {
        ProcessNode(pid: pid, ppid: 1, name: name, tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: false)
    }

    private func entry(
        source: RequestSource,
        chain: [ProcessNode],
        argv: [String] = [],
        title: String = "",
        kind: RequestKind = .oidcLogin,
        terminalBundleID: String? = nil,
        terminalPID: pid_t? = nil,
        appBundleID: String? = nil,
        appPID: pid_t? = nil,
        appName: String? = nil
    ) -> OverlayPanel.ProcessEntry {
        OverlayPanel.ProcessEntry(
            pid: 1, chain: chain, triggerArgv: argv, tty: nil,
            tabTitle: nil, tabShortcut: nil, claudeSession: nil, claudeContext: nil,
            scriptInfo: nil, terminalBundleID: terminalBundleID, terminalPID: terminalPID,
            cwd: nil, triggerCwd: nil, cmuxWorkspaceID: nil, cmuxTabID: nil,
            cmuxSurface: nil, pluginUpdate: nil,
            summary: RequestSummary(kind: kind, title: title, subtitle: nil, isWarning: false),
            matchedRuleID: nil, matchedRuleName: nil, matchedBuiltInID: nil,
            source: source, appBundleID: appBundleID, appPID: appPID, appName: appName
        )
    }

    @Test func oidcActionRowShowsSummaryTitle() {
        let e = entry(source: .oidcLogin, chain: [node("kubectl"), node("zsh")],
                      argv: ["kubectl", "get", "pods"],
                      title: "Your zsh shell needs a Kubernetes login for ‘kubectl get pods’")
        let rows = bodyRows(entry: e, dense: false)
        #expect(rows[0].label == nil)
        #expect(rows[0].value == "Your zsh shell needs a Kubernetes login for ‘kubectl get pods’")
        #expect(rows[0].style == .action(.oidcLogin))
        #expect(rows[1].label == "who")
        #expect(rows[1].value == "zsh")
    }

    @Test func onePasswordActionRowStillShowsCommand() {
        let e = entry(source: .onePassword, chain: [node("op"), node("zsh")],
                      argv: ["op", "read", "op://v/x"], title: "ignored", kind: .onePasswordCLI)
        #expect(bodyRows(entry: e, dense: false)[0].value == "op read op://v/x")
    }

    @Test func oidcEmptyChainWhoIsTheApp() {
        let e = entry(source: .oidcLogin, chain: [], title: "Visual Studio Code needs an OIDC login",
                      appBundleID: "com.microsoft.VSCode", appPID: 50, appName: "Visual Studio Code")
        let rows = bodyRows(entry: e, dense: false)
        #expect(rows.map(\.label) == [nil, "who"])
        #expect(rows[1].value == "Visual Studio Code")
    }

    @Test func oidcEmptyChainWithoutApp() {
        let e = entry(source: .oidcLogin, chain: [], title: "An unknown process needs an OIDC login")
        #expect(bodyRows(entry: e, dense: false)[1].value == "unknown")
    }

    @Test func leadRowPrefersTerminal() {
        let e = entry(source: .oidcLogin, chain: [node("kubectl")],
                      terminalBundleID: "com.googlecode.iterm2",
                      appBundleID: "com.googlecode.iterm2", appName: "iTerm")
        let app = OverlayPanel.leadRowApp(entry: e)
        #expect(app.bundleID == "com.googlecode.iterm2")
        #expect(app.name == "iTerm")
    }

    @Test func leadRowNamesNonTerminalAppForOidc() {
        let e = entry(source: .oidcLogin, chain: [],
                      appBundleID: "com.microsoft.VSCode", appName: "Visual Studio Code")
        let app = OverlayPanel.leadRowApp(entry: e)
        #expect(app.bundleID == "com.microsoft.VSCode")
        #expect(app.name == "Visual Studio Code")
        #expect(OverlayPanel.terminalRowText(entry: e, termName: app.name) == "Visual Studio Code")
    }

    @Test func leadRowWithoutAppForOidc() {
        let app = OverlayPanel.leadRowApp(entry: entry(source: .oidcLogin, chain: []))
        #expect(app.bundleID == nil)
        #expect(app.name == "Unknown app")
    }

    @Test func leadRowUnchangedForOnePassword() {
        let e = entry(source: .onePassword, chain: [node("op")], kind: .onePasswordCLI,
                      appBundleID: "com.microsoft.VSCode", appName: "Visual Studio Code")
        let app = OverlayPanel.leadRowApp(entry: e)
        #expect(app.bundleID == nil)
        #expect(app.name == "Unknown terminal")
    }

    @Test func treeRootIsTheAppForOidc() {
        let e = entry(source: .oidcLogin, chain: [],
                      appBundleID: "com.microsoft.VSCode", appPID: 50, appName: "Visual Studio Code")
        let root = OverlayPanel.treeRoot(entry: e)
        #expect(root.name == "Visual Studio Code")
        #expect(root.pid == 50)
    }

    @Test func treeRootUnchangedForOnePassword() {
        let e = entry(source: .onePassword, chain: [node("op")], kind: .onePasswordCLI,
                      terminalBundleID: "com.googlecode.iterm2", terminalPID: 40,
                      appBundleID: "com.googlecode.iterm2", appPID: 40)
        let root = OverlayPanel.treeRoot(entry: e)
        #expect(root.name == "iTerm")
        #expect(root.pid == 40)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OidcOverlayRenderingTests`
Expected: compile failure, `type 'OverlayPanel' has no member 'leadRowApp'`.

- [ ] **Step 3: `bodyRows` (PopupLayout.swift, keep it free of AppKit)**

Replace the action-text block:

```swift
    let actionText: String
    if entry.source == .oidcLogin {
        // The OIDC sentence comes from OidcLogin.rules and already names the
        // actor and the command.
        actionText = entry.summary.title
    } else if let update = entry.pluginUpdate {
        actionText = "plugin update check from \(update.remoteURL)"
    } else {
        actionText = operationDisplay(argv: entry.triggerArgv, chain: entry.chain, cwd: nil)
    }
```

Replace the who block (from `let driver = …` up to and including the `if entry.claudeSession == nil, let s = entry.scriptInfo { … }` statement) with:

```swift
    let driver = driverDescription(chain: entry.chain, claudeSession: entry.claudeSession)
    var whoValue = driver.text
    if entry.source == .oidcLogin, entry.chain.isEmpty {
        // An app ran kubelogin itself: the app is who asked.
        whoValue = entry.appName ?? "unknown"
    } else if entry.claudeSession == nil, let s = entry.scriptInfo {
        // Show the command name too — for a plain invoked command the name is
        // the leading argv token (`git commit -m msg`); scriptName alone would
        // drop it. For an interpreter it prepends `python app.py` etc.
        whoValue += " \u{00B7} \(s.interpreter) \(s.scriptName)"
    }
```

Leave the `rows.append` lines and the rest of the function unchanged.

- [ ] **Step 4: Lead row and process tree (OverlayPanel.swift)**

Add next to `terminalRowParts`:

```swift
    /// App shown in row 1 (icon + name). A known terminal always wins, so a
    /// terminal request shows the app and its tab. Otherwise OIDC entries
    /// show the requesting app; 1Password entries keep "Unknown terminal"
    /// (the 1Password dialog already names the app).
    static func leadRowApp(entry: ProcessEntry) -> (bundleID: String?, name: String) {
        if let terminal = humanTerminalName(bundleID: entry.terminalBundleID) {
            return (entry.terminalBundleID, terminal)
        }
        guard entry.source == .oidcLogin else { return (nil, "Unknown terminal") }
        return (entry.appBundleID, entry.appName ?? "Unknown app")
    }

    /// Root node of the details process tree.
    static func treeRoot(entry: ProcessEntry) -> (name: String?, pid: pid_t?) {
        if entry.source == .oidcLogin, let name = entry.appName {
            return (name, entry.appPID)
        }
        return (humanTerminalName(bundleID: entry.terminalBundleID), entry.terminalPID)
    }
```

In `makeTerminalRow`, replace the two lines

```swift
        let bundleID = entry.terminalBundleID
        let termName = humanTerminalName(bundleID: bundleID) ?? "Unknown terminal"
```

with

```swift
        let app = Self.leadRowApp(entry: entry)
        let bundleID = app.bundleID
        let termName = app.name
```

In `makeProcessTreeLabel`, replace

```swift
        let appName = humanTerminalName(bundleID: entry.terminalBundleID)
        let nodes = processTreeNodes(
            appName: appName, appPID: entry.terminalPID, chain: entry.chain
        )
```

with

```swift
        let root = Self.treeRoot(entry: entry)
        let nodes = processTreeNodes(appName: root.name, appPID: root.pid, chain: entry.chain)
```

- [ ] **Step 5: Run all tests**

Run: `swift test`
Expected: all PASS, including the existing `bodyRows`, `OverlayPanel.terminalRowText` and `BodyTableRender` suites unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpWhoLib/PopupLayout.swift Sources/OpWhoLib/OverlayPanel.swift \
  Tests/OidcOverlayRenderingTests.swift
git commit -m "Render OIDC entries: login sentence in the action row, requesting app in the lead row"
```

---

### Task 6: Browser-window placement (op-who)

OIDC overlays sit inside the browser window near its bottom edge and never over the address bar. 1Password placement must not change, so the new placement is opt-in.

**Files:**
- Modify: `Sources/OpWhoLib/OverlayPanel.swift` (`show(entries:near:)`, new nested types and static functions)
- Test: `Tests/OverlayPlacementTests.swift`

**Interfaces:**
- Produces:
  - `public enum OverlayPanel.Placement { case aboveWindow, insideBrowserWindow }`
  - `public func show(entries: [ProcessEntry], near windowFrame: CGRect?, placement: Placement = .aboveWindow)` (replaces the two-parameter `show`; existing callers compile unchanged)
  - `struct OverlayPanel.ScreenGeometry { let frame: NSRect; let visibleFrame: NSRect }`
  - `static func browserOverlayOrigin(windowFrame: CGRect, panelSize: NSSize, primaryHeight: CGFloat, screens: [ScreenGeometry]) -> NSPoint`
  - `static func centeredOrigin(panelSize: NSSize, in rect: NSRect) -> NSPoint`

Coordinates: `windowFrame` is CG global (origin top-left of the primary display, y down). The result is AppKit (origin bottom-left of the primary display, y up). `primaryHeight` is the primary display's height, as `show` already computes it.

- [ ] **Step 1: Write the failing tests**

`Tests/OverlayPlacementTests.swift`:

```swift
import AppKit
import Testing
@testable import OpWhoLib

@Suite("OverlayPanel browser placement")
struct OverlayPlacementTests {
    private let size = NSSize(width: 400, height: 200)
    // Primary display 1600x1000 with a 25 pt menu bar.
    private let primary = OverlayPanel.ScreenGeometry(
        frame: NSRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 975))
    // Second display to the right of the primary.
    private let secondary = OverlayPanel.ScreenGeometry(
        frame: NSRect(x: 1600, y: 0, width: 1200, height: 1000),
        visibleFrame: NSRect(x: 1600, y: 0, width: 1200, height: 975))

    private func origin(_ window: CGRect, screens: [OverlayPanel.ScreenGeometry]? = nil) -> NSPoint {
        OverlayPanel.browserOverlayOrigin(
            windowFrame: window, panelSize: size, primaryHeight: 1000,
            screens: screens ?? [primary])
    }

    @Test func tallWindowCentersHorizontallySixteenAboveBottom() {
        // AppKit window: x 100…1100, y 150…950.
        #expect(origin(CGRect(x: 100, y: 50, width: 1000, height: 800)) == NSPoint(x: 400, y: 166))
    }

    @Test func windowExactlyTallEnoughKeepsOverlayInside() {
        // height 336 = 16 + 200 + 120. AppKit window y 564…900.
        #expect(origin(CGRect(x: 100, y: 100, width: 1000, height: 336)) == NSPoint(x: 400, y: 580))
    }

    @Test func shortWindowPutsOverlayDirectlyBelow() {
        // AppKit window y 600…900: 16 + 200 would reach into the top 120 pt.
        #expect(origin(CGRect(x: 100, y: 100, width: 1000, height: 300)) == NSPoint(x: 400, y: 400))
    }

    @Test func belowWindowIsClampedToVisibleFrame() {
        // AppKit window y 0…300, below would be y -200.
        #expect(origin(CGRect(x: 100, y: 700, width: 1000, height: 300)) == NSPoint(x: 400, y: 0))
    }

    @Test func horizontalClampLeft() {
        #expect(origin(CGRect(x: -100, y: 50, width: 300, height: 800)) == NSPoint(x: 0, y: 166))
    }

    @Test func usesTheScreenContainingTheWindow() {
        let screens = [primary, secondary]
        #expect(origin(CGRect(x: 1700, y: 50, width: 1000, height: 800), screens: screens)
                == NSPoint(x: 2000, y: 166))
        // Window hangs off the right edge of the secondary display.
        #expect(origin(CGRect(x: 2500, y: 50, width: 600, height: 800), screens: screens)
                == NSPoint(x: 2400, y: 166))
    }

    @Test func noScreensMeansNoClamp() {
        #expect(origin(CGRect(x: 100, y: 700, width: 1000, height: 300), screens: [])
                == NSPoint(x: 400, y: -200))
    }

    @Test func centered() {
        #expect(OverlayPanel.centeredOrigin(panelSize: size, in: primary.visibleFrame)
                == NSPoint(x: 600, y: 387.5))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OverlayPlacementTests`
Expected: compile failure, `type 'OverlayPanel' has no member 'ScreenGeometry'`.

- [ ] **Step 3: Add the pure placement functions**

Add to `OverlayPanel`, directly above `public func show(`:

```swift
    /// Where `show` puts the panel relative to the window frame it is given.
    public enum Placement {
        /// 8 pt above the window (1Password dialogs).
        case aboveWindow
        /// Inside the window near its bottom edge (OIDC login pages).
        case insideBrowserWindow
    }

    /// A screen's frames in AppKit coordinates.
    struct ScreenGeometry {
        let frame: NSRect
        let visibleFrame: NSRect
    }

    /// Gap between the overlay's bottom edge and the browser window's.
    static let browserBottomInset: CGFloat = 16
    /// Top strip of a browser window (tabs + address bar) the overlay never
    /// covers: the URL is what the user must check on a login page.
    static let browserTopReserve: CGFloat = 120

    /// Panel origin (AppKit coordinates) for a browser window given in CG
    /// global coordinates. Centered horizontally, bottom edge
    /// `browserBottomInset` above the window's bottom edge; directly below
    /// the window when that would reach into the top `browserTopReserve`.
    /// The result is clamped to the visible frame of the screen that
    /// contains most of the window.
    static func browserOverlayOrigin(
        windowFrame: CGRect,
        panelSize: NSSize,
        primaryHeight: CGFloat,
        screens: [ScreenGeometry]
    ) -> NSPoint {
        let window = NSRect(
            x: windowFrame.origin.x,
            y: primaryHeight - (windowFrame.origin.y + windowFrame.height),
            width: windowFrame.width,
            height: windowFrame.height
        )
        var x = window.midX - panelSize.width / 2
        var y = window.minY + browserBottomInset
        if y + panelSize.height > window.maxY - browserTopReserve {
            y = window.minY - panelSize.height
        }

        func overlap(_ screen: ScreenGeometry) -> CGFloat {
            let r = screen.frame.intersection(window)
            return r.isNull ? 0 : r.width * r.height
        }
        var best: ScreenGeometry? = screens.first
        for screen in screens.dropFirst() where overlap(screen) > overlap(best!) {
            best = screen
        }
        if let visible = best?.visibleFrame {
            x = max(visible.minX, min(x, visible.maxX - panelSize.width))
            y = max(visible.minY, min(y, visible.maxY - panelSize.height))
        }
        return NSPoint(x: x, y: y)
    }

    static func centeredOrigin(panelSize: NSSize, in rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX - panelSize.width / 2, y: rect.midY - panelSize.height / 2)
    }
```

- [ ] **Step 4: Use them from `show`**

Change the signature to:

```swift
    public func show(
        entries: [ProcessEntry],
        near windowFrame: CGRect?,
        placement: Placement = .aboveWindow
    ) {
```

Replace the block from `let origin: NSPoint` through the line before `panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)` with:

```swift
        // AX and CG use global coordinates with the origin at the top-left of
        // the primary display, y growing down. AppKit uses the bottom-left of
        // the primary display, y growing up. The flip MUST use the primary
        // display's height — not NSScreen.main, which tracks keyboard focus
        // and can be a non-primary screen on multi-monitor setups.
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.screens.first
            ?? NSScreen.main)?.frame.height ?? 0

        let origin: NSPoint
        switch (placement, windowFrame) {
        case (.insideBrowserWindow, let frame?):
            origin = Self.browserOverlayOrigin(
                windowFrame: frame,
                panelSize: panelSize,
                primaryHeight: primaryHeight,
                screens: NSScreen.screens.map {
                    ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
                }
            )
        case (.insideBrowserWindow, nil):
            origin = NSScreen.main.map {
                Self.centeredOrigin(panelSize: panelSize, in: $0.visibleFrame)
            } ?? NSPoint(x: 200, y: 400)
        case (.aboveWindow, let frame?):
            let axBottom = frame.origin.y + frame.size.height
            let appKitY = primaryHeight - axBottom
            origin = NSPoint(
                x: frame.origin.x + (frame.width - panelSize.width) / 2,
                y: appKitY + frame.height + 8
            )
        case (.aboveWindow, nil):
            if let screen = NSScreen.main {
                origin = NSPoint(
                    x: screen.frame.midX - panelSize.width / 2,
                    y: screen.frame.midY + 100
                )
            } else {
                origin = NSPoint(x: 200, y: 400)
            }
        }
```

The two `.aboveWindow` cases are the existing math, unchanged. Do not add clamping to them.

- [ ] **Step 5: Run all tests**

Run: `swift build && swift test`
Expected: all PASS. `OnePasswordWatcher` and `AppearancePane` call `show(entries:near:)` without `placement` and compile unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpWhoLib/OverlayPanel.swift Tests/OverlayPlacementTests.swift
git commit -m "Add browser-window placement for the overlay"
```

---

### Task 7: `OidcLoginWatcher` and app wiring (op-who)

**Files:**
- Create: `Sources/OpWhoLib/OidcLoginWatcher.swift`
- Modify: `Sources/op-who/main.swift` (property next to `var watcher: OnePasswordWatcher!` at line 7; construction next to `watcher = OnePasswordWatcher(recentStore: recentStore)` at ~line 96)

**Interfaces:**
- Consumes: `OidcLogin.notificationName/parse/isHelper(executablePath:)/dropHelpers(chain:pathFor:)/rules` (Task 4); `ProcessTree.kernelExecutablePath(pid:)` (Task 2); `TriggerEntryBuilder.makeEntry(foldedChain:fallbackNode:chainResult:triggerArgv:rules:source:)` (Task 3); `OverlayPanel.show(entries:near:placement:)` with `.insideBrowserWindow` (Task 6); existing `redactArgv`, `ProcessTree.buildChain/processArgv`, `AppSettings`, `PopupStyle`, `PopupSound`, `Log.watcher`.
- Produces: `public final class OidcLoginWatcher { public init() }`

Rules this watcher must keep:
- It owns one `OverlayPanel` for its whole life and reuses it. It never creates a second one.
- A notification for the tracked PID is ignored. A valid notification for a different PID replaces the panel content and resets tracking to the new PID.
- The 1Password short-chain filter is not applied.
- Nothing is written to the recent-requests ring buffer.

- [ ] **Step 1: Implement the watcher**

`Sources/OpWhoLib/OidcLoginWatcher.swift`:

```swift
import AppKit
import Darwin
import os

/// Shows the overlay for OIDC logins announced by `oidc-browser`.
/// The notification is unauthenticated: only the PID (and an optional
/// window frame, used for placement) is taken from it, the PID must be a
/// kubelogin process, and all displayed text comes from the live process tree.
public final class OidcLoginWatcher {
    private var observer: NSObjectProtocol?
    /// The only OIDC panel. Reused for every request.
    private let overlayPanel = OverlayPanel()
    private var trackedPID: pid_t?
    private var pollTimer: Timer?

    public init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: OidcLogin.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            guard let request = OidcLogin.parse(userInfo: note.userInfo) else {
                Log.watcher.info("oidc: ignored malformed notification")
                return
            }
            self?.handle(request)
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        pollTimer?.invalidate()
    }

    private func handle(_ request: OidcLogin.Request) {
        let pid = request.requesterPID
        if trackedPID == pid { return }

        guard let path = ProcessTree.kernelExecutablePath(pid: pid),
              OidcLogin.isHelper(executablePath: path) else {
            Log.watcher.info("oidc: ignored pid=\(pid, privacy: .public), not kubelogin")
            return
        }
        let result = ProcessTree.buildChain(from: pid)
        guard let requester = result.chain.first, requester.pid == pid else {
            Log.watcher.info("oidc: ignored pid=\(pid, privacy: .public), no process chain")
            return
        }
        // Empty when an app (IDE, Lens) ran kubelogin itself.
        let chain = OidcLogin.dropHelpers(chain: result.chain) {
            ProcessTree.kernelExecutablePath(pid: $0)
        }
        let triggerArgv = chain.first.map { redactArgv(ProcessTree.processArgv(pid: $0.pid)) } ?? []
        let entry = TriggerEntryBuilder.makeEntry(
            foldedChain: chain,
            fallbackNode: requester,
            chainResult: result,
            triggerArgv: triggerArgv,
            rules: OidcLogin.rules,
            source: .oidcLogin
        )
        Log.watcher.info("oidc: showing pid=\(pid, privacy: .public) app=\(result.appBundleID ?? "<none>", privacy: .public) chain=\(chain.map(\.name).joined(separator: ","), privacy: .public)")

        let settings = AppSettings()
        overlayPanel.densePopup = settings.densePopup
        overlayPanel.style = PopupStyle(settings: settings)
        overlayPanel.show(entries: [entry], near: request.frame, placement: .insideBrowserWindow)
        PopupSound.resolve(id: PopupSound.effectiveID(
            ruleSoundID: nil, globalSoundID: settings.popupSoundID
        )).play()

        trackedPID = pid
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.dismissIfRequesterExited()
        }
    }

    /// kubelogin exits when the login completes or times out.
    private func dismissIfRequesterExited() {
        guard let pid = trackedPID, kill(pid, 0) != 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        trackedPID = nil
        overlayPanel.dismiss()
    }
}
```

- [ ] **Step 2: Wire into the app**

In `Sources/op-who/main.swift`, next to `var watcher: OnePasswordWatcher!` add `var oidcWatcher: OidcLoginWatcher!`, and directly after `watcher = OnePasswordWatcher(recentStore: recentStore)` add:

```swift
        oidcWatcher = OidcLoginWatcher()
```

- [ ] **Step 3: Build and run tests**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 4: Manual check with a real kubelogin process**

1. Build and launch the dev app (`scripts/bundle.sh`, then open the built `.app`; see `CONTRIBUTORS.md`).
2. In a terminal, start kubelogin so it waits for a callback without opening a browser:
   ```bash
   kubectl oidc-login get-token --oidc-issuer-url=https://auth.sunstoneinstitute.ai/realms/sunstone \
     --oidc-client-id=k8s-dev --browser-command=/usr/bin/true \
     --listen-address=127.0.0.1:8124 --token-cache-dir="$(mktemp -d)" --authentication-timeout-sec=30 &
   ```
3. Post the notification for it from a second terminal:
   ```bash
   PID=$(pgrep -f 'kubectl-oidc_login get-token.*8124')
   osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('com.stigbakken.op-who.oidc-login', \$(), \$({requesterPID: '$PID', frame: '200,200,1000,700'}), true)"
   ```
4. Expected: one overlay appears inside the rectangle x 200…1200, y 200…900 (top-left coordinates), centered horizontally, its bottom edge 16 pt above y 900. Row 1 shows the terminal's icon and tab. The action row reads "… needs an OIDC login (via ‘zsh’)" (kubectl `exec`s the plugin, so the trigger here is the interactive shell) in the `oidcLogin` color. It disappears within ~1 s of kubelogin timing out after 30 s.
5. While it is showing, post the same notification again. Expected: nothing changes, the elapsed timer keeps counting.
6. Restart step 2 (new PID) and post with `frame: '200,200,1000,250'`. Expected: the overlay sits directly below y 450.
7. Post with `requesterPID` set to the PID of your shell (`$$`). Expected: no overlay, and `log stream --predicate 'subsystem == "com.stigbakken.op-who"'` shows `oidc: ignored pid=..., not kubelogin`.
8. Trigger a 1Password approval (`op whoami` or an SSH key use). Expected: the 1Password overlay looks and sits exactly as before this change.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/OidcLoginWatcher.swift Sources/op-who/main.swift
git commit -m "Show the overlay for OIDC logins announced by oidc-browser"
```

---

### Task 8: Docs (op-who)

Describe current state only. No changelog-style narration inside `docs/architecture.md`.

**Files:**
- Modify: `docs/architecture.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: `docs/architecture.md`**

1. §2 module list. In the `main.swift` bullet, change "and `OnePasswordWatcher`" to "`OnePasswordWatcher`, and `OidcLoginWatcher`". Add these bullets after the `OnePasswordWatcher` bullet:

```markdown
- **`OidcLoginWatcher` / `OidcLogin`** — shows the overlay for kubelogin OIDC logins announced by `oidc-browser` over a distributed notification. `OidcLogin` holds the pure parts: notification parsing, kubelogin-helper detection, and the fixed ruleset (see §4.15).
- **`TriggerEntryBuilder`** — builds one `ProcessEntry` from a chain: terminal tab, Claude session, cmux, git context, rule evaluation. Shared by both watchers so both overlays carry the same context.
```

2. §2 mermaid diagram. Inside `subgraph lib[OpWhoLib]` add:

```
        oidc["OidcLoginWatcher + OidcLogin<br/>distributed notification"]
        builder["TriggerEntryBuilder<br/>entry context"]
```

and add these edges next to the other `watcher -->` edges:

```
    main --> oidc
    watcher --> builder
    oidc --> builder
    oidc --> ptree
    oidc --> overlay
    builder --> rules
    builder --> summary
```

3. §4.3, "Candidate assembly" bullet: replace everything after "drop non-network `git` triggers," with "then hand the chain to `TriggerEntryBuilder.makeEntry`, which looks up terminal tab info, Claude session/context, the trigger CWD and `bestCWD`, a Claude plugin update, cmux workspace/surface info, runs the matcher engine, and returns a `ProcessEntry` carrying the matched rule's id/name/builtInID and the rendered summary."

4. §4.4, after the ranking list, add: "`RequestKind.oidcLogin` never reaches ranking (OIDC entries do not go through `selectBestCandidate`); `kindRank` lists it only to stay exhaustive."

5. §4.5, add two bullets to "Key responsibilities":

```markdown
- **Requesting app** — `buildChain` records the app it stopped at as `ChainResult.appBundleID` / `appPID`, for every app, not only terminals. A terminal helper counts as its terminal app. When the app's bundle is nested inside another `.app` (Electron and Chromium helpers), the outermost bundle is reported (`outermostApp`). `appDisplayName` turns a bundle ID into the name shown in the overlay.
- **Kernel executable path** — `kernelExecutablePath(pid:)` wraps `proc_pidpath`. It is the only identity used for the kubelogin trust check, because argv[0] and the `KERN_PROCARGS2` exec path live in process memory and the `kinfo_proc` name is truncated to 16 characters.
```

6. §4.8, add a bullet: "- For an empty chain (OIDC login started by an app) the actor is the `appName` passed by `TriggerEntryBuilder`, or `An unknown process` without one. 1Password requests never pass `appName`."

7. §4.11. Replace the last paragraph ("The panel is positioned just above the 1Password dialog …") with:

```markdown
Placement is chosen by the caller through `show(entries:near:placement:)`. Both modes flip AX/CG top-left coordinates to AppKit using the *primary* display's height (not `NSScreen.main`, which can be a non-primary screen).

- `.aboveWindow` (1Password): 8 pt above the dialog, centered on it. Without a frame, slightly above screen center.
- `.insideBrowserWindow` (OIDC): centered horizontally on the browser window, bottom edge 16 pt above the window's bottom edge, never covering the top 120 pt (tabs and address bar). A window too short for that gets the overlay directly below it. The result is clamped to the visible frame of the screen containing the window. Without a frame, centered on the main screen. The math is the pure `browserOverlayOrigin`.

OIDC entries (`ProcessEntry.source == .oidcLogin`) differ in three places: the action row shows the summary title in the `oidcLogin` color role, row 1 shows the requesting app's icon and name when the app is not a terminal, and the details tree is rooted at that app.
```

8. Add a new section after §4.14:

```markdown
### 4.15 `OidcLoginWatcher` and `OidcLogin` — OIDC login overlay

Design: [superpowers/specs/2026-11-23-oidc-login-overlay-design.md](superpowers/specs/2026-11-23-oidc-login-overlay-design.md).

`oidc-browser` (sunstoneinstitute/cli-tools), kubelogin's `--browser-command`, posts the distributed notification `com.stigbakken.op-who.oidc-login` with `requesterPID` (kubelogin's PID) and an optional `frame` (`"x,y,w,h"`, CG global coordinates) of the browser window.

- **Trust.** Distributed notifications do not identify the sender. The watcher takes only the PID and the frame from the message, ignores the message unless the PID's `proc_pidpath` basename is `kubectl-oidc_login` or `kubelogin`, and derives all displayed text from the live process tree. The frame only affects placement. A local process running as the user can still stage a fake kubelogin, so the overlay is context for a login the user started, not proof that a login page is legitimate.
- **Chain.** `buildChain(from: requesterPID)`, then `OidcLogin.dropHelpers` removes the leading kubelogin nodes. The chain is empty when an app ran kubelogin itself; `TriggerEntryBuilder` then reads environment, TTY and CWD from the kubelogin process and the app becomes the actor. The 1Password short-chain filter is not applied.
- **Rules.** `OidcLogin.rules` is fixed and not user-editable: `kubectl` → "needs a Kubernetes login for ‘{argv}’", empty chain → "needs an OIDC login", anything else → "needs an OIDC login (via ‘{process}’)". All use `RequestKind.oidcLogin`, which the Rules pane does not offer. OIDC requests are not recorded in the recent-requests ring buffer.
- **Panel.** The watcher owns one `OverlayPanel` and reuses it, so at most one OIDC panel exists, next to at most one 1Password panel. A notification for the tracked PID is ignored; one for a different PID replaces the content and resets tracking.
- **Dismissal.** `kill(requesterPID, 0)` every 500 ms. kubelogin exits when the login completes or times out.
```

9. §5 flowchart: change the `recordTerm` node label to `record appBundleID + appPID (outermost bundle)<br/>if bundleID is a terminal:<br/>record terminalBundleID + PID` and the `recordHelper` node label to `record terminalBundleID + PID<br/>and appBundleID + appPID`.

10. §5 "Stops at app boundaries" bullet: replace its last sentence ("As a side effect we capture …") with "The app is recorded as `appBundleID` / `appPID` (outermost bundle when nested), and a terminal additionally as `terminalBundleID` / `terminalPID` for `TerminalHelper`. The OIDC overlay names the app, since a browser window does not."

11. §6, add two bullets:

```markdown
- **Identify kubelogin by `proc_pidpath`, and take only a PID from the OIDC notification.** Rationale: the notification is unauthenticated. The kernel's record of the executed file cannot be rewritten by the process, unlike argv[0] and the `KERN_PROCARGS2` exec path, and is not truncated like the `kinfo_proc` name. Deriving every displayed string from the process tree keeps a bare message from naming an arbitrary process.
- **Fixed OIDC rules and a separate panel per watcher.** Rationale: the user-editable ruleset and the ring buffer exist to describe and test 1Password triggers. Each watcher reusing a single `OverlayPanel` bounds the screen to one overlay per source.
```

12. §8, add to the test list:

```markdown
- **`OidcLoginTests`, `TriggerEntryBuilderTests`, `RequestingAppTests`** — notification parsing, kubelogin-helper detection and dropping with an injected path lookup, the three OIDC rules, entry building for empty and non-empty chains, outermost-bundle resolution, and app display names.
- **`OidcOverlayRenderingTests`, `OverlayPlacementTests`, `OidcKindColorTests`** — OIDC body rows and lead-row app (and that 1Password entries are unchanged), the browser-window placement math, and the `oidcLogin` color role.
```

and to "Deliberately *not* unit-tested": "- **`OidcLoginWatcher`** — notification delivery, the panel and the dismissal timer. Validated manually; its decisions live in tested pure functions."

- [ ] **Step 2: `CLAUDE.md`**

In "Key design decisions", replace the first bullet with:

```markdown
- Chain stops at any process registered as a macOS app (has bundle ID in NSWorkspace). The app is recorded (`ChainResult.appBundleID/appPID`, outermost bundle when nested) but never added to the chain. 1Password overlays do not show it, since 1Password already shows the app name; OIDC overlays do.
```

and add at the end of the list:

```markdown
- OIDC login notifications are unauthenticated. `OidcLoginWatcher` takes only the PID (and a frame used for placement) from them, requires that PID's `proc_pidpath` basename to be `kubectl-oidc_login` or `kubelogin` (never argv[0], the `KERN_PROCARGS2` path or the kinfo name), and derives all displayed text from the live process tree. Never display text taken from the notification.
- OIDC-only behavior is gated on `RequestSource.oidcLogin` or an opt-in parameter (`placement:`, `appName:`): 1Password overlays keep their text, rows and placement. `OidcLogin.rules` is fixed; the Rules pane must not offer `RequestKind.oidcLogin`, and OIDC requests are not recorded in the ring buffer.
- Each watcher owns one `OverlayPanel` and reuses it: at most one 1Password panel and one OIDC panel at a time.
```

- [ ] **Step 3: `README.md`**

After the numbered "How it works" list and before `## Supported terminals`, add:

```markdown
op-who also shows its overlay for Kubernetes OIDC logins started through `oidc-browser` from [sunstoneinstitute/cli-tools](https://github.com/sunstoneinstitute/cli-tools) (kubelogin's `--browser-command`). The overlay appears inside the browser window and names the app, terminal tab and command that needed the login, for example "Claude Code in cmux workspace ‘infra’ needs a Kubernetes login for ‘kubectl get pods -n demo’". It is context for a login you started, not proof that the login page is legitimate.
```

- [ ] **Step 4: `CHANGELOG.md`**

Under `## [Unreleased]` add:

```markdown
- Added: overlay for Kubernetes OIDC logins started by `oidc-browser`, shown inside the browser window and naming the app, terminal tab and command that needed the login. New `oidcLogin` popup color.
```

- [ ] **Step 5: Verify and commit**

Run: `swift test`
Expected: all PASS (docs only, confirms nothing else changed).

```bash
git add docs/architecture.md CLAUDE.md README.md CHANGELOG.md
git commit -m "Document the OIDC login overlay"
```

---

### Task 9: `oidc-browser` posts the notification (cli-tools)

Independent of Tasks 1–8. Work in `~/git/sunstone/cli-tools`.

**Files:**
- Modify: `swift/Sources/oidc-browser/OidcBrowser.swift`
- Create: `swift/Tests/oidc-browserTests/OidcBrowserTests.swift`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces (module-internal, top level in `OidcBrowser.swift`):
  - `func opWhoUserInfo(requesterPID: pid_t, bounds: [Int]?) -> [String: String]`
  - `func notifyOpWho(requesterPID: pid_t, bounds: [Int]?)`
- Protocol: see Global Constraints. `bounds` is AppleScript `{left, top, right, bottom}`.

- [ ] **Step 1: Write the failing test**

`swift/Tests/oidc-browserTests/OidcBrowserTests.swift`:

```swift
import Testing
@testable import oidc_browser

@Suite struct OpWhoUserInfoTests {
    @Test func includesFrameFromBounds() {
        #expect(opWhoUserInfo(requesterPID: 4242, bounds: [10, 20, 810, 620])
                == ["requesterPID": "4242", "frame": "10,20,800,600"])
    }

    @Test func omitsFrameWithoutValidBounds() {
        #expect(opWhoUserInfo(requesterPID: 4242, bounds: nil) == ["requesterPID": "4242"])
        #expect(opWhoUserInfo(requesterPID: 4242, bounds: [1, 2, 3]) == ["requesterPID": "4242"])
        #expect(opWhoUserInfo(requesterPID: 4242, bounds: [10, 20, 10, 620]) == ["requesterPID": "4242"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd swift && swift test --filter OpWhoUserInfoTests`
Expected: compile failure, `cannot find 'opWhoUserInfo'`.

- [ ] **Step 3: Implement the helpers**

Append to `OidcBrowser.swift`:

```swift
/// userInfo for op-who's OIDC overlay. Protocol: op-who
/// docs/superpowers/specs/2026-11-23-oidc-login-overlay-design.md.
func opWhoUserInfo(requesterPID: pid_t, bounds: [Int]?) -> [String: String] {
    var info = ["requesterPID": String(requesterPID)]
    if let b = bounds, b.count == 4, b[2] > b[0], b[3] > b[1] {
        info["frame"] = "\(b[0]),\(b[1]),\(b[2] - b[0]),\(b[3] - b[1])"
    }
    return info
}

/// Tells op-who, if running, which kubelogin process opened this login.
func notifyOpWho(requesterPID: pid_t, bounds: [Int]?) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.stigbakken.op-who.oidc-login"),
        object: nil,
        userInfo: opWhoUserInfo(requesterPID: requesterPID, bounds: bounds),
        deliverImmediately: true
    )
}
```

- [ ] **Step 4: Return bounds from the AppleScripts and post**

In `openScript(bundle:url:)`, change the Safari script's last line to `return {id of front window, bounds of front window}` and the Chromium script's last line to `return {id of w, bounds of w}`.

Replace `open(_:)` with:

```swift
    private func open(_ urlString: String) throws {
        guard let url = URL(string: urlString) else { throw ValidationError("Invalid URL: \(urlString)") }
        let requester = getppid()  // kubelogin
        let bundle = defaultBrowserBundleID()
        guard let script = openScript(bundle: bundle, url: urlString) else {
            NSWorkspace.shared.open(url)
            notifyOpWho(requesterPID: requester, bounds: nil)
            return
        }
        let prev = NSWorkspace.shared.frontmostApplication
        let result = try runAppleScript(script)
        let window = Int(result.atIndex(1)?.int32Value ?? 0)
        let bounds = result.atIndex(2).map { list in
            (1...max(list.numberOfItems, 1)).compactMap { list.atIndex($0).map { Int($0.int32Value) } }
        }
        notifyOpWho(requesterPID: requester, bounds: bounds)
        try spawnWatcher(bundle: bundle, window: window, prevPid: prev?.processIdentifier)
    }
```

Update the file's header comment to add one line: `Also notifies op-who (if running) so it can show which command needed the login.`

- [ ] **Step 5: Verify**

Run from repo root: `make && make test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 6: End-to-end check (needs op-who from Task 7 running)**

Run any kubectl command against a context whose token is expired, e.g. `kubectl --context <dev context> get pods -n <ns>` after `rm -rf ~/.kube/cache/oidc-login`. Expected: the browser window opens with op-who's overlay inside it, near the bottom edge and clear of the address bar, reading "… needs a Kubernetes login for ‘kubectl get pods -n <ns>’". The overlay and the window close when the login completes.

- [ ] **Step 7: Changelog and commit**

Add under `## [Unreleased]` in `CHANGELOG.md`:
`- Added: oidc-browser tells op-who which command started the login, so op-who can show it next to the browser window.`

```bash
git add swift/Sources/oidc-browser/OidcBrowser.swift swift/Tests/oidc-browserTests/OidcBrowserTests.swift CHANGELOG.md
git commit -m "oidc-browser: notify op-who of the requesting kubelogin process"
```
