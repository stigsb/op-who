# WCAG Contrast Guidance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add live WCAG AA contrast badges (with click-to-snap-to-passing) to the Appearance tab's color wells — guide, don't block.

**Architecture:** A pure `snapToContrast` function in `OpWhoLib` bisects HSB brightness to the nearest passing color. `AppearancePane`'s existing per-role color cells (one well per role, editing the variant chosen by the "Editing: Light | Dark" selector) each gain a badge button showing the contrast ratio against the popup background resolved in that variant's appearance; clicking a failing badge snaps the well. No schema or `PopupStyle` changes.

**Tech Stack:** Swift, AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-12-wcag-contrast-guidance-design.md`

**Test command** (this machine is CommandLineTools-only; symlinks under `.build/` are already in place — see CLAUDE.md if they vanish after a clean):

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW"
```

Append `--filter <pattern>` as needed. `swift build` needs no extra flags.

---

## Task 1: `snapToContrast`

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

Run: `FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" --filter ContrastSnap 2>&1 | tail -20`
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

Run: `FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" --filter ContrastSnap 2>&1 | tail -20`
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

## Task 2: Contrast badges in `AppearancePane`

**Files:**
- Modify: `Sources/OpWhoLib/OverlayColors.swift` (one access-level change)
- Modify: `Sources/op-who/AppearancePane.swift`
- Modify: `CLAUDE.md` (one sentence appended to the popup-style bullet)

AppKit UI wiring — verified by build + manual check (Step 4); the math it
calls is covered by Task 1's tests.

- [ ] **Step 1: Make `OverlayColors.resolved(_:in:)` public**

In `Sources/OpWhoLib/OverlayColors.swift`, the badge needs the popup
background resolved in the *edited variant's* appearance (not the app's
current one). Change:

```swift
    static func resolved(_ color: NSColor, in name: NSAppearance.Name) -> NSColor {
```

to:

```swift
    public static func resolved(_ color: NSColor, in name: NSAppearance.Name) -> NSColor {
```

- [ ] **Step 2: Add badges to the color cells**

In `Sources/op-who/AppearancePane.swift`, apply all of the following:

**2a.** Next to `private var colorWells` (line ~28), add:

```swift
    private var colorBadges: [PopupColorRole: NSButton] = [:]
```

