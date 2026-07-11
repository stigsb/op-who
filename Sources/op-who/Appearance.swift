import AppKit
import OpWhoLib

/// Apply the appearance override to the whole app. `.system` clears the
/// override so macOS follows the system setting.
func applyAppearance(_ a: AppAppearance) {
    switch a {
    case .system: NSApp.appearance = nil
    case .light:  NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
