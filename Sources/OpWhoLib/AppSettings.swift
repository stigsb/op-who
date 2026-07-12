import Foundation

/// Popup appearance override.
public enum AppAppearance: String, CaseIterable {
    case system, light, dark
}

/// UserDefaults-backed app settings. Inject a suite in tests.
public final class AppSettings {
    private let defaults: UserDefaults
    private enum Key {
        static let densePopup = "densePopup"
        static let appearance = "appearance"
        static let popupUIFontName = "popupUIFontName"
        static let popupMonoFontName = "popupMonoFontName"
        static let popupFontBaseSize = "popupFontBaseSize"
        static let popupColorOverrides = "popupColorOverrides"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Collapse droppable popup rows (e.g. the worktree row in the main
    /// checkout). Default false (positional stability).
    public var densePopup: Bool {
        get { defaults.bool(forKey: Key.densePopup) }
        set { defaults.set(newValue, forKey: Key.densePopup) }
    }

    public var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

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
}