**2b.** In `colorGrid()` (line ~144), change `let pairsPerRow = 4` to
`let pairsPerRow = 3` (cells grow by a badge; three per row keeps the grid
inside the window's 720pt minimum width).

**2c.** In `colorCell(for:)` (line ~165), add the badge after the well:

```swift
        let cell = NSStackView(views: [name, makeColorWell(for: role), makeBadge(for: role)])
```

**2d.** After `makeColorWell(for:)` (line ~207), add:

```swift
    /// Build and register the WCAG contrast badge for a role's well. Shows the
    /// ratio vs. the popup background in the edited variant's appearance;
    /// enabled (clickable) only when failing — click snaps to the nearest
    /// passing color. Guide, don't block: failing colors stay selectable.
    private func makeBadge(for role: PopupColorRole) -> NSButton {
        let badge = NSButton(title: "", target: self, action: #selector(badgeClicked(_:)))
        badge.isBordered = false
        badge.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        badge.tag = colorTag(for: role)
        badge.toolTip = "WCAG contrast vs. the popup background. "
            + "Click a failing badge to snap to the nearest passing color."
        badge.setContentHuggingPriority(.required, for: .horizontal)
        colorBadges[role] = badge
        refreshBadge(for: role)
        return badge
    }

    /// The popup background as sRGB components in the edited variant's
    /// appearance (white in light, ~#1E1E1E in dark).
    private func backgroundSRGB() -> (r: Double, g: Double, b: Double) {
        OverlayColors.srgb(
            OverlayColors.resolved(OverlayColors.background, in: colorVariant.appearanceName))
    }

    private static let requiredRatio = 4.5

    private func refreshBadge(for role: PopupColorRole) {
        guard let badge = colorBadges[role], let well = colorWells[role] else { return }
        let fg = OverlayColors.srgb(
            OverlayColors.resolved(well.color, in: colorVariant.appearanceName))
        let ratio = contrastRatio(fg, backgroundSRGB())
        let passing = ratio >= Self.requiredRatio
        badge.title = String(format: "%.1f %@", ratio, passing ? "✓" : "✗")
        badge.contentTintColor = passing ? .secondaryLabelColor : .systemOrange
        badge.isEnabled = !passing
    }

    private func refreshAllBadges() {
        PopupColorRole.allCases.forEach { refreshBadge(for: $0) }
    }

    @objc private func badgeClicked(_ sender: NSButton) {
        guard let role = role(forTag: sender.tag), let well = colorWells[role] else { return }
        let fg = OverlayColors.srgb(
            OverlayColors.resolved(well.color, in: colorVariant.appearanceName))
        let snapped = snapToContrast(fg, against: backgroundSRGB(), ratio: Self.requiredRatio)
        well.color = NSColor(srgbRed: snapped.r, green: snapped.g, blue: snapped.b, alpha: 1)
        colorChanged(well)   // persist + badge refresh via the normal path
    }
```

Note: `makeBadge(for:)` runs inside `colorCell(for:)` *after*
`makeColorWell(for:)` in the same views array, so `colorWells[role]` is
already registered when `refreshBadge` first runs — argument evaluation
order is left-to-right.

**2e.** In `colorChanged(_:)` (line ~322), refresh the badge after persisting.
The method becomes:

```swift
    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let role = role(forTag: sender.tag) else { return }
        var overrides = settings.popupColorOverrides
        overrides[PopupStyle.overrideKey(role, colorVariant)] = sender.color.popupHexString
        settings.popupColorOverrides = overrides
        refreshBadge(for: role)
        refreshPreviewIfShowing()
    }
```

**2f.** In `reloadColorWells()` (line ~339), refresh all badges after the
wells reload. The method becomes:

```swift
    private func reloadColorWells() {
        let style = PopupStyle(settings: settings)
        for (role, well) in colorWells {
            well.color = style.color(role, variant: colorVariant)
        }
        refreshAllBadges()
    }
```

(`colorVariantChanged` and `restoreDefaults` both call `reloadColorWells`, so
variant switches and restores refresh badges through this one hook.)

- [ ] **Step 3: Build + full test**

Run: `swift build 2>&1 | tail -5`, then
`FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks; swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" 2>&1 | tail -5`
Expected: build succeeds; all tests pass.

- [ ] **Step 4: Manual verification** (AppKit UI — not unit-testable)

```bash
scripts/bundle.sh
```

Launch the app bundle it prints, open Settings → Appearance, and confirm:
- Every color cell reads name → well → badge; all default colors show a
  dimmed passing badge (e.g. `5.2 ✓`) in both Light and Dark editing modes.
- Pick a pale yellow in a well while editing Light → badge flips to orange
  `✗` and becomes clickable; click it → the well darkens to a same-hue color
  and the badge flips back to `✓`.
- Switch Editing: Light → Dark → badges recompute against the dark background.
- Restore default colors → all badges pass again.
- The color grid still fits the window at minimum width (no clipping).

- [ ] **Step 5: Update `CLAUDE.md`**

In the "Key design decisions" list, find the bullet describing configurable
popup fonts/colors (it mentions `PopupStyle.swift`) and append this sentence
to it:

```
Each color well carries a live WCAG AA contrast badge against the popup background for the edited variant; clicking a failing badge snaps to the nearest passing color via `snapToContrast` (`ContrastSnap.swift`) — guidance only, never enforced.
```

- [ ] **Step 6: Commit**

```bash
git add Sources/OpWhoLib/OverlayColors.swift Sources/op-who/AppearancePane.swift CLAUDE.md
git commit -F - <<'EOF'
feat: WCAG contrast badges on the Appearance tab color wells

Each well shows its contrast ratio against the popup background for
the variant being edited; a failing badge is clickable and snaps the
color to the nearest passing one. Guide, don't block.
EOF
```

---

## Notes for the implementer

- **Guidance, not enforcement:** a failing custom color is the user's call;
  the badge just says so. The contrast test still guards only the built-in
  defaults.
- **Badges evaluate the edited variant**, not the app's current appearance —
  that's why the background is resolved via `colorVariant.appearanceName`.
- **Commit message hygiene:** commits use `git commit -F -` with single-quoted
  HEREDOCs so backticks aren't interpolated (see `CLAUDE.md`). Never advertise
  the assistant in commit messages.
