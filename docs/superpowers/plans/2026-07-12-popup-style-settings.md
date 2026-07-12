# Popup Style Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user configure the approval popup's fonts, font size, and per-role colors from a new tabbed Settings window, defaulting to today's WCAG palette and system fonts.

**Architecture:** A pure `PopupStyle` resolver turns an `AppSettings` snapshot into concrete `NSFont`/`NSColor`, so `OverlayPanel` stops hardcoding sizes and default colors. `OverlayColors` stays the home of the default values (and its contrast test). The Settings window becomes an `NSTabView` with General / Appearance / Rules tabs; all visual settings live in the new `AppearancePane`.

**Tech Stack:** Swift, AppKit, Swift Testing, UserDefaults-backed `AppSettings`.

**Spec:** `docs/superpowers/specs/2026-07-12-popup-style-settings-design.md`

---

## File Structure

- **Modify** `Sources/OpWhoLib/AppSettings.swift` — four new keys (`popupUIFontName`, `popupMonoFontName`, `popupFontBaseSize`, `popupColorOverrides`).
- **Create** `Sources/OpWhoLib/PopupStyle.swift` — `PopupColorRole`, `FontRole`, `FontTier`, the `PopupStyle` resolver, and the `NSColor(popupHex:)` / `popupHexString` helpers.
- **Modify** `Sources/OpWhoLib/OverlayPanel.swift` — add a `style` property, route `makeLabel` and the color helpers through it, add `static func sampleEntry()`.
- **Modify** `Sources/OpWhoLib/OnePasswordWatcher.swift` — set `overlayPanel.style` before `show` (near line 430).
- **Modify** `Sources/op-who/GeneralPane.swift` — shed dense-popup + appearance controls; keep only "Run on startup".
- **Create** `Sources/op-who/AppearancePane.swift` — the new Appearance tab (dense, light/dark, fonts, size, colors, restore, preview).
- **Modify** `Sources/op-who/ConfigWindowController.swift` — replace the single scroll column with an `NSTabView`.
- **Modify** `Tests/AppSettingsTests.swift` — cover the four new keys.
- **Create** `Tests/PopupStyleTests.swift` — cover color/font/size resolution.

Test commands throughout: `swift build` and `swift test`. (If on a CommandLineTools-only toolchain, apply the `Testing.framework` symlink dance from `CLAUDE.md` first.)

---

## Task 1: `AppSettings` new keys

**Files:**
- Modify: `Sources/OpWhoLib/AppSettings.swift`
- Test: `Tests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/AppSettingsTests.swift` inside the `AppSettingsTests` struct:

```swift
    @Test("popup font names default to nil and persist")
    func popupFontNames() {
        let d = freshDefaults()
        #expect(AppSettings(defaults: d).popupUIFontName == nil)
        #expect(AppSettings(defaults: d).popupMonoFontName == nil)
        AppSettings(defaults: d).popupUIFontName = "Helvetica Neue"
        AppSettings(defaults: d).popupMonoFontName = "Menlo"
        #expect(AppSettings(defaults: d).popupUIFontName == "Helvetica Neue")
        #expect(AppSettings(defaults: d).popupMonoFontName == "Menlo")
    }

    @Test("clearing a popup font name restores nil")
    func popupFontNameClear() {
        let d = freshDefaults()
        let s = AppSettings(defaults: d)
        s.popupUIFontName = "Menlo"
        s.popupUIFontName = nil
        #expect(AppSettings(defaults: d).popupUIFontName == nil)
    }

    @Test("base font size defaults to 12 and clamps to 9...24")
    func popupBaseSize() {
        let d = freshDefaults()
        #expect(AppSettings(defaults: d).popupFontBaseSize == 12)
        AppSettings(defaults: d).popupFontBaseSize = 100   // over max
        #expect(AppSettings(defaults: d).popupFontBaseSize == 24)
        AppSettings(defaults: d).popupFontBaseSize = 1     // under min
        #expect(AppSettings(defaults: d).popupFontBaseSize == 9)
        AppSettings(defaults: d).popupFontBaseSize = 15
        #expect(AppSettings(defaults: d).popupFontBaseSize == 15)
    }

    @Test("color overrides default empty and persist")
    func popupColorOverrides() {
        let d = freshDefaults()
        #expect(AppSettings(defaults: d).popupColorOverrides.isEmpty)
        AppSettings(defaults: d).popupColorOverrides = ["claude": "#AABBCC"]
        #expect(AppSettings(defaults: d).popupColorOverrides["claude"] == "#AABBCC")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppSettings 2>&1 | tail -20`
Expected: FAIL — `value of type 'AppSettings' has no member 'popupUIFontName'` (etc.).

- [ ] **Step 3: Implement the keys**

In `Sources/OpWhoLib/AppSettings.swift`, add to the `Key` enum:

```swift
        static let popupUIFontName = "popupUIFontName"
        static let popupMonoFontName = "popupMonoFontName"
        static let popupFontBaseSize = "popupFontBaseSize"
        static let popupColorOverrides = "popupColorOverrides"
```

Add these properties after `appearance`:

