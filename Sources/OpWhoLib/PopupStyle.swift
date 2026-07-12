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
