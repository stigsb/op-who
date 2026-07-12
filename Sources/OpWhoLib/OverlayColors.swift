import AppKit

/// Popup color palette, audited for WCAG AA contrast against `background` in
/// both light and dark appearances (see OverlayColorsContrastTests). Values
/// that fail as raw `system*` colors are replaced with appearance-aware pairs.
public enum OverlayColors {
    /// The popup's window background.
    public static let background = NSColor.windowBackgroundColor

    // Appearance-aware pairs: (light, dark). TUNE these until the contrast test
    // passes: darken the light value / lighten the dark value to raise ratio.
    public static let claude = dynamic(
        light: NSColor(srgbRed: 0.42, green: 0.20, blue: 0.60, alpha: 1),
        dark:  NSColor(srgbRed: 0.78, green: 0.60, blue: 0.98, alpha: 1))
    public static let editor = dynamic(
        light: NSColor(srgbRed: 0.0, green: 0.42, blue: 0.45, alpha: 1),
        dark:  NSColor(srgbRed: 0.40, green: 0.85, blue: 0.90, alpha: 1))
    public static let verifiedOp = dynamic(
        light: NSColor(srgbRed: 0.0, green: 0.45, blue: 0.20, alpha: 1),
        dark:  NSColor(srgbRed: 0.40, green: 0.85, blue: 0.55, alpha: 1))
    public static let unverifiedOp = dynamic(
        light: NSColor(srgbRed: 0.62, green: 0.33, blue: 0.0, alpha: 1),
        dark:  NSColor(srgbRed: 1.0, green: 0.70, blue: 0.30, alpha: 1))
    public static let ssh = dynamic(
        light: NSColor(srgbRed: 0.0, green: 0.35, blue: 0.80, alpha: 1),
        dark:  NSColor(srgbRed: 0.45, green: 0.72, blue: 1.0, alpha: 1))

    // Dedicated location-field colors. Each of git-root / branch / worktree
    // keeps its own hue in a fixed row so the value can be found by color as
    // well as position. Chosen from the palette's still-free hues (gold, rose,
    // slate) so they don't echo the action/who row colors above them.
    public static let gitRoot = dynamic(
        light: NSColor(srgbRed: 0.56, green: 0.42, blue: 0.0, alpha: 1),
        dark:  NSColor(srgbRed: 0.93, green: 0.77, blue: 0.33, alpha: 1))
    public static let branch = dynamic(
        light: NSColor(srgbRed: 0.74, green: 0.14, blue: 0.44, alpha: 1),
        dark:  NSColor(srgbRed: 1.0, green: 0.55, blue: 0.80, alpha: 1))
    public static let worktree = dynamic(
        light: NSColor(srgbRed: 0.24, green: 0.36, blue: 0.56, alpha: 1),
        dark:  NSColor(srgbRed: 0.62, green: 0.74, blue: 0.95, alpha: 1))

    public static let dimLabel = NSColor.secondaryLabelColor
    public static let brightValue = NSColor.labelColor

    /// Build an appearance-aware color from a light/dark pair.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    /// Resolve `color` to sRGB components in the current drawing appearance.
    public static func srgb(_ color: NSColor) -> (r: Double, g: Double, b: Double) {
        let c = (color.usingColorSpace(.sRGB) ?? color)
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    /// Snapshot a (possibly appearance-dynamic) color to the concrete sRGB
    /// color it renders as under `name`. Used to capture a default's light or
    /// dark component so one variant can be overridden while the other keeps
    /// its WCAG default.
    public static func resolved(_ color: NSColor, in name: NSAppearance.Name) -> NSColor {
        var comps = (r: 0.0, g: 0.0, b: 0.0)
        let appearance = NSAppearance(named: name) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            comps = srgb(color)
        }
        return NSColor(srgbRed: comps.r, green: comps.g, blue: comps.b, alpha: 1)
    }
}

/// WCAG relative-luminance contrast ratio of two sRGB colors (1…21).
public func contrastRatio(_ a: (r: Double, g: Double, b: Double),
                          _ b: (r: Double, g: Double, b: Double)) -> Double {
    func lum(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func chan(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b)
    }
    let l1 = lum(a), l2 = lum(b)
    let hi = max(l1, l2), lo = min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)
}