```swift
    /// Popup proportional (UI) font family. nil ⇒ system font.
    public var popupUIFontName: String? {
        get { defaults.string(forKey: Key.popupUIFontName) }
        set { setOptionalString(newValue, forKey: Key.popupUIFontName) }
    }

    /// Popup monospace font family. nil ⇒ `monospacedSystemFont`.
    public var popupMonoFontName: String? {
        get { defaults.string(forKey: Key.popupMonoFontName) }
        set { setOptionalString(newValue, forKey: Key.popupMonoFontName) }
    }

    /// Base popup font size. The three popup tiers render at base−1/base/base+1.
    /// Default 12 (reproduces the historical 11/12/13). Clamped to 9…24.
    public var popupFontBaseSize: Double {
        get {
            guard defaults.object(forKey: Key.popupFontBaseSize) != nil else { return 12 }
            return Self.clampSize(defaults.double(forKey: Key.popupFontBaseSize))
        }
        set { defaults.set(Self.clampSize(newValue), forKey: Key.popupFontBaseSize) }
    }

    /// Per-role popup color overrides: role key → "#RRGGBB". Absent ⇒ default.
    public var popupColorOverrides: [String: String] {
        get { (defaults.dictionary(forKey: Key.popupColorOverrides) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.popupColorOverrides) }
    }

    private static func clampSize(_ v: Double) -> Double { min(24, max(9, v)) }

    private func setOptionalString(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppSettings 2>&1 | tail -20`
