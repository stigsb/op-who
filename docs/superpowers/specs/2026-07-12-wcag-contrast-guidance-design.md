# WCAG Contrast Guidance for Color Settings — Design

**Date:** 2026-07-12 (revised same day to match the shipped popup-style settings)
**Status:** Approved for planning

## Goal

When the user customizes popup colors in the Appearance tab, show live WCAG AA
contrast feedback against the popup background and offer a one-click fix —
without ever blocking their choice. **Guide, don't enforce.**

## Context: what already exists

The popup style settings shipped on main with per-appearance color overrides:

- `AppSettings.popupColorOverrides` is one `[String: String]` dict keyed
  `"<role>.<variant>"` (e.g. `"claude.light"`), value `#RRGGBB`
  (`PopupStyle.overrideKey(_:_:)`).
- `PopupStyle.color(_:variant:)` returns the effective **concrete** color for
  one variant: the override if set, else the WCAG default resolved in that
  appearance.
- The Appearance tab shows **one well per role** with an
  **"Editing: Light | Dark"** segmented selector (`colorVariant`); wells reload
  on variant switch (`reloadColorWells`).
- `OverlayColors.resolved(_:in:)` (internal) resolves a dynamic color in a
  given appearance; `contrastRatio` is public.

Per-appearance overrides are what make AA 4.5:1 achievable at all: the popup
background resolves to pure white in light mode and ~`#1E1E1E` in dark mode,
and the compliant luminance intervals for those two backgrounds (Y ≤ 0.183 vs.
Y ≥ 0.233) do not intersect — no single color can pass 4.5:1 in both modes.

## Decisions (from brainstorming)

- **Posture: guide, don't block.** The Chrome-DevTools pattern (visible
  verdict + snap-to-passing), not a hard mask. A user can keep a failing
  color; the badge just says so. Prior art surveyed: Chrome DevTools contrast
  line, wcagwheel.com isolines, Stripe's masked palette tool, Adobe Leonardo's
  contrast-as-input. No off-the-shelf Swift component does any of this;
  NSColorPanel/SwiftUI ColorPicker have no constraint or masking hooks.
- **Scope: badge + snap only.** Standard `NSColorWell`s stay; guidance lives
  next to them. No custom wheel/slider picker.
- **Fit the shipped UI.** Each color cell gains a badge for the variant
  currently being edited; the badge re-evaluates when the well changes, when
  the Light|Dark selector switches, and on restore-defaults. (The brainstorm's
  "two wells per role" grid was superseded by the shipped Light|Dark selector.)
- **Threshold: AA 4.5:1**, matching the existing
  `OverlayColorsContrastTests` guard on the defaults.

## Non-goals

- No hard mask; failing colors remain selectable and persistable.
- No custom color-picker view (wheel with contrast contour, clamped
  brightness slider). Parked; the math notes below are kept for a future
  iteration.
- No APCA / WCAG 3 scoring.
- No schema changes — the shipped `"role.variant"` key format stays.

## Architecture

### 1. Snap function (`Sources/OpWhoLib/ContrastSnap.swift`, new)

```swift
/// Nearest color to `color` (same hue, then reduced saturation if needed)
/// meeting `ratio` against `background`. Pure sRGB math, no AppKit views.
public func snapToContrast(_ color: (r: Double, g: Double, b: Double),
                           against background: (r: Double, g: Double, b: Double),
                           ratio: Double = 4.5) -> (r: Double, g: Double, b: Double)
```

- Hold hue and saturation; luminance is strictly monotonic in HSB brightness,
  so bisect brightness to the nearest crossing of the required contrast.
  Target ~ratio+0.06 rather than the exact ratio so 8-bit quantization cannot
  round the result back below threshold.
- If no brightness passes at that hue/saturation (e.g. a saturated blue maxes
  out at Y = 0.072, below dark mode's 0.233 floor), progressively reduce
  saturation and retry; grayscale always reaches a passing luminance against
  these backgrounds, so the function effectively always returns a passing
  color (black/white fallback guards the theoretical empty case).
- Already-passing input is returned unchanged (idempotent).
- Direction choice: the passing branch (darker vs. lighter than background)
  whose boundary is nearest in brightness; against near-white / near-black
  backgrounds only one branch is feasible anyway.

### 2. Per-variant background (`OverlayColors`)

The badge compares against the popup background **for the variant being
edited**, not the current app appearance. Make `resolved(_:in:)` public so the
settings pane can compute `OverlayColors.resolved(OverlayColors.background,
in: variant.appearanceName)` — no new API surface beyond the access level.

### 3. Contrast badges (`AppearancePane`)

Each `colorCell` becomes name → well → **badge**:

- Badge = small borderless `NSButton` showing the rounded ratio and verdict
  (`4.7 ✓` dimmed / `2.1 ✗` orange), computed with `contrastRatio` between the
  well's color and the popup background resolved in `colorVariant`'s
  appearance.
- A failing badge is enabled/clickable: click applies `snapToContrast` to the
  well's color, updates the well, persists the override through the normal
  `colorChanged` path, and refreshes the badge. A passing badge is inert.
- Badges refresh on: well change (`colorChanged`), variant switch
  (`reloadColorWells`), and restore-defaults.
- If four cells per row overflow the window's minimum width with badges
  added, drop to three cells per row.

## Data flow

```
NSColorWell edit ─▶ colorChanged ─▶ popupColorOverrides["role.variant"] ─▶ badge refresh
Light|Dark switch ─▶ reloadColorWells ─▶ wells + badges show that variant
badge click (failing) ─▶ snapToContrast(well, bg(variant)) ─▶ well.color ─▶ colorChanged
```

## Testing

All pure functions, no AppKit UI tests (`Tests/ContrastSnapTests.swift`):

- `snapToContrast` meets ≥ 4.5 against both real backgrounds (white,
  `#1E1E1E`) for a sweep of input hues.
- Hue/saturation preserved when reachable at input saturation.
- Desaturation fallback engages for saturated blue against the dark background.
- Idempotent on already-passing input; grayscale extremes handled.
- Existing suites (`PopupStyleTests`, `OverlayColorsContrastTests`) unchanged.

## Reference: the math (kept for a future custom picker)

WCAG contrast C = (Y_lighter + 0.05)/(Y_darker + 0.05); for background
luminance Yb and threshold R, a foreground of luminance Y passes iff
Y ≤ (Yb + 0.05)/R − 0.05 (darker branch) or Y ≥ R·(Yb + 0.05) − 0.05
(lighter branch). At fixed hue/saturation, Y is strictly monotonic in HSB
brightness (all linearized channels scale together), so slider clamping and
bisection are well-posed. The pass/fail boundary on a hue/saturation wheel is
hue-dependent (luminance weights 0.2126/0.7152/0.0722), i.e. a closed contour
— cheap to render per-pixel into a wheel bitmap if a contour-annotated picker
is ever built.
