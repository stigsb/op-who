# Popup Style Settings — Design

**Date:** 2026-07-12
**Status:** Approved for planning

## Goal

Let the user configure the approval popup's **fonts**, **font size**, and
**colors** from the Settings window. Everything defaults to today's values —
the existing WCAG-audited `OverlayColors` palette and the system fonts — so
existing installs are visually unchanged until the user opts in.

As part of the same change, the Settings window is restructured from a single
scrolling column into a tabbed multi-pane window, and the Rules section moves
into its own tab.

## Decisions (from brainstorming)

- **Fonts:** two configurable roles — a proportional **UI font** and a
  **monospace font** — matching the popup's existing mixed typography. The mono
  font is load-bearing (it keeps the process-tree and body grid columns
  aligned); the family picker should stay monospace but this is not enforced.
- **Font size:** a single **base size** (default 12). The three existing tiers
  become `base−1 / base / base+1`, so the default reproduces today's 11/12/13
  exactly. Clamped to 9–24.
- **Colors:** one color well **per semantic role** (~10 roles), each defaulting
  to the current effective `OverlayColors` value, with a **Restore defaults**
  button. A custom override is a single static color applied in **both** light
  and dark appearances — a deliberate consequence of "one well per role" (it
  replaces the adaptive light/dark default only when set).
- **Preview:** a **Preview…** button pops the real `OverlayPanel` with a sample
  entry so colors/fonts aren't chosen blind.
- **Window:** move to a tabbed layout (`NSTabView`, top tabs) with **General**,
  **Appearance**, and **Rules** tabs. All visual settings consolidate into the
  **Appearance** tab; General keeps only non-visual options.

## Non-goals

- No live re-render of an on-screen popup. Settings apply to the **next** popup;
  the Preview button covers immediate feedback.
- **WCAG contrast is not enforced on custom colors.** The user overrides
  deliberately. The existing contrast test continues to guard only the built-in
  defaults in `OverlayColors`.
- No full `NSFontPanel` — family popup + base-size stepper is enough.
- No per-well reset (only a global Restore defaults) in v1.

## Architecture

### 1. `AppSettings` — new keys

All optional/defaulted; absent ⇒ current behavior.

| Key                    | Type              | Default | Meaning |
|------------------------|-------------------|---------|---------|
| `popupUIFontName`      | `String?`         | `nil`   | nil ⇒ system proportional font |
| `popupMonoFontName`    | `String?`         | `nil`   | nil ⇒ `monospacedSystemFont` |
| `popupFontBaseSize`    | `Double`          | `12`    | clamped to 9–24 on read |
| `popupColorOverrides`  | `[String:String]` | `[:]`   | role key → hex sRGB (`#RRGGBB`); absent key ⇒ default |

Stored via UserDefaults like the existing `densePopup` / `appearance`.
`popupColorOverrides` persists as a dictionary (UserDefaults handles
`[String:String]`). Invalid/unparseable values are ignored (treated as absent)
so a hand-edited or corrupt default can't crash the popup.

### 2. `PopupStyle` resolver — new file in `OpWhoLib`

A pure value type built from an `AppSettings` snapshot. It is the single place
that turns settings into concrete `NSFont`/`NSColor`, so `OverlayPanel` never
reads UserDefaults and never hardcodes a size or default color.

```
enum PopupColorRole: String, CaseIterable {
    case claude, editor, verifiedOp, unverifiedOp, ssh
    case gitRoot, branch, worktree
    case dimLabel, brightValue
    // raw value is the stable storage key
}

enum FontRole { case ui, mono }
enum FontTier { case small, base, large }   // base−1 / base / base+1

struct PopupStyle {
    init(settings: AppSettings)

    func font(_ role: FontRole, weight: NSFont.Weight, tier: FontTier) -> NSFont
    func color(_ role: PopupColorRole) -> NSColor
}
```

- `font`: if the role has a custom family name, build it via
  `NSFontManager.shared.font(withFamily:traits:weight:size:)` so the requested
  weight is honored; if that returns nil (family gone), fall back to the system
  font. Otherwise `NSFont.systemFont` / `NSFont.monospacedSystemFont`. Size comes
  from the base and tier.
- `color`: parsed override if present and valid, else the `OverlayColors`
  default for that role.

`OverlayColors` remains the home of the **default** values and the WCAG contrast
test. `PopupColorRole` gets a `defaultColor` mapping back to the corresponding
`OverlayColors` static.