Expected: PASS (all AppSettings tests, including the pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/AppSettings.swift Tests/AppSettingsTests.swift
git commit -F - <<'EOF'
feat: add popup font/size/color settings keys to AppSettings

Four optional/defaulted UserDefaults keys backing the upcoming popup
style settings. Absent keys reproduce today's appearance.
EOF
```

---

## Task 2: `PopupStyle` — color roles and resolution

**Files:**
- Create: `Sources/OpWhoLib/PopupStyle.swift`
- Test: `Tests/PopupStyleTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PopupStyleTests.swift`:

```swift
import AppKit
import Testing
@testable import OpWhoLib

@Suite("PopupStyle colors")
struct PopupStyleColorTests {
    private func srgb(_ c: NSColor) -> (r: Double, g: Double, b: Double) {
        OverlayColors.srgb(c)
    }

    @Test("no override returns the role default")
    func defaultColor() {
        let style = PopupStyle.default
        for role in PopupColorRole.allCases {
            #expect(srgb(style.color(role)) == srgb(role.defaultColor))
        }
    }

    @Test("a valid hex override wins over the default")
    func overrideColor() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overrides: ["claude": "#112233"]
        )
        let c = style.color(.claude)
        #expect(srgb(c) == srgb(NSColor(srgbRed: 0x11/255.0, green: 0x22/255.0, blue: 0x33/255.0, alpha: 1)))
    }

    @Test("an invalid hex override falls back to the default")
    func invalidOverride() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overrides: ["ssh": "not-a-color"]
        )
        #expect(srgb(style.color(.ssh)) == srgb(PopupColorRole.ssh.defaultColor))
    }

    @Test("hex round-trips through NSColor helpers")
    func hexRoundTrip() {
        let c = NSColor(popupHex: "#4A2B99")
        #expect(c != nil)
        #expect(c?.popupHexString == "#4A2B99")
        #expect(NSColor(popupHex: "zzz") == nil)
        #expect(NSColor(popupHex: "#12345") == nil)   // wrong length
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PopupStyleColor 2>&1 | tail -20`
Expected: FAIL — `cannot find 'PopupStyle' in scope`.

- [ ] **Step 3: Implement `PopupStyle.swift` (colors + hex, font stub)**

Create `Sources/OpWhoLib/PopupStyle.swift`:

```swift
import AppKit

/// Semantic color roles the popup renders. Raw value is the stable storage
/// key used in `AppSettings.popupColorOverrides`.
public enum PopupColorRole: String, CaseIterable {
    case claude, editor, verifiedOp, unverifiedOp, ssh
    case gitRoot, branch, worktree
    case dimLabel, brightValue

    /// The WCAG-audited default from `OverlayColors` for this role.
    public var defaultColor: NSColor {
        switch self {
        case .claude:       return OverlayColors.claude
        case .editor:       return OverlayColors.editor
        case .verifiedOp:   return OverlayColors.verifiedOp
        case .unverifiedOp: return OverlayColors.unverifiedOp
        case .ssh:          return OverlayColors.ssh
        case .gitRoot:      return OverlayColors.gitRoot
        case .branch:       return OverlayColors.branch
        case .worktree:     return OverlayColors.worktree
        case .dimLabel:     return OverlayColors.dimLabel
        case .brightValue:  return OverlayColors.brightValue
        }
    }
}

/// Which of the popup's two font families a label uses.
public enum FontRole { case ui, mono }

/// The three popup size tiers, relative to the configured base size.
public enum FontTier {
    case small, base, large
    var offset: CGFloat {
        switch self {
        case .small: return -1
        case .base:  return 0
        case .large: return 1
        }
    }
}

/// Pure resolver turning an `AppSettings` snapshot into concrete fonts/colors.
/// `OverlayPanel` asks this instead of hardcoding sizes or default colors.
public struct PopupStyle {
    private let uiFontName: String?
    private let monoFontName: String?
    private let baseSize: CGFloat
    private let overrides: [String: String]

    /// Reproduces today's appearance: system fonts, base 12, no overrides.
    public static let `default` = PopupStyle(
        uiFontName: nil, monoFontName: nil, baseSize: 12, overrides: [:]
    )

    public init(uiFontName: String?, monoFontName: String?, baseSize: CGFloat, overrides: [String: String]) {
        self.uiFontName = uiFontName
        self.monoFontName = monoFontName
        self.baseSize = baseSize
        self.overrides = overrides
    }

    public init(settings: AppSettings) {
        self.init(
            uiFontName: settings.popupUIFontName,
            monoFontName: settings.popupMonoFontName,
            baseSize: CGFloat(settings.popupFontBaseSize),
            overrides: settings.popupColorOverrides
        )
    }

    public func color(_ role: PopupColorRole) -> NSColor {
        if let hex = overrides[role.rawValue], let c = NSColor(popupHex: hex) {
            return c
        }
        return role.defaultColor
    }

    public func font(_ role: FontRole, weight: NSFont.Weight, tier: FontTier) -> NSFont {
        let size = baseSize + tier.offset
        let familyName = (role == .ui) ? uiFontName : monoFontName
        if let name = familyName {
            // The weight trait must be the numeric rawValue; passing the
            // NSFont.Weight struct is silently ignored by the descriptor.
            let desc = NSFontDescriptor(fontAttributes: [
                .family: name,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            if let f = NSFont(descriptor: desc, size: size) { return f }
        }
        return role == .ui
            ? NSFont.systemFont(ofSize: size, weight: weight)
            : NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}

public extension NSColor {
    /// Parse `#RRGGBB` (sRGB). Returns nil for malformed input.
    convenience init?(popupHex hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green:   CGFloat((v >> 8) & 0xFF) / 255,
            blue:    CGFloat(v & 0xFF) / 255,
            alpha:   1
        )
    }

    /// `#RRGGBB` in sRGB. Used to persist a color-well selection.
    var popupHexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PopupStyleColor 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/PopupStyle.swift Tests/PopupStyleTests.swift
git commit -F - <<'EOF'
feat: add PopupStyle resolver with color roles and hex helpers

PopupColorRole maps each popup color to its OverlayColors default;
PopupStyle.color resolves an override (or the default). Adds
NSColor(popupHex:)/popupHexString for persistence.
EOF
```

---

## Task 3: `PopupStyle` — font and size resolution

**Files:**
- Test: `Tests/PopupStyleTests.swift`
- (Implementation already written in Task 2; this task adds the font/size tests that lock its behavior.)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/PopupStyleTests.swift`:

```swift
@Suite("PopupStyle fonts")
struct PopupStyleFontTests {
    @Test("default base 12 yields 11/12/13 tiers")
    func defaultTiers() {
        let s = PopupStyle.default
        #expect(s.font(.ui, weight: .regular, tier: .small).pointSize == 11)
        #expect(s.font(.ui, weight: .regular, tier: .base).pointSize == 12)
        #expect(s.font(.ui, weight: .regular, tier: .large).pointSize == 13)
    }

    @Test("custom base size shifts every tier")
    func customBase() {
        let s = PopupStyle(uiFontName: nil, monoFontName: nil, baseSize: 16, overrides: [:])
        #expect(s.font(.mono, weight: .regular, tier: .small).pointSize == 15)
        #expect(s.font(.mono, weight: .regular, tier: .base).pointSize == 16)
        #expect(s.font(.mono, weight: .regular, tier: .large).pointSize == 17)
    }

    @Test("system default mono role is monospaced")
    func systemMonoIsFixedPitch() {
        let f = PopupStyle.default.font(.mono, weight: .regular, tier: .base)
        #expect(f.isFixedPitch)
    }

    @Test("unknown family name falls back to a system font of the right size")
    func unknownFamilyFallsBack() {
        let s = PopupStyle(uiFontName: "No Such Font XYZ", monoFontName: nil, baseSize: 12, overrides: [:])
        let f = s.font(.ui, weight: .semibold, tier: .large)
        #expect(f.pointSize == 13)   // still sized correctly
    }

    @Test("a real custom family is honored")
    func customFamilyHonored() {
        let s = PopupStyle(uiFontName: "Menlo", monoFontName: nil, baseSize: 12, overrides: [:])
        let f = s.font(.ui, weight: .regular, tier: .base)
        #expect(f.familyName == "Menlo")
        #expect(f.pointSize == 12)
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter PopupStyleFont 2>&1 | tail -20`
Expected: PASS (implementation from Task 2 already satisfies these).

Note: if `unknownFamilyFallsBack` fails because `NSFont(descriptor:)` synthesized a font at the wrong size, harden `PopupStyle.font` by also asserting the resolved font's `familyName != nil`; but the descriptor path returns nil for unknown families on macOS, so the system fallback runs. Do not change the test.

- [ ] **Step 3: Commit**

```bash
git add Tests/PopupStyleTests.swift
git commit -F - <<'EOF'
test: lock PopupStyle font tiers, size scaling, and family fallback
EOF
```

---

## Task 4: Route `OverlayPanel` through `PopupStyle`

**Files:**
- Modify: `Sources/OpWhoLib/OverlayPanel.swift`
- Test: existing `Tests/OverlayPanelTests.swift` + `Tests/BodyTableRenderTests.swift` are the regression guard (they use the default style).

- [ ] **Step 1: Add the `style` property**

In `OverlayPanel`, next to `var densePopup: Bool = false` (around line 67), add:

```swift
    /// Resolves popup fonts and colors from user settings. Defaults to the
    /// historical appearance; set before `show` (see OnePasswordWatcher).
    var style: PopupStyle = .default
```

- [ ] **Step 2: Replace `makeLabel`'s size/mono parameters with role/tier**

Replace the existing `makeLabel(_:size:weight:color:mono:)` (around line 557) with:

```swift
    private func makeLabel(
        _ text: String,
        role: FontRole,
        weight: NSFont.Weight,
        tier: FontTier,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = style.font(role, weight: weight, tier: tier)
        label.textColor = color
        label.isSelectable = true
        return label
    }
```

- [ ] **Step 3: Update every `makeLabel` call site**

Apply these exact replacements (size → role/tier; `mono: true` → `role: .mono`):

- `makeHeaderRow` (line ~212):
  `makeLabel("op-who", size: 11, weight: .medium, color: .secondaryLabelColor)`
  → `makeLabel("op-who", role: .ui, weight: .medium, tier: .small, color: .secondaryLabelColor)`

- `makeElapsedLabel` (line ~227):
  ```swift
  let timeLabel = makeLabel(
      formatElapsed(0),
      role: .mono, weight: .medium, tier: .base,
      color: elapsedColor(0)
  )
  ```

- `makeBodyTable` cells (line ~332): the label-column cell becomes
  ```swift
  makeLabel(
      row.label ?? "", role: .mono, weight: .regular, tier: .small,
      color: style.color(.dimLabel)
  ),
  ```

- `makeBodyValueLabel` (line ~357):
  `let label = makeLabel(row.value, size: 12, weight: weight, color: color)`
  → `let label = makeLabel(row.value, role: .ui, weight: weight, tier: .base, color: color)`

- `makeTerminalRow` (lines ~436-437):
  ```swift
  let label = makeLabel("", role: .ui, weight: .semibold, tier: .large, color: .labelColor)
  let mainFont = style.font(.ui, weight: .semibold, tier: .large)
  ```

- `makeTerminalRow` shortcuts label (line ~467):
  ```swift
  let sl = makeLabel(
      shortcutsText,
      role: .mono, weight: .medium, tier: .base, color: dim
  )
  ```

- `makeDimDetailLabel` (line ~575):
  `let label = makeLabel(text, size: 11, weight: .regular, color: .secondaryLabelColor, mono: true)`
  → `let label = makeLabel(text, role: .mono, weight: .regular, tier: .small, color: .secondaryLabelColor)`

- `makeProcessTreeLabel` (line ~589):
  `let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)`
  → `let font = style.font(.mono, weight: .regular, tier: .small)`

- [ ] **Step 4: Route the color helpers through `style`**

Replace `OverlayColors.<role>` with `style.color(.<role>)` in these methods:

- `bodyActionColor` (line ~371):
  ```swift
  private func bodyActionColor(_ kind: RequestKind) -> NSColor {
      switch kind {
      case .onePasswordCLI: return style.color(.verifiedOp)
      case .unverifiedOp:   return style.color(.unverifiedOp)
      case .ssh:            return style.color(.ssh)
      case .unknown:        return style.color(.brightValue)
      }
  }
  ```

- `bodyFieldColor` (line ~380):
  ```swift
  private func bodyFieldColor(_ field: FieldColor) -> NSColor {
      switch field {
      case .gitRoot:  return style.color(.gitRoot)
      case .branch:   return style.color(.branch)
      case .worktree: return style.color(.worktree)
      case .plain:    return style.color(.brightValue)
      }
  }
  ```

- `bodyWhoColor` (line ~389):
  ```swift
  private func bodyWhoColor(_ kind: DriverKind) -> NSColor {
      switch kind {
      case .claude: return style.color(.claude)
      case .editor: return style.color(.editor)
      case .shell, .other: return style.color(.brightValue)
      }
  }
  ```

- `makeProcessTreeLabel` op colors (line ~597):
  ```swift
          switch node.opColor {
          case .verified:   color = style.color(.verifiedOp)
          case .unverified: color = style.color(.unverifiedOp)
          case .none:       color = style.color(.dimLabel)
          }
  ```

Leave `.secondaryLabelColor`, `.tertiaryLabelColor`, and `.labelColor` literals (chrome), and the `toggle.font`/button `NSFont.systemFont(ofSize: 11)` chrome fonts, unchanged.

- [ ] **Step 5: Run the regression tests**

Run: `swift test --filter OverlayPanel 2>&1 | tail -20 && swift test --filter BodyTable 2>&1 | tail -20`
Expected: PASS — the default style reproduces the prior fonts/colors, so these existing tests stay green.

- [ ] **Step 6: Full build + test**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -15`
Expected: build succeeds; all tests pass (including `OverlayColorsContrastTests`, unchanged).

- [ ] **Step 7: Commit**

```bash
git add Sources/OpWhoLib/OverlayPanel.swift
git commit -F - <<'EOF'
refactor: resolve popup fonts and colors through PopupStyle

OverlayPanel gains a `style` property and asks it for every font and
themeable color instead of hardcoding sizes and OverlayColors values.
Default style reproduces the prior appearance exactly.
EOF
```

---

## Task 5: Sample entry factory + wire `style` into live popups

**Files:**
- Modify: `Sources/OpWhoLib/OverlayPanel.swift` (add `sampleEntry`)
- Modify: `Sources/OpWhoLib/OnePasswordWatcher.swift` (set `style` before show)
- Test: `Tests/OverlayPanelTests.swift` (a smoke test for `sampleEntry`)

- [ ] **Step 1: Write the failing test**

Append to `Tests/OverlayPanelTests.swift` (new suite at end of file):

```swift
@Suite("OverlayPanel.sampleEntry")
@MainActor
struct OverlayPanelSampleEntryTests {
    @Test("sample entry renders a content view without crashing")
    func sampleRenders() {
        let panel = OverlayPanel()
        panel.style = PopupStyle(uiFontName: nil, monoFontName: "Menlo",
                                 baseSize: 14, overrides: ["claude": "#AA33FF"])
        let view = panel.buildContentView(entries: [OverlayPanel.sampleEntry()])
        let stack = view as? NSStackView
        #expect(stack != nil)
        #expect((stack?.arrangedSubviews.count ?? 0) >= 2)  // header + entry
    }
}
```

Add `import AppKit` at the top of `OverlayPanelTests.swift` if not already present (the file currently imports `Foundation`/`Testing`; add `import AppKit`).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SampleEntry 2>&1 | tail -20`
Expected: FAIL — `type 'OverlayPanel' has no member 'sampleEntry'`.

- [ ] **Step 3: Add `sampleEntry`**

In `OverlayPanel` (place it just after the `ProcessEntry` struct definition, before `private var panel`), add:

```swift
    /// A representative entry used by the Settings "Preview" button so fonts
    /// and colors can be judged without waiting for a real 1Password prompt.
    public static func sampleEntry() -> ProcessEntry {
        ProcessEntry(
            pid: 4242,
            chain: [
                ProcessNode(pid: 4242, ppid: 4200, name: "op", tty: "/dev/ttys003",
                            executablePath: "/opt/homebrew/bin/op", isVerifiedOnePasswordCLI: true),
                ProcessNode(pid: 4200, ppid: 4100, name: "node", tty: "/dev/ttys003",
                            executablePath: nil, isVerifiedOnePasswordCLI: false),
                ProcessNode(pid: 4100, ppid: 1, name: "zsh", tty: "/dev/ttys003",
                            executablePath: nil, isVerifiedOnePasswordCLI: false),
            ],
            triggerArgv: ["op", "read", "op://vault/item/password"],
            tty: "/dev/ttys003",
            tabTitle: "op-who",
            tabShortcut: nil,
            claudeSession: "preview",
            claudeContext: nil,
            scriptInfo: nil,
            terminalBundleID: "com.googlecode.iterm2",
            terminalPID: 4000,
            cwd: "~/git/stigsb/op-who",
            triggerCwd: "~/git/stigsb/op-who",
            cmuxWorkspaceID: nil,
            cmuxTabID: nil,
            cmuxSurface: nil,
            pluginUpdate: nil,
            summary: RequestSummary(kind: .onePasswordCLI, title: "Preview", subtitle: nil, isWarning: false),
            matchedRuleID: nil,
            matchedRuleName: nil,
            matchedBuiltInID: nil,
            gitContext: GitContext(root: "~/git/stigsb/op-who", branch: "main", worktreeSubpath: nil)
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SampleEntry 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Set `style` on the live panel**

In `Sources/OpWhoLib/OnePasswordWatcher.swift`, around lines 428-430, the code currently reads:

```swift
            overlayPanel = OverlayPanel()
        }
        overlayPanel?.densePopup = AppSettings().densePopup
```

Replace the settings-read line so both settings come from one snapshot:

```swift
            overlayPanel = OverlayPanel()
        }
        let settings = AppSettings()
        overlayPanel?.densePopup = settings.densePopup
        overlayPanel?.style = PopupStyle(settings: settings)
```

- [ ] **Step 6: Build + full test**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -15`
Expected: build succeeds; all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpWhoLib/OverlayPanel.swift Sources/OpWhoLib/OnePasswordWatcher.swift Tests/OverlayPanelTests.swift
git commit -F - <<'EOF'
feat: apply PopupStyle to live popups and add a sample entry for preview

Live popups now build their PopupStyle from AppSettings before showing.
OverlayPanel.sampleEntry provides a representative entry for the Settings
preview button.
EOF
```

---

## Task 6: Slim `GeneralPane` down to "Run on startup"

**Files:**
- Modify: `Sources/op-who/GeneralPane.swift`

Dense-popup and appearance controls move to `AppearancePane` (Task 7). `GeneralPane` keeps only the startup toggle and its `SMAppService` wiring.

- [ ] **Step 1: Remove the moved controls and their handlers**

Replace the whole body of `GeneralPane` with:

```swift
import AppKit
import OpWhoLib
import ServiceManagement

/// The General tab: non-visual global options. Currently just the
/// "Run on startup" toggle (backed by SMAppService). Visual popup settings
/// live in `AppearancePane`.
final class GeneralPane: NSObject {

    private let startupCheckbox = NSButton(
        checkboxWithTitle: "Run op-who on startup",
        target: nil,
        action: nil
    )

    private(set) lazy var view: NSView = makeContentView()

    override init() {
        super.init()
        _ = view
        startupCheckbox.target = self
        startupCheckbox.action = #selector(toggleStartup(_:))
        refreshState()
    }

    /// Re-read the SMAppService status. Called from the window-controller
    /// just before the window appears, so a change made via System Settings
    /// while op-who was running shows up the next time the user opens
    /// Settings.
    func refreshState() {
        startupCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private func makeContentView() -> NSView {
        let stack = NSStackView(views: [startupCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @objc private func toggleStartup(_ sender: NSButton) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change startup setting"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshState()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: FAILS to link only if something still references the removed members — nothing does yet (`ConfigWindowController` still calls `generalPane.view` and `refreshState`, both retained). Build should succeed.

- [ ] **Step 3: Commit**

```bash
git add Sources/op-who/GeneralPane.swift
git commit -F - <<'EOF'
refactor: reduce GeneralPane to the Run-on-startup toggle

Dense-popup and appearance controls move to the new Appearance tab.
EOF
```

---

## Task 7: Create `AppearancePane`

**Files:**
- Create: `Sources/op-who/AppearancePane.swift`

Holds: Dense popup checkbox, System/Light/Dark segmented control, UI/Mono font family popups, base-size stepper, per-role color wells, Restore defaults, and Show/Hide Preview. Every control writes to `AppSettings` immediately.

- [ ] **Step 1: Write the pane**

Create `Sources/op-who/AppearancePane.swift`:

```swift
import AppKit
import OpWhoLib

/// The Appearance tab: all popup visual settings. Each control writes to
/// AppSettings immediately, so the Preview button (and the next real popup)
/// reflect changes without an explicit save.
final class AppearancePane: NSObject {

    private let settings = AppSettings()

    // Behavior + appearance (moved from GeneralPane).
    private let denseCheckbox = NSButton(
        checkboxWithTitle: "Dense popup (collapse rows that don't apply)",
        target: nil, action: nil
    )
    private let appearanceControl = NSSegmentedControl(
        labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil
    )

    // Fonts.
    private let uiFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let monoFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeStepper = NSStepper()
    private let sizeLabel = NSTextField(labelWithString: "")

    // Colors: one well per role, in declaration order.
    private var colorWells: [PopupColorRole: NSColorWell] = [:]

    // Preview.
    private var previewPanel: OverlayPanel?

    private static let systemDefaultTitle = "System default"

    private(set) lazy var view: NSView = makeContentView()

    override init() {
        super.init()
        _ = view
        wireControls()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        denseCheckbox.state = settings.densePopup ? .on : .off

        appearanceControl.selectedSegment = {
            switch settings.appearance {
            case .system: return 0
            case .light:  return 1
            case .dark:   return 2
            }
        }()

        populateFontPopup(uiFontPopup, selected: settings.popupUIFontName)
        populateFontPopup(monoFontPopup, selected: settings.popupMonoFontName)

        sizeStepper.minValue = 9
        sizeStepper.maxValue = 24
        sizeStepper.increment = 1
        sizeStepper.integerValue = Int(settings.popupFontBaseSize.rounded())
        updateSizeLabel()

        let stack = NSStackView(views: [
            sectionLabel("Popup"),
            denseCheckbox,
            labeledRow("Appearance:", appearanceControl),
            spacer(),
            sectionLabel("Fonts"),
            labeledRow("UI font:", uiFontPopup),
            labeledRow("Mono font:", monoFontPopup),
            labeledRow("Base size:", sizeRow()),
            spacer(),
            sectionLabel("Colors"),
            colorGrid(),
            restoreRow(),
            spacer(),
            previewRow(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.boldSystemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return v
    }

    private func labeledRow(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let row = NSStackView(views: [l, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func sizeRow() -> NSStackView {
        let row = NSStackView(views: [sizeLabel, sizeStepper])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        sizeLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return row
    }

    /// A two-column grid of role name → color well.
    private func colorGrid() -> NSView {
        let cells: [[NSView]] = PopupColorRole.allCases.map { role in
            let well = NSColorWell()
            well.color = PopupStyle(settings: settings).color(role)
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.tag = colorTag(for: role)
            colorWells[role] = well

            let name = NSTextField(labelWithString: role.rawValue)
            name.font = NSFont.systemFont(ofSize: 12)
            return [name, well]
        }
        let grid = NSGridView(views: cells)
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .leading }
        return grid
    }

    private func restoreRow() -> NSView {
        let btn = NSButton(title: "Restore default colors", target: self,
                           action: #selector(restoreDefaults(_:)))
        btn.bezelStyle = .rounded
        return btn
    }

    private func previewRow() -> NSStackView {
        let show = NSButton(title: "Show Preview", target: self, action: #selector(showPreview(_:)))
        show.bezelStyle = .rounded
        let hide = NSButton(title: "Hide Preview", target: self, action: #selector(hidePreview(_:)))
        hide.bezelStyle = .rounded
        let row = NSStackView(views: [show, hide])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - Wiring

    private func wireControls() {
        denseCheckbox.target = self
        denseCheckbox.action = #selector(toggleDense(_:))
        appearanceControl.target = self
        appearanceControl.action = #selector(changeAppearance(_:))
        uiFontPopup.target = self
        uiFontPopup.action = #selector(uiFontChanged(_:))
        monoFontPopup.target = self
        monoFontPopup.action = #selector(monoFontChanged(_:))
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeChanged(_:))
    }

    private func populateFontPopup(_ popup: NSPopUpButton, selected: String?) {
        popup.removeAllItems()
        popup.addItem(withTitle: Self.systemDefaultTitle)
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        popup.addItems(withTitles: families)
        if let selected, families.contains(selected) {
            popup.selectItem(withTitle: selected)
        } else {
            popup.selectItem(withTitle: Self.systemDefaultTitle)
        }
    }

    /// Encode a role as an NSControl tag via its position in `allCases`.
    private func colorTag(for role: PopupColorRole) -> Int {
        PopupColorRole.allCases.firstIndex(of: role) ?? 0
    }
    private func role(forTag tag: Int) -> PopupColorRole? {
        let all = PopupColorRole.allCases
        return all.indices.contains(tag) ? all[tag] : nil
    }

    private func updateSizeLabel() {
        sizeLabel.stringValue = "\(sizeStepper.integerValue)"
    }

    private func selectedFontName(_ popup: NSPopUpButton) -> String? {
        let title = popup.titleOfSelectedItem ?? Self.systemDefaultTitle
        return title == Self.systemDefaultTitle ? nil : title
    }

    // MARK: - Actions

    @objc private func toggleDense(_ sender: NSButton) {
        settings.densePopup = (sender.state == .on)
    }

    @objc private func changeAppearance(_ sender: NSSegmentedControl) {
        let a: AppAppearance = [.system, .light, .dark][sender.selectedSegment]
        settings.appearance = a
        applyAppearance(a)
    }

    @objc private func uiFontChanged(_ sender: NSPopUpButton) {
        settings.popupUIFontName = selectedFontName(sender)
    }

    @objc private func monoFontChanged(_ sender: NSPopUpButton) {
        settings.popupMonoFontName = selectedFontName(sender)
    }

    @objc private func sizeChanged(_ sender: NSStepper) {
        settings.popupFontBaseSize = Double(sender.integerValue)
        updateSizeLabel()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let role = role(forTag: sender.tag) else { return }
        var overrides = settings.popupColorOverrides
        overrides[role.rawValue] = sender.color.popupHexString
        settings.popupColorOverrides = overrides
    }

    @objc private func restoreDefaults(_ sender: NSButton) {
        settings.popupColorOverrides = [:]
        for (role, well) in colorWells {
            well.color = role.defaultColor
        }
    }

    @objc private func showPreview(_ sender: NSButton) {
        previewPanel?.dismiss()
        let panel = OverlayPanel()
        panel.densePopup = settings.densePopup
        panel.style = PopupStyle(settings: settings)
        panel.show(entries: [OverlayPanel.sampleEntry()], near: nil)
        previewPanel = panel
    }

    @objc private func hidePreview(_ sender: NSButton) {
        previewPanel?.dismiss()
        previewPanel = nil
    }

    /// Called by the window controller when Settings closes, so a stray
    /// preview panel doesn't linger.
    func dismissPreview() {
        previewPanel?.dismiss()
        previewPanel = nil
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -15`
Expected: FAILS only at the not-yet-updated `ConfigWindowController` (it doesn't reference `AppearancePane` yet, so it should actually build). If the build succeeds, good; if it errors on `AppearancePane` being unused, that's not an error in Swift — proceed.

- [ ] **Step 3: Commit**

```bash
git add Sources/op-who/AppearancePane.swift
git commit -F - <<'EOF'
feat: add AppearancePane with fonts, size, color wells, and preview

New Appearance-tab pane owning dense-popup, light/dark, font family
popups, base-size stepper, per-role color wells with restore, and a
Show/Hide Preview backed by OverlayPanel.sampleEntry.
EOF
```

---

## Task 8: Tabbed Settings window

**Files:**
- Modify: `Sources/op-who/ConfigWindowController.swift`

Replace the single scroll column with an `NSTabView` (General / Appearance / Rules). Rules moves to its own tab. Preserve the `ConfigWindow` subclass (Cmd-W + undo field editor).

- [ ] **Step 1: Rework `ConfigWindowController`**

Replace the stored properties, `init`, `showWindow`, `resetScrollToTop`, `makeContentView`, and `makeOptionsSection` (keep the `ConfigWindow` inner class unchanged) so the type reads:

```swift
final class ConfigWindowController: NSWindowController, NSWindowDelegate {

    private let generalPane: GeneralPane
    private let appearancePane: AppearancePane
    private let rulesPane: RulesPane
    private var appearanceScroll: NSScrollView?

    init(
        ruleStore: RequestRuleStore,
        recentStore: RecentRequestsStore
    ) {
        self.generalPane = GeneralPane()
        self.appearancePane = AppearancePane()
        self.rulesPane = RulesPane(store: ruleStore, recentStore: recentStore)

        let window = ConfigWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "op-who Settings"
        window.minSize = NSSize(width: 720, height: 540)
        super.init(window: window)

        rulesPane.presenter = window
        window.delegate = self
        window.contentView = makeTabView()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func showWindow(_ sender: Any?) {
        generalPane.refreshState()
        super.showWindow(sender)
        resetAppearanceScroll()
    }

    /// Dismiss any lingering popup preview when Settings closes.
    func windowWillClose(_ notification: Notification) {
        appearancePane.dismissPreview()
    }

    private func makeTabView() -> NSView {
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        tabView.addTabViewItem(tab("General", fill(generalPane.view)))

        let appearanceScroll = wrapInScroll(appearancePane.view)
        self.appearanceScroll = appearanceScroll
        tabView.addTabViewItem(tab("Appearance", appearanceScroll))

        tabView.addTabViewItem(tab("Rules", fill(rulesPane.view)))

        return tabView
    }

    private func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    /// A plain container that lets its single child fill it (autoresizing).
    private func fill(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func wrapInScroll(_ content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    /// The controller is retained and reused, so the Appearance scroll view
    /// keeps its prior offset. Snap it back to the top on reopen.
    private func resetAppearanceScroll() {
        guard let scroll = appearanceScroll, let doc = scroll.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let topY = doc.isFlipped ? 0 : max(0, doc.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: topY))
        scroll.reflectScrolledClipView(clip)
    }
```

Keep the existing `private final class ConfigWindow: NSWindow { ... }` block exactly as it is, and the closing brace of `ConfigWindowController`.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -15`
Expected: build succeeds.

- [ ] **Step 3: Manually verify the window** (AppKit UI — not unit-testable)

Build and launch the app bundle:

```bash
scripts/bundle.sh && open .build/op-who.app 2>/dev/null || echo "check scripts/bundle.sh output path"
```

(If the bundle output path differs, use the path `scripts/bundle.sh` prints.) Then, from the menu-bar icon, open **Settings** and confirm:
- Three tabs: General, Appearance, Rules.
- **General** shows only "Run op-who on startup".
- **Appearance** shows dense popup, System/Light/Dark, UI/Mono font popups, base-size stepper, the color wells, "Restore default colors", and Show/Hide Preview.
- **Rules** shows the rules table as before.
- Click **Show Preview** → the popup appears using current settings; change a color / base size / font, click Show Preview again → it reflects the change; **Hide Preview** dismisses it; closing Settings also dismisses it.

- [ ] **Step 4: Commit**

```bash
git add Sources/op-who/ConfigWindowController.swift
git commit -F - <<'EOF'
feat: tabbed Settings window (General / Appearance / Rules)

Replaces the single scroll column with an NSTabView. Rules moves into
its own tab; the Appearance tab scrolls and its preview is dismissed
when Settings closes.
EOF
```

---

## Task 9: Full verification & docs

**Files:**
- Modify: `CLAUDE.md` (document the new settings surface)

- [ ] **Step 1: Full build + test**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected: build succeeds; all tests pass (AppSettings, PopupStyle, OverlayPanel, BodyTable, OverlayColors contrast, and the rest).

- [ ] **Step 2: Update `CLAUDE.md`**

In the "Key design decisions" list, append a bullet after the popup-body bullet:

```markdown
- Popup fonts and colors are configurable (`PopupStyle.swift`): `AppSettings` stores an optional UI-font family, mono-font family, a base size (default 12; the popup's three tiers render at base−1/base/base+1), and per-role color overrides (`popupColorOverrides`, keyed by `PopupColorRole.rawValue`). `PopupStyle` resolves each request to a concrete `NSFont`/`NSColor`, falling back to the system font or the WCAG-audited `OverlayColors` default; `OverlayColors` stays the home of the defaults and the contrast test. The Settings window is an `NSTabView` (General / Appearance / Rules): `GeneralPane` holds only Run-on-startup; `AppearancePane` owns dense-popup, light/dark, the font pickers, size stepper, per-role color wells, and a Show/Hide Preview backed by `OverlayPanel.sampleEntry()`.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -F - <<'EOF'
docs: document configurable popup fonts/colors and tabbed settings
EOF
```

- [ ] **Step 4: Finish the branch**

Use the `superpowers:finishing-a-development-branch` skill to decide how to integrate the work (merge / PR / cleanup).

---

## Notes for the implementer

- **Regression guard:** Tasks 1-3 are pure TDD. Task 4 is a behavior-preserving refactor — its guard is that the *existing* `OverlayPanelTests`, `BodyTableRenderTests`, and `OverlayColorsContrastTests` stay green with the default style.
- **No WCAG enforcement on overrides:** deliberate. The contrast test guards only the built-in defaults; custom colors are the user's call.
- **Static overrides:** one color per role, applied in both light and dark (per the approved spec). The Preview button + the light/dark control let the user check both appearances.
- **Chrome stays fixed:** the "▸ details" toggle, the Show Tab / Send Message buttons, and the secondary/tertiary system label colors are intentionally *not* themed or scaled.
- **Commit message hygiene:** all commits above use single-quoted HEREDOCs so backticks aren't interpolated (see `CLAUDE.md`). Never advertise the assistant in commit messages.
