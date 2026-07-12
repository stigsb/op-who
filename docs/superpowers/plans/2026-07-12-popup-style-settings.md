# Popup Style Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user configure the approval popup's fonts, font size, and per-role colors (with per-appearance light/dark values and live WCAG contrast guidance) from a new tabbed Settings window, defaulting to today's WCAG palette and system fonts.

**Architecture:** A pure `PopupStyle` resolver turns an `AppSettings` snapshot into concrete `NSFont`/`NSColor`, so `OverlayPanel` stops hardcoding sizes and default colors. Color overrides are **per-appearance** (a light and a dark hex per role); `OverlayColors` stays the home of the default values (and its contrast test) and newly exposes its raw light/dark pairs. The Settings window becomes an `NSTabView` with General / Appearance / Rules tabs; all visual settings live in the new `AppearancePane`, where each color well carries a live WCAG AA contrast badge with click-to-snap (guide, don't block).

**Tech Stack:** Swift, AppKit, Swift Testing, UserDefaults-backed `AppSettings`.

**Specs:**
- `docs/superpowers/specs/2026-07-12-popup-style-settings-design.md`
- `docs/superpowers/specs/2026-07-12-wcag-contrast-guidance-design.md` (amends the first: per-appearance overrides, badges + snap)

---

## File Structure

- **Modify** `Sources/OpWhoLib/AppSettings.swift` — five new keys (`popupUIFontName`, `popupMonoFontName`, `popupFontBaseSize`, `popupColorOverridesLight`, `popupColorOverridesDark`).
- **Modify** `Sources/OpWhoLib/OverlayColors.swift` — expose the `(light, dark)` pair behind each role plus `backgroundPair` and a public `resolved(_:dark:)` helper.
- **Create** `Sources/OpWhoLib/PopupStyle.swift` — `PopupColorRole`, `FontRole`, `FontTier`, the `PopupStyle` resolver, and the `NSColor(popupHex:)` / `popupHexString` helpers.
- **Create** `Sources/OpWhoLib/ContrastSnap.swift` — `snapToContrast` and the HSB conversion helpers.
- **Modify** `Sources/OpWhoLib/OverlayPanel.swift` — add a `style` property, route `makeLabel` and the color helpers through it, add `static func sampleEntry()`.
- **Modify** `Sources/OpWhoLib/OnePasswordWatcher.swift` — set `overlayPanel.style` before `show` (near line 430).
- **Modify** `Sources/op-who/GeneralPane.swift` — shed dense-popup + appearance controls; keep only "Run on startup".
- **Create** `Sources/op-who/AppearancePane.swift` — the new Appearance tab (dense, light/dark, fonts, size, Light+Dark color wells with contrast badges, restore, preview).
- **Modify** `Sources/op-who/ConfigWindowController.swift` — replace the single scroll column with an `NSTabView`.
- **Modify** `Tests/AppSettingsTests.swift` — cover the five new keys.
- **Create** `Tests/PopupStyleTests.swift` — cover color/font/size resolution.
- **Create** `Tests/ContrastSnapTests.swift` — cover `snapToContrast`.
- **Modify** `Tests/OverlayColorsContrastTests.swift` — add a pair-consistency suite (existing contrast assertions unchanged).

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

    @Test("per-appearance color overrides default empty and persist independently")
    func popupColorOverrides() {
        let d = freshDefaults()
        #expect(AppSettings(defaults: d).popupColorOverridesLight.isEmpty)
        #expect(AppSettings(defaults: d).popupColorOverridesDark.isEmpty)
        AppSettings(defaults: d).popupColorOverridesLight = ["claude": "#AABBCC"]
        AppSettings(defaults: d).popupColorOverridesDark = ["claude": "#112233"]
        #expect(AppSettings(defaults: d).popupColorOverridesLight["claude"] == "#AABBCC")
        #expect(AppSettings(defaults: d).popupColorOverridesDark["claude"] == "#112233")
        #expect(AppSettings(defaults: d).popupColorOverridesLight["ssh"] == nil)
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
        static let popupColorOverridesLight = "popupColorOverridesLight"
        static let popupColorOverridesDark = "popupColorOverridesDark"
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

    /// Per-role popup color overrides for the light appearance:
    /// role key → "#RRGGBB". Absent key ⇒ the role's default light variant.
    public var popupColorOverridesLight: [String: String] {
        get { (defaults.dictionary(forKey: Key.popupColorOverridesLight) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.popupColorOverridesLight) }
    }

    /// Per-role popup color overrides for the dark appearance:
    /// role key → "#RRGGBB". Absent key ⇒ the role's default dark variant.
    public var popupColorOverridesDark: [String: String] {
        get { (defaults.dictionary(forKey: Key.popupColorOverridesDark) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.popupColorOverridesDark) }
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

Five optional/defaulted UserDefaults keys backing the upcoming popup
style settings. Color overrides are per-appearance (light + dark dicts).
Absent keys reproduce today's appearance.
EOF
```

---

## Task 2: `OverlayColors` — expose light/dark pairs

**Files:**
- Modify: `Sources/OpWhoLib/OverlayColors.swift`
- Test: `Tests/OverlayColorsContrastTests.swift` (new suite appended; existing contrast assertions untouched)

The role colors are currently pre-built dynamic `NSColor`s; the raw `(light, dark)` pair is inaccessible. Per-appearance overrides need to fall back one side at a time, and the Appearance tab needs concrete per-appearance values to validate against — so expose the pairs.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/OverlayColorsContrastTests.swift`:

```swift
@Suite("OverlayColors pairs")
struct OverlayColorsPairTests {
    private func resolvedSRGB(_ c: NSColor, dark: Bool) -> (r: Double, g: Double, b: Double) {
        OverlayColors.srgb(OverlayColors.resolved(c, dark: dark))
    }

    @Test("dynamic role colors resolve to their exposed pairs")
    func pairsMatchDynamics() {
        let cases: [(NSColor, (light: NSColor, dark: NSColor))] = [
            (OverlayColors.claude, OverlayColors.claudePair),
            (OverlayColors.editor, OverlayColors.editorPair),
            (OverlayColors.verifiedOp, OverlayColors.verifiedOpPair),
            (OverlayColors.unverifiedOp, OverlayColors.unverifiedOpPair),
            (OverlayColors.ssh, OverlayColors.sshPair),
            (OverlayColors.gitRoot, OverlayColors.gitRootPair),
            (OverlayColors.branch, OverlayColors.branchPair),
            (OverlayColors.worktree, OverlayColors.worktreePair),
        ]
        for (dyn, pair) in cases {
            #expect(resolvedSRGB(dyn, dark: false) == OverlayColors.srgb(pair.light))
            #expect(resolvedSRGB(dyn, dark: true) == OverlayColors.srgb(pair.dark))
        }
    }

    @Test("system-color pairs resolve per appearance")
    func systemPairsResolve() {
        // dimLabel/brightValue/background come from system colors; the pair
        // must be the concrete per-appearance resolution of the same color.
        #expect(OverlayColors.srgb(OverlayColors.dimLabelPair.light)
            == resolvedSRGB(OverlayColors.dimLabel, dark: false))
        #expect(OverlayColors.srgb(OverlayColors.brightValuePair.dark)
            == resolvedSRGB(OverlayColors.brightValue, dark: true))
    }

    @Test("background pair spans light to dark")
    func backgroundPairOrdering() {
        let bp = OverlayColors.backgroundPair
        let light = OverlayColors.srgb(bp.light)
        let dark = OverlayColors.srgb(bp.dark)
        #expect(contrastRatio(light, dark) > 10)   // white vs ~#1E1E1E ≈ 17:1
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OverlayColorsPair 2>&1 | tail -20`
Expected: FAIL — `type 'OverlayColors' has no member 'claudePair'` (etc.).

- [ ] **Step 3: Restructure `OverlayColors`**

Replace the body of `Sources/OpWhoLib/OverlayColors.swift`'s `OverlayColors` enum (keep the file's `contrastRatio` free function unchanged) with:

```swift
public enum OverlayColors {
    /// The popup's window background.
    public static let background = NSColor.windowBackgroundColor

    // Concrete (light, dark) values behind each themeable role. Exposed so
    // per-appearance overrides can fall back one side at a time and the
    // Appearance tab can validate each side against its own background.
    // TUNE these until the contrast test passes: darken the light value /
    // lighten the dark value to raise ratio.
    public static let claudePair: (light: NSColor, dark: NSColor) = (
        light: NSColor(srgbRed: 0.42, green: 0.20, blue: 0.60, alpha: 1),
        dark:  NSColor(srgbRed: 0.78, green: 0.60, blue: 0.98, alpha: 1))
    public static let editorPair: (light: NSColor, dark: NSColor) = (
        light: NSColor(srgbRed: 0.0, green: 0.42, blue: 0.45, alpha: 1),
        dark:  NSColor(srgbRed: 0.40, green: 0.85, blue: 0.90, alpha: 1))
    public static let verifiedOpPair: (light: NSColor, dark: NSColor) = (
        light: NSColor(srgbRed: 0.0, green: 0.45, blue: 0.20, alpha: 1),
        dark:  NSColor(srgbRed: 0.40, green: 0.85, blue: 0.55, alpha: 1))
    public static let unverifiedOpPair: (light: NSColor, dark: NSColor) = (
        light: NSColor(srgbRed: 0.62, green: 0.33, blue: 0.0, alpha: 1),
        dark:  NSColor(srgbRed: 1.0, green: 0.70, blue: 0.30, alpha: 1))
    public static let sshPair: (light: NSColor, dark: NSColor) = (
        light: NSColor(srgbRed: 0.0, green: 0.35, blue: 0.80, alpha: 1),
        dark:  NSColor(srgbRed: 0.45, green: 0.72, blue: 1.0, alpha: 1))

    // Dedicated location-field colors. Each of git-root / branch / worktree
    // keeps its own hue in a fixed row so the value can be found by color as
    // well as position. Chosen from the palette's still-free hues (gold, rose,
    // slate) so they don't echo the action/who row colors above them.
    public static let gitRootPair: (light: NSColor, dark: NSColor) = (
        light: NSColor(srgbRed: 0.56, green: 0.42, blue: 0.0, alpha: 1),
        dark:  NSColor(srgbRed: 0.93, green: 0.77, blue: 0.33, alpha: 1))
    public static let branchPair: (light: NSColor, dark: NSColor) = (
        light: NSColor(srgbRed: 0.74, green: 0.14, blue: 0.44, alpha: 1),
        dark:  NSColor(srgbRed: 1.0, green: 0.55, blue: 0.80, alpha: 1))
    public static let worktreePair: (light: NSColor, dark: NSColor) = (
        light: NSColor(srgbRed: 0.24, green: 0.36, blue: 0.56, alpha: 1),
        dark:  NSColor(srgbRed: 0.62, green: 0.74, blue: 0.95, alpha: 1))

    // The appearance-aware colors the popup actually renders with.
    public static let claude = dynamic(claudePair)
    public static let editor = dynamic(editorPair)
    public static let verifiedOp = dynamic(verifiedOpPair)
    public static let unverifiedOp = dynamic(unverifiedOpPair)
    public static let ssh = dynamic(sshPair)
    public static let gitRoot = dynamic(gitRootPair)
    public static let branch = dynamic(branchPair)
    public static let worktree = dynamic(worktreePair)

    public static let dimLabel = NSColor.secondaryLabelColor
    public static let brightValue = NSColor.labelColor

    // System-color roles resolved to concrete per-appearance values.
    public static var dimLabelPair: (light: NSColor, dark: NSColor) {
        (resolved(.secondaryLabelColor, dark: false), resolved(.secondaryLabelColor, dark: true))
    }
    public static var brightValuePair: (light: NSColor, dark: NSColor) {
        (resolved(.labelColor, dark: false), resolved(.labelColor, dark: true))
    }
    /// The popup background as concrete per-appearance values (white in
    /// light mode, ~#1E1E1E in dark on current macOS).
    public static var backgroundPair: (light: NSColor, dark: NSColor) {
        (resolved(.windowBackgroundColor, dark: false), resolved(.windowBackgroundColor, dark: true))
    }

    /// Build an appearance-aware color from a light/dark pair.
    static func dynamic(_ pair: (light: NSColor, dark: NSColor)) -> NSColor {
        dynamic(light: pair.light, dark: pair.dark)
    }

    /// Build an appearance-aware color from a light/dark pair.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    /// Resolve an appearance-dependent color (dynamic or system) to its
    /// concrete sRGB value in the given appearance.
    public static func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = color
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    /// Resolve `color` to sRGB components in the current drawing appearance.
    public static func srgb(_ color: NSColor) -> (r: Double, g: Double, b: Double) {
        let c = (color.usingColorSpace(.sRGB) ?? color)
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter OverlayColors 2>&1 | tail -20`
Expected: PASS — both the new pair suite and the pre-existing contrast assertions (the dynamic colors are built from the same values as before).

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/OverlayColors.swift Tests/OverlayColorsContrastTests.swift
git commit -F - <<'EOF'
refactor: expose light/dark pairs behind OverlayColors roles

The dynamic role colors are now built from public (light, dark) pair
constants; system-color roles and the popup background gain resolved
per-appearance pairs. Needed for per-appearance overrides and the
contrast badges in the Appearance tab.
EOF
```

---

## Task 3: `PopupStyle` — color roles and per-appearance resolution

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
    private func resolved(_ c: NSColor, dark: Bool) -> (r: Double, g: Double, b: Double) {
        OverlayColors.srgb(OverlayColors.resolved(c, dark: dark))
    }

    @Test("no override returns the role default in both appearances")
    func defaultColor() {
        let style = PopupStyle.default
        for role in PopupColorRole.allCases {
            #expect(resolved(style.color(role), dark: false) == resolved(role.defaultColor, dark: false))
            #expect(resolved(style.color(role), dark: true) == resolved(role.defaultColor, dark: true))
        }
    }

    @Test("a light-only override changes light and keeps the dark default")
    func lightOnlyOverride() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overridesLight: ["claude": "#112233"], overridesDark: [:]
        )
        let c = style.color(.claude)
        #expect(resolved(c, dark: false) == OverlayColors.srgb(NSColor(popupHex: "#112233")!))
        #expect(resolved(c, dark: true) == resolved(PopupColorRole.claude.defaultPair.dark, dark: true))
    }

    @Test("a dark-only override changes dark and keeps the light default")
    func darkOnlyOverride() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overridesLight: [:], overridesDark: ["branch": "#445566"]
        )
        let c = style.color(.branch)
        #expect(resolved(c, dark: true) == OverlayColors.srgb(NSColor(popupHex: "#445566")!))
        #expect(resolved(c, dark: false) == resolved(PopupColorRole.branch.defaultPair.light, dark: false))
    }

    @Test("an invalid hex falls back to the default for that side only")
    func invalidOverride() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overridesLight: ["ssh": "not-a-color"], overridesDark: ["ssh": "#012345"]
        )
        let c = style.color(.ssh)
        #expect(resolved(c, dark: false) == resolved(PopupColorRole.ssh.defaultPair.light, dark: false))
        #expect(resolved(c, dark: true) == OverlayColors.srgb(NSColor(popupHex: "#012345")!))
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

- [ ] **Step 3: Implement `PopupStyle.swift` (colors + hex, fonts)**

Create `Sources/OpWhoLib/PopupStyle.swift`:

```swift
import AppKit

/// Semantic color roles the popup renders. Raw value is the stable storage
/// key used in `AppSettings.popupColorOverridesLight/Dark`.
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

    /// The default's concrete (light, dark) values, for per-side fallback.
    public var defaultPair: (light: NSColor, dark: NSColor) {
        switch self {
        case .claude:       return OverlayColors.claudePair
        case .editor:       return OverlayColors.editorPair
        case .verifiedOp:   return OverlayColors.verifiedOpPair
        case .unverifiedOp: return OverlayColors.unverifiedOpPair
        case .ssh:          return OverlayColors.sshPair
        case .gitRoot:      return OverlayColors.gitRootPair
        case .branch:       return OverlayColors.branchPair
        case .worktree:     return OverlayColors.worktreePair
        case .dimLabel:     return OverlayColors.dimLabelPair
        case .brightValue:  return OverlayColors.brightValuePair
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
    private let overridesLight: [String: String]
    private let overridesDark: [String: String]

    /// Reproduces today's appearance: system fonts, base 12, no overrides.
    public static let `default` = PopupStyle(
        uiFontName: nil, monoFontName: nil, baseSize: 12,
        overridesLight: [:], overridesDark: [:]
    )

    public init(uiFontName: String?, monoFontName: String?, baseSize: CGFloat,
                overridesLight: [String: String], overridesDark: [String: String]) {
        self.uiFontName = uiFontName
        self.monoFontName = monoFontName
        self.baseSize = baseSize
        self.overridesLight = overridesLight
        self.overridesDark = overridesDark
    }

    public init(settings: AppSettings) {
        self.init(
            uiFontName: settings.popupUIFontName,
            monoFontName: settings.popupMonoFontName,
            baseSize: CGFloat(settings.popupFontBaseSize),
            overridesLight: settings.popupColorOverridesLight,
            overridesDark: settings.popupColorOverridesDark
        )
    }

    /// The effective appearance-aware color for a role: each side is the
    /// user's override for that appearance, or the default variant.
    public func color(_ role: PopupColorRole) -> NSColor {
        let light = overridesLight[role.rawValue].flatMap { NSColor(popupHex: $0) }
        let dark = overridesDark[role.rawValue].flatMap { NSColor(popupHex: $0) }
        if light == nil && dark == nil { return role.defaultColor }
        let pair = role.defaultPair
        return OverlayColors.dynamic(light: light ?? pair.light, dark: dark ?? pair.dark)
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
feat: add PopupStyle resolver with per-appearance color overrides

PopupColorRole maps each popup color to its OverlayColors default (and
its light/dark pair); PopupStyle.color composes a dynamic color from
the per-appearance override or the default variant, side by side. Adds
NSColor(popupHex:)/popupHexString for persistence.
EOF
```

---

## Task 4: `PopupStyle` — font and size resolution

**Files:**
- Test: `Tests/PopupStyleTests.swift`
- (Implementation already written in Task 3; this task adds the font/size tests that lock its behavior.)

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
        let s = PopupStyle(uiFontName: nil, monoFontName: nil, baseSize: 16,
                           overridesLight: [:], overridesDark: [:])
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
        let s = PopupStyle(uiFontName: "No Such Font XYZ", monoFontName: nil, baseSize: 12,
                           overridesLight: [:], overridesDark: [:])
        let f = s.font(.ui, weight: .semibold, tier: .large)
        #expect(f.pointSize == 13)   // still sized correctly
    }

    @Test("a real custom family is honored")
    func customFamilyHonored() {
        let s = PopupStyle(uiFontName: "Menlo", monoFontName: nil, baseSize: 12,
                           overridesLight: [:], overridesDark: [:])
        let f = s.font(.ui, weight: .regular, tier: .base)
        #expect(f.familyName == "Menlo")
        #expect(f.pointSize == 12)
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter PopupStyleFont 2>&1 | tail -20`
Expected: PASS (implementation from Task 3 already satisfies these).

Note: if `unknownFamilyFallsBack` fails because `NSFont(descriptor:)` synthesized a font at the wrong size, harden `PopupStyle.font` by also asserting the resolved font's `familyName != nil`; but the descriptor path returns nil for unknown families on macOS, so the system fallback runs. Do not change the test.

- [ ] **Step 3: Commit**

```bash
git add Tests/PopupStyleTests.swift
git commit -F - <<'EOF'
test: lock PopupStyle font tiers, size scaling, and family fallback
EOF
```

---

## Task 5: `snapToContrast`

**Files:**
- Create: `Sources/OpWhoLib/ContrastSnap.swift`
- Test: `Tests/ContrastSnapTests.swift`

The badge's one-click fix: given a failing color, return the nearest color
(same hue, then reduced saturation only if needed) meeting the ratio against a
background. Pure sRGB math, no AppKit views.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ContrastSnapTests.swift`:

```swift
import Testing
@testable import OpWhoLib

@Suite("snapToContrast")
struct ContrastSnapTests {
    // The popup's real backgrounds: white (light) and #1E1E1E (dark).
    let lightBG = (r: 1.0, g: 1.0, b: 1.0)
    let darkBG = (r: 30.0 / 255, g: 30.0 / 255, b: 30.0 / 255)

    @Test("full hue sweep snaps to passing against both backgrounds")
    func hueSweep() {
        for deg in stride(from: 0, to: 360, by: 15) {
            let c = hsbToRGB(h: Double(deg), s: 1, v: 1)
            for bg in [lightBG, darkBG] {
                let snapped = snapToContrast(c, against: bg)
                #expect(contrastRatio(snapped, bg) >= 4.5,
                        "hue \(deg) failed: got \(contrastRatio(snapped, bg))")
            }
        }
    }

    @Test("already-passing input is returned unchanged")
    func idempotent() {
        let navy = (r: 0.0, g: 0.0, b: 0.5)
        let snapped = snapToContrast(navy, against: lightBG)
        #expect(snapped == navy)
    }

    @Test("hue and saturation are preserved when reachable")
    func huePreserved() {
        let lightRed = (r: 1.0, g: 0.6, b: 0.6)   // fails on white
        let snapped = snapToContrast(lightRed, against: lightBG)
        #expect(contrastRatio(snapped, lightBG) >= 4.5)
        let (h, s, _) = rgbToHSB(snapped)
        #expect(min(h, 360 - h) < 2)   // still red
        #expect(abs(s - 0.4) < 0.02)   // saturation untouched
    }

    @Test("saturated blue desaturates against the dark background")
    func blueDesaturates() {
        // Pure blue maxes out at Y ≈ 0.072, below the ≈0.23 floor the dark
        // background demands — unreachable at full saturation.
        let blue = (r: 0.0, g: 0.0, b: 1.0)
        let snapped = snapToContrast(blue, against: darkBG)
        #expect(contrastRatio(snapped, darkBG) >= 4.5)
        let (_, s, _) = rgbToHSB(snapped)
        #expect(s < 1.0)
    }

    @Test("grayscale extremes snap fine")
    func extremes() {
        let white = (r: 1.0, g: 1.0, b: 1.0)
        let black = (r: 0.0, g: 0.0, b: 0.0)
        #expect(contrastRatio(snapToContrast(white, against: lightBG), lightBG) >= 4.5)
        #expect(contrastRatio(snapToContrast(black, against: darkBG), darkBG) >= 4.5)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ContrastSnap 2>&1 | tail -20`
Expected: FAIL — `cannot find 'snapToContrast' in scope`.

- [ ] **Step 3: Implement `ContrastSnap.swift`**

Create `Sources/OpWhoLib/ContrastSnap.swift`:

```swift
import Foundation

/// Nearest color to `color` (same hue; saturation reduced only if that hue
/// can't reach the ratio at any brightness) meeting `ratio` against
/// `background`. Used by the Appearance tab's contrast badges — guide, don't
/// block: the caller decides whether to apply the result.
///
/// Relies on WCAG relative luminance being strictly monotonic in HSB
/// brightness at fixed hue/saturation, so each pass/fail boundary is a single
/// brightness value found by bisection.
public func snapToContrast(
    _ color: (r: Double, g: Double, b: Double),
    against background: (r: Double, g: Double, b: Double),
    ratio: Double = 4.5
) -> (r: Double, g: Double, b: Double) {
    if contrastRatio(color, background) >= ratio { return color }

    let (h, s, v) = rgbToHSB(color)
    // Aim slightly past the requested ratio so 8-bit quantization of the
    // result can't round it back below threshold.
    let target = ratio + 0.06

    var sat = s
    while true {
        if let snapped = snapBrightness(h: h, s: sat, v: v, background: background,
                                        target: target, minimum: ratio) {
            return snapped
        }
        if sat <= 0 { break }
        sat = max(0, sat - 0.05)
    }
    // Unreachable for real backgrounds (grayscale always spans the required
    // luminance), but keep a safe fallback.
    let black = (r: 0.0, g: 0.0, b: 0.0)
    let white = (r: 1.0, g: 1.0, b: 1.0)
    return contrastRatio(black, background) >= contrastRatio(white, background) ? black : white
}

/// At fixed hue/saturation, find the brightness nearest `v` whose color meets
/// `target` against `background`; nil if no brightness at this saturation can.
private func snapBrightness(
    h: Double, s: Double, v: Double,
    background: (r: Double, g: Double, b: Double),
    target: Double, minimum: Double
) -> (r: Double, g: Double, b: Double)? {
    func ratioAt(_ vv: Double) -> Double {
        contrastRatio(hsbToRGB(h: h, s: s, v: vv), background)
    }

    var best: (r: Double, g: Double, b: Double)?
    var bestDist = Double.infinity

    func consider(_ vv: Double) {
        let c = quantize(hsbToRGB(h: h, s: s, v: vv))
        guard contrastRatio(c, background) >= minimum, abs(vv - v) < bestDist else { return }
        best = c
        bestDist = abs(vv - v)
    }

    // Darker-than-background branch: contrast decreases as brightness rises.
    // Feasible iff v=0 (black-ward extreme) passes; bisect to the largest
    // passing brightness (the one nearest the input from below).
    if ratioAt(0) >= target {
        var lo = 0.0, hi = 1.0          // invariant: ratioAt(lo) >= target
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if ratioAt(mid) >= target { lo = mid } else { hi = mid }
        }
        consider(lo)
    }
    // Lighter-than-background branch: contrast increases as brightness rises.
    // Feasible iff v=1 passes; bisect to the smallest passing brightness.
    if ratioAt(1) >= target {
        var lo = 0.0, hi = 1.0          // invariant: ratioAt(hi) >= target
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if ratioAt(mid) >= target { hi = mid } else { lo = mid }
        }
        consider(hi)
    }
    return best
}

/// Round each channel to the nearest 8-bit value, matching what persisting
/// as #RRGGBB will store.
private func quantize(_ c: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
    ((c.r * 255).rounded() / 255, (c.g * 255).rounded() / 255, (c.b * 255).rounded() / 255)
}

func rgbToHSB(_ c: (r: Double, g: Double, b: Double)) -> (h: Double, s: Double, v: Double) {
    let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
    let d = mx - mn
    var h = 0.0
    if d > 0 {
        switch mx {
        case c.r: h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6)
        case c.g: h = (c.b - c.r) / d + 2
        default:  h = (c.r - c.g) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
    }
    return (h, mx == 0 ? 0 : d / mx, mx)
}

func hsbToRGB(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
    let c = v * s
    let hp = h / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r1, g1, b1): (Double, Double, Double)
    switch hp {
    case ..<1: (r1, g1, b1) = (c, x, 0)
    case ..<2: (r1, g1, b1) = (x, c, 0)
    case ..<3: (r1, g1, b1) = (0, c, x)
    case ..<4: (r1, g1, b1) = (0, x, c)
    case ..<5: (r1, g1, b1) = (x, 0, c)
    default:   (r1, g1, b1) = (c, 0, x)
    }
    let m = v - c
    return (r1 + m, g1 + m, b1 + m)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ContrastSnap 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/ContrastSnap.swift Tests/ContrastSnapTests.swift
git commit -F - <<'EOF'
feat: add snapToContrast for one-click WCAG fixes

Bisects HSB brightness (luminance is monotonic in brightness at fixed
hue/saturation) to the nearest color meeting the ratio, desaturating
only when the hue can't reach it. Targets slightly past the ratio so
8-bit quantization can't undercut it.
EOF
```

---

## Task 6: Route `OverlayPanel` through `PopupStyle`

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

## Task 7: Sample entry factory + wire `style` into live popups

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
                                 baseSize: 14,
                                 overridesLight: ["claude": "#AA33FF"],
                                 overridesDark: ["claude": "#CC77FF"])
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

## Task 8: Slim `GeneralPane` down to "Run on startup"

**Files:**
- Modify: `Sources/op-who/GeneralPane.swift`

Dense-popup and appearance controls move to `AppearancePane` (Task 9). `GeneralPane` keeps only the startup toggle and its `SMAppService` wiring.

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

## Task 9: Create `AppearancePane` (with contrast badges)

**Files:**
- Create: `Sources/op-who/AppearancePane.swift`

Holds: Dense popup checkbox, System/Light/Dark segmented control, UI/Mono font family popups, base-size stepper, a **Light and a Dark color well per role — each with a live WCAG AA contrast badge (click a failing badge to snap to the nearest passing color)**, Restore defaults, and Show/Hide Preview. Every control writes to `AppSettings` immediately.

- [ ] **Step 1: Write the pane**

Create `Sources/op-who/AppearancePane.swift`:

```swift
import AppKit
import OpWhoLib

/// The Appearance tab: all popup visual settings. Each control writes to
/// AppSettings immediately, so the Preview button (and the next real popup)
/// reflect changes without an explicit save.
///
/// Each color well carries a WCAG contrast badge computed against the popup
/// background for that well's appearance. Guide, don't block: a failing color
/// stays selectable; clicking its badge snaps to the nearest passing color.
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

    // Colors: a Light and a Dark well (+ contrast badge) per role.
    private var lightWells: [PopupColorRole: NSColorWell] = [:]
    private var darkWells: [PopupColorRole: NSColorWell] = [:]
    private var lightBadges: [PopupColorRole: NSButton] = [:]
    private var darkBadges: [PopupColorRole: NSButton] = [:]

    // Preview.
    private var previewPanel: OverlayPanel?

    private static let systemDefaultTitle = "System default"
    private static let requiredRatio = 4.5

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

    private func columnLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.boldSystemFont(ofSize: 11)
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

    /// Grid: role name · Light well · badge · Dark well · badge.
    private func colorGrid() -> NSView {
        let header: [NSView] = [
            NSTextField(labelWithString: ""),
            columnLabel("Light"), NSTextField(labelWithString: ""),
            columnLabel("Dark"), NSTextField(labelWithString: ""),
        ]
        let rows: [[NSView]] = [header] + PopupColorRole.allCases.map { role in
            let name = NSTextField(labelWithString: role.rawValue)
            name.font = NSFont.systemFont(ofSize: 12)
            let (lightWell, lightBadge) = makeWellAndBadge(role: role, dark: false)
            let (darkWell, darkBadge) = makeWellAndBadge(role: role, dark: true)
            lightWells[role] = lightWell
            lightBadges[role] = lightBadge
            darkWells[role] = darkWell
            darkBadges[role] = darkBadge
            return [name, lightWell, lightBadge, darkWell, darkBadge]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .leading }
        return grid
    }

    private func makeWellAndBadge(role: PopupColorRole, dark: Bool) -> (NSColorWell, NSButton) {
        let well = NSColorWell()
        well.color = effectiveColor(role: role, dark: dark)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.tag = tag(role: role, dark: dark)

        let badge = NSButton(title: "", target: self, action: #selector(badgeClicked(_:)))
        badge.isBordered = false
        badge.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        badge.tag = tag(role: role, dark: dark)
        badge.toolTip = "WCAG contrast vs. the popup background. "
            + "Click a failing badge to snap to the nearest passing color."
        refreshBadge(badge, color: well.color, dark: dark)
        return (well, badge)
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

    // MARK: - Colors, badges, snapping

    /// Encode role+side as an NSControl tag: role index × 2, +1 for dark.
    private func tag(role: PopupColorRole, dark: Bool) -> Int {
        (PopupColorRole.allCases.firstIndex(of: role) ?? 0) * 2 + (dark ? 1 : 0)
    }

    private func roleAndSide(forTag tag: Int) -> (role: PopupColorRole, dark: Bool)? {
        let all = PopupColorRole.allCases
        let idx = tag / 2
        guard all.indices.contains(idx) else { return nil }
        return (all[idx], tag % 2 == 1)
    }

    /// The user's override for this side, or the default variant, as a
    /// concrete (non-dynamic) color the well and badge can use directly.
    private func effectiveColor(role: PopupColorRole, dark: Bool) -> NSColor {
        let overrides = dark ? settings.popupColorOverridesDark : settings.popupColorOverridesLight
        if let hex = overrides[role.rawValue], let c = NSColor(popupHex: hex) { return c }
        let pair = role.defaultPair
        return OverlayColors.resolved(dark ? pair.dark : pair.light, dark: dark)
    }

    private func backgroundSRGB(dark: Bool) -> (r: Double, g: Double, b: Double) {
        let pair = OverlayColors.backgroundPair
        return OverlayColors.srgb(dark ? pair.dark : pair.light)
    }

    private func refreshBadge(_ badge: NSButton, color: NSColor, dark: Bool) {
        let fg = OverlayColors.srgb(OverlayColors.resolved(color, dark: dark))
        let ratio = contrastRatio(fg, backgroundSRGB(dark: dark))
        let passing = ratio >= Self.requiredRatio
        badge.title = String(format: "%.1f %@", ratio, passing ? "✓" : "✗")
        badge.contentTintColor = passing ? .secondaryLabelColor : .systemOrange
        badge.isEnabled = !passing
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
        guard let (role, dark) = roleAndSide(forTag: sender.tag) else { return }
        var overrides = dark ? settings.popupColorOverridesDark : settings.popupColorOverridesLight
        overrides[role.rawValue] = sender.color.popupHexString
        if dark { settings.popupColorOverridesDark = overrides }
        else { settings.popupColorOverridesLight = overrides }
        if let badge = dark ? darkBadges[role] : lightBadges[role] {
            refreshBadge(badge, color: sender.color, dark: dark)
        }
    }

    @objc private func badgeClicked(_ sender: NSButton) {
        guard let (role, dark) = roleAndSide(forTag: sender.tag),
              let well = dark ? darkWells[role] : lightWells[role] else { return }
        let fg = OverlayColors.srgb(OverlayColors.resolved(well.color, dark: dark))
        let snapped = snapToContrast(fg, against: backgroundSRGB(dark: dark),
                                     ratio: Self.requiredRatio)
        well.color = NSColor(srgbRed: snapped.r, green: snapped.g, blue: snapped.b, alpha: 1)
        colorChanged(well)   // persist + badge refresh via the normal path
    }

    @objc private func restoreDefaults(_ sender: NSButton) {
        settings.popupColorOverridesLight = [:]
        settings.popupColorOverridesDark = [:]
        for role in PopupColorRole.allCases {
            for dark in [false, true] {
                guard let well = dark ? darkWells[role] : lightWells[role],
                      let badge = dark ? darkBadges[role] : lightBadges[role] else { continue }
                well.color = effectiveColor(role: role, dark: dark)
                refreshBadge(badge, color: well.color, dark: dark)
            }
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
Expected: build succeeds (nothing references `AppearancePane` yet; unused types are not an error in Swift).

- [ ] **Step 3: Commit**

```bash
git add Sources/op-who/AppearancePane.swift
git commit -F - <<'EOF'
feat: add AppearancePane with per-appearance color wells and WCAG badges

New Appearance-tab pane owning dense-popup, light/dark, font family
popups, base-size stepper, and a Light+Dark color well per role. Each
well shows a live WCAG AA contrast badge against its own popup
background; clicking a failing badge snaps to the nearest passing
color (guide, don't block). Includes restore-defaults and a Show/Hide
Preview backed by OverlayPanel.sampleEntry.
EOF
```

---

## Task 10: Tabbed Settings window

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
- **Appearance** shows dense popup, System/Light/Dark, UI/Mono font popups, base-size stepper, the Light/Dark color-well grid with contrast badges, "Restore default colors", and Show/Hide Preview.
- All default colors show passing badges (`✓`) in both columns.
- Pick a pale yellow in a Light well → badge flips to `✗` (orange, enabled); click the badge → the well darkens to a same-hue passing color and the badge flips to `✓`.
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

## Task 11: Full verification & docs

**Files:**
- Modify: `CLAUDE.md` (document the new settings surface)

- [ ] **Step 1: Full build + test**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected: build succeeds; all tests pass (AppSettings, PopupStyle, ContrastSnap, OverlayColors pairs + contrast, OverlayPanel, BodyTable, and the rest).

- [ ] **Step 2: Update `CLAUDE.md`**

In the "Key design decisions" list, append a bullet after the popup-body bullet:

```markdown
- Popup fonts and colors are configurable (`PopupStyle.swift`): `AppSettings` stores an optional UI-font family, mono-font family, a base size (default 12; the popup's three tiers render at base−1/base/base+1), and **per-appearance** color overrides (`popupColorOverridesLight`/`popupColorOverridesDark`, keyed by `PopupColorRole.rawValue`). `PopupStyle` resolves each request to a concrete `NSFont`/`NSColor`, composing each appearance side from the override or the `OverlayColors` default pair; `OverlayColors` stays the home of the defaults (now exposed as `(light, dark)` pairs) and the contrast test. The Settings window is an `NSTabView` (General / Appearance / Rules): `GeneralPane` holds only Run-on-startup; `AppearancePane` owns dense-popup, light/dark, the font pickers, size stepper, a Light+Dark color well per role — each with a live WCAG AA contrast badge against its own popup background, click a failing badge to snap to the nearest passing color via `snapToContrast` (`ContrastSnap.swift`; guide, don't block) — and a Show/Hide Preview backed by `OverlayPanel.sampleEntry()`.
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

- **Regression guard:** Tasks 1-5 are pure TDD. Task 6 is a behavior-preserving refactor — its guard is that the *existing* `OverlayPanelTests`, `BodyTableRenderTests`, and `OverlayColorsContrastTests` stay green with the default style.
- **WCAG guidance, not enforcement:** the contrast badges + snap are advisory (guide, don't block). A failing custom color is the user's call; the contrast test still guards only the built-in defaults.
- **Per-appearance overrides:** each role stores an independent light and dark hex (`popupColorOverridesLight`/`Dark`). This is what makes AA 4.5:1 achievable — no single static color can pass against both the white light-mode background and the ~#1E1E1E dark-mode background (their compliant luminance intervals don't intersect; see the WCAG spec's math appendix).
- **Chrome stays fixed:** the "▸ details" toggle, the Show Tab / Send Message buttons, and the secondary/tertiary system label colors are intentionally *not* themed or scaled.
- **Commit message hygiene:** all commits above use single-quoted HEREDOCs so backticks aren't interpolated (see `CLAUDE.md`). Never advertise the assistant in commit messages.