### 3. `OverlayPanel` — route through the resolver

- Add a `style: PopupStyle` property, set alongside `densePopup` before `show`
  (in `OnePasswordWatcher`, from `AppSettings()`).
- `makeLabel` gains font-role/tier parameters (or callers pass a resolved
  `NSFont`); the current `size:`/`mono:` call sites map to
  `style.font(role, weight, tier)`. The 11/12/13 literals become
  `.small/.base/.large` tiers.
- The color helpers (`bodyActionColor`, `bodyWhoColor`, `bodyFieldColor`, the
  process-tree op colors, dim/bright labels) call `style.color(role)` instead of
  `OverlayColors.xxx` directly.
- Chrome that is not popup content — the "▸ details" toggle and the
  Show Tab / Send Message buttons — stays at fixed system sizes (not scaled).

### 4. Settings window — tabbed layout

`ConfigWindowController` builds an `NSTabView` (top tabs) instead of the single
scroll column. All visual settings consolidate into the Appearance tab:

- **General** — `generalPane.view`, now holding only **Run on startup**.
- **Appearance** — new `AppearancePane.view`: dense popup, light/dark override,
  fonts, base size, colors, Restore defaults, Preview.
- **Rules** — `rulesPane.view`, moved verbatim out of the old shared scroll
  column. It keeps its own internal table scrolling.

`GeneralPane` sheds its dense-popup checkbox and appearance segmented control;
those move to `AppearancePane` (which owns the `settings.densePopup` and
`settings.appearance` wiring plus the `applyAppearance` call). `GeneralPane`
retains the `SMAppService` startup logic and `refreshState`.

The `Cmd-W` handling and the undo-enabled field editor on `ConfigWindow` are
preserved. `resetScrollToTop` applies to whichever tab owns a scroll view (the
Appearance tab wraps its content in a scroll view; Rules already scrolls).

### 5. `AppearancePane` — new file in `Sources/op-who`

A stacked section, wrapped in a scroll view (color grid can be tall). Groups,
top to bottom:

- **Popup behavior**: the **Dense popup** checkbox (moved from `GeneralPane`).
- **Appearance**: the System/Light/Dark segmented control (moved from
  `GeneralPane`), still calling `applyAppearance` on change.
- **Fonts**: **UI font** and **Mono font** `NSPopUpButton`s listing available
  font families, with "System default" as the first item (⇒ store nil); a
  **Base size** `NSStepper` + value label, range 9–24.
- **Colors**: a labeled grid of `NSColorWell`s, one per `PopupColorRole`, each
  initialized to the current effective color. Editing a well writes a hex
  override; the wells reflect current overrides on open.
- **Restore defaults**: clears `popupColorOverrides` (and resets the wells to
  default effective colors). Fonts/size are left as-is (their own "System
  default" popup item and stepper cover reset).
- **Preview…**: constructs a throwaway `OverlayPanel`, sets its `style` from the
  current values, and calls `show` with a representative sample `ProcessEntry`
  near the screen center. Each control writes its value to `AppSettings`
  immediately (same pattern as the existing dense/appearance toggles), so
  Preview reads straight from settings.

## Data flow

```
Settings UI (AppearancePane)  ──writes──▶  AppSettings (UserDefaults)
                                                 │
OnePasswordWatcher, before show ─reads─▶ PopupStyle(settings:) ─▶ OverlayPanel.style
                                                 │
Preview button ───────────────────────────▶ PopupStyle(settings:) ─▶ throwaway OverlayPanel.show(sample)
```

## Testing

- `PopupStyleTests` (Swift Testing, in `OpWhoLib` tests):
  - override present ⇒ returns override color; absent ⇒ returns `OverlayColors`
    default for that role.
  - invalid hex ⇒ treated as absent (default returned), no crash.
  - size tiers: default base 12 ⇒ 11/12/13; a custom base shifts all three;
    out-of-range base clamped to 9–24.
  - font fallback: unknown family name ⇒ system font of the right kind/size.
- `AppSettings` round-trip for the four new keys (inject a test suite).
- Existing `OverlayColorsContrastTests` unchanged — still guards the defaults.
- No new AppKit UI tests; `buildContentView` remains exercisable with an
  injected `style` if a smoke test is cheap.

## Rollout / compatibility

Purely additive. No migration: absent keys reproduce today's appearance exactly.
The tabbed window is a layout change only; no persisted state depends on the old
single-column structure.
