# WCAG Contrast Guidance for Color Settings — Design

**Date:** 2026-07-12
**Status:** Approved for planning
**Amends:** [2026-07-12-popup-style-settings-design.md](2026-07-12-popup-style-settings-design.md)
(color-override schema and Appearance-tab color grid; the rest of that design
stands as written)

## Goal

When the user customizes popup colors in the Appearance tab, show them live
WCAG AA contrast feedback against the popup background and offer a one-click
fix — without ever blocking their choice. **Guide, don't enforce.**

As a prerequisite, color overrides become **per-appearance** (a light value
and a dark value per role), replacing the single static color in the amended
design. This is what makes AA 4.5:1 achievable at all: the popup background
resolves to pure white in light mode and `#1E1E1E` in dark mode, and the
compliant luminance intervals for those two backgrounds (Y ≤ 0.183 vs.
Y ≥ 0.233) do not intersect — no single color can pass 4.5:1 in both modes.

## Decisions (from brainstorming)

- **Posture: guide, don't block.** The Chrome-DevTools pattern (visible
  verdict + snap-to-passing), not a hard mask. A user can keep a failing
  color; the badge just says so. Prior art surveyed: Chrome DevTools contrast
  line, wcagwheel.com isolines, Stripe's masked palette tool, Adobe Leonardo's
  contrast-as-input. No off-the-shelf Swift component does any of this;
  NSColorPanel/SwiftUI ColorPicker have no constraint or masking hooks.
- **Scope: badge + snap only.** Standard `NSColorWell`s stay; guidance lives
  next to them. No custom wheel/slider picker. (A contour-annotated custom
  wheel was explored and parked — see Non-goals.)
- **Per-appearance overrides, two wells per role.** Each role row shows a
  Light well and a Dark well. Each well is validated against its own
  background, so "current appearance" ambiguity disappears.
- **Threshold: AA 4.5:1**, matching the existing
  `OverlayColorsContrastTests` guard on the defaults.

## Non-goals

- No hard mask; failing colors remain selectable and persistable.
- No custom color-picker view (wheel with contrast contour, clamped
  brightness slider). Parked; the math notes below are kept for a future
  iteration.
- No APCA / WCAG 3 scoring.
- No validation of fonts/sizes (contrast is color-only).

## Architecture

### 1. Schema change: per-appearance overrides (`AppSettings`)

Replaces `popupColorOverrides` from the amended design:

| Key                        | Type              | Default | Meaning |
|----------------------------|-------------------|---------|---------|
| `popupColorOverridesLight` | `[String:String]` | `[:]`   | role key → hex sRGB `#RRGGBB`, light appearance |
| `popupColorOverridesDark`  | `[String:String]` | `[:]`   | role key → hex sRGB `#RRGGBB`, dark appearance |

Absent or unparseable value ⇒ that appearance keeps its `OverlayColors`
default for the role. No migration concerns: the single-dict key never
shipped.

### 2. `OverlayColors` refactor: expose light/dark pairs

The role colors are currently pre-built dynamic `NSColor`s; the raw pair is
inaccessible. Restructure so each role's `(light, dark)` pair is available
(e.g. a `static func pair(for: PopupColorRole) -> (light: NSColor, dark:
NSColor)` or stored pair constants the dynamic colors are built from). The
public dynamic statics keep working. `dimLabel`/`brightValue` map to concrete
resolved values per appearance (they are system colors today; resolving them
per appearance gives the pair). This also lets the existing contrast test
iterate pairs directly instead of resolving dynamic colors through appearance
tricks.

### 3. `PopupStyle.color(role)` composition

```
dynamic(light: lightOverride(role) ?? defaultLight(role),
        dark:  darkOverride(role)  ?? defaultDark(role))
```

Override lookup parses the hex dict entry; invalid ⇒ nil ⇒ default, no crash.

### 4. Snap function (`OpWhoLib`, alongside `contrastRatio`)

```swift
/// Nearest color to `color` (same hue, then reduced saturation if needed)
/// meeting `ratio` against `background`. Pure sRGB math, no AppKit views.
public func snapToContrast(_ color: RGB, against background: RGB,
                           ratio: Double = 4.5) -> RGB
```

- Hold hue and saturation; luminance is strictly monotonic in HSB brightness,
  so bisect brightness to the nearest crossing of the required luminance
  bound. Target ~4.55 rather than 4.5 exactly so 8-bit quantization cannot
  round the result back below threshold.
- If no brightness passes at that hue/saturation (e.g. a saturated blue maxes
  out at Y = 0.072, below dark mode's 0.233 floor), progressively reduce
  saturation and retry; S = 0 (grayscale) always reaches a passing luminance
  against these backgrounds, so the function always returns a passing color.
- Already-passing input is returned unchanged (idempotent).

Direction choice: pick the passing branch (darker vs. lighter than
background) whose boundary is nearest in brightness; against near-white /
near-black backgrounds only one branch is feasible anyway.

### 5. Appearance tab: color grid with badges

Each role row: label · **Light** `NSColorWell` + badge · **Dark**
`NSColorWell` + badge.

- Wells seed from the effective per-appearance value (override or default
  variant).
- Badge = small text field/button showing the rounded ratio and verdict
  (`4.7 ✓` / `2.1 ✗`), computed with the existing `contrastRatio` against the
  popup background for that column's appearance (light: white; dark:
  `#1E1E1E` — resolved from `NSColor.windowBackgroundColor` per appearance,
  not hardcoded).
- A failing badge is enabled/clickable: click applies `snapToContrast` to
  that well's color, updates the well, the override, and the badge. A passing
  badge is inert.
- Badges update live on every well change (`NSColorWell` action fires
  continuously during panel dragging).
- **Restore defaults** clears both dicts and reseeds wells and badges.

Editing a well writes to the matching dict immediately, same
write-on-change pattern as the rest of the pane.

## Data flow

```
Light/Dark NSColorWell ─writes─▶ popupColorOverridesLight/Dark (AppSettings)
        │                                        │
        └─▶ contrastRatio(color, bg(appearance)) ─▶ badge text/state
                     │
        badge click ─▶ snapToContrast ─▶ well + dict + badge update

PopupStyle(settings:) ─▶ dynamic(lightOverride ?? default, darkOverride ?? default)
```

## Testing

All in `OpWhoLib` tests (Swift Testing), pure functions — no AppKit UI tests:

- `snapToContrast`: result meets ≥ 4.5 against both real backgrounds for a
  sweep of input hues; hue preserved when reachable at input saturation;
  desaturation fallback engages for saturated blue against the dark
  background; idempotent on passing input; grayscale extremes handled.
- `PopupStyle.color`: light-only override ⇒ dark stays default (and vice
  versa); invalid hex in one dict ⇒ that side falls back, other side intact.
- `AppSettings` round-trip for the two dict keys.
- `OverlayColorsContrastTests` continues to guard the defaults, now iterating
  the exposed pairs.

## Rollout / compatibility

Purely additive; ships as part of the popup-style-settings work. The
**implementation plan `docs/superpowers/plans/2026-07-12-popup-style-settings.md`
must be amended before execution**: single `popupColorOverrides` dict → the
two per-appearance dicts, one well per role → two wells + badges, plus the
new snap-function and `OverlayColors` pair-refactor tasks.

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
