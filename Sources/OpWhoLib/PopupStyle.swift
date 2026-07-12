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

/// Light vs dark variant of a role's color. In System appearance the popup
/// renders whichever the OS currently is; a forced Light/Dark setting pins it.
/// Each variant is overridden independently.
public enum ColorVariant: String, CaseIterable {
    case light, dark

    public var appearanceName: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
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

    /// Storage key for a role's override in a given appearance variant, e.g.
    /// `"claude.light"`. The value is a `#RRGGBB` string in `popupColorOverrides`.
    public static func overrideKey(_ role: PopupColorRole, _ variant: ColorVariant) -> String {
        "\(role.rawValue).\(variant.rawValue)"
    }

    /// Appearance-aware color for a role, used when rendering the popup. If the
    /// user overrode either variant, returns a dynamic color that resolves the
    /// light/dark override at draw time and falls back to the WCAG default's
    /// matching component for any variant left un-overridden. With no overrides
    /// it hands back the role's default (already dynamic) untouched.
    public func color(_ role: PopupColorRole) -> NSColor {
        let light = overrideColor(role, .light)
        let dark = overrideColor(role, .dark)
        guard light != nil || dark != nil else { return role.defaultColor }
        let l = light ?? OverlayColors.resolved(role.defaultColor, in: ColorVariant.light.appearanceName)
        let d = dark ?? OverlayColors.resolved(role.defaultColor, in: ColorVariant.dark.appearanceName)
        return OverlayColors.dynamic(light: l, dark: d)
    }

    /// The concrete color a role resolves to for one variant — the override if
    /// set, else the WCAG default resolved in that appearance. For the settings
    /// UI, where each color well edits one variant at a time.
    public func color(_ role: PopupColorRole, variant: ColorVariant) -> NSColor {
        overrideColor(role, variant)
            ?? OverlayColors.resolved(role.defaultColor, in: variant.appearanceName)
    }

    private func overrideColor(_ role: PopupColorRole, _ variant: ColorVariant) -> NSColor? {
        guard let hex = overrides[Self.overrideKey(role, variant)] else { return nil }
        return NSColor(popupHex: hex)
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
        // Require exactly six hex digits: `allSatisfy(isHexDigit)` rejects a
        // leading "+"/"-" (which UInt32(_:radix:) would otherwise accept for
        // "+" and mis-handle for "-").
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16) else { return nil }
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
