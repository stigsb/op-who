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
}
