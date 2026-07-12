import Foundation
import Testing
@testable import OpWhoLib

@Suite("AppSettings")
struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        // Unique suite name per test avoids cross-test bleed. Vary by UUID
        // (Date.now is unavailable/undesirable in tests).
        let name = "op-who-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("densePopup defaults to false")
    func denseDefault() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.densePopup == false)
    }

    @Test("densePopup persists")
    func densePersists() {
        let d = freshDefaults()
        AppSettings(defaults: d).densePopup = true
        #expect(AppSettings(defaults: d).densePopup == true)
    }

    @Test("appearance defaults to system")
    func appearanceDefault() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.appearance == .system)
    }

    @Test("appearance persists")
    func appearancePersists() {
        let d = freshDefaults()
        AppSettings(defaults: d).appearance = .dark
        #expect(AppSettings(defaults: d).appearance == .dark)
    }

    @Test("unknown stored appearance falls back to system")
    func appearanceFallback() {
        let d = freshDefaults()
        d.set("chartreuse", forKey: "appearance")
        #expect(AppSettings(defaults: d).appearance == .system)
    }

    @Test("popup font names default to nil and persist")
    func popupFontNames() {
        let d = freshDefaults()
        #expect(AppSettings(defaults: d).popupUIFontName == nil)
        #expect(AppSettings(defaults: d).popupMonoFontName == nil)
        AppSettings(defaults: d).popupUIFontName = "Helvetica Neue"
        AppSettings(defaults: d).popupMonoFontName = "Menlo"
        #expect(AppSettings(defaults: d).popupUIFontName == "Helvetica Neue")
        #expect(AppSettings(defaults: d).popupMonoFontName == "Menlo")
    }

    @Test("clearing a popup font name restores nil")
    func popupFontNameClear() {
        let d = freshDefaults()
        let s = AppSettings(defaults: d)
        s.popupUIFontName = "Menlo"
        s.popupUIFontName = nil
        #expect(AppSettings(defaults: d).popupUIFontName == nil)
    }

    @Test("base font size defaults to 12 and clamps to 9...24")
    func popupBaseSize() {
        let d = freshDefaults()
        #expect(AppSettings(defaults: d).popupFontBaseSize == 12)
        AppSettings(defaults: d).popupFontBaseSize = 100   // over max
        #expect(AppSettings(defaults: d).popupFontBaseSize == 24)
        AppSettings(defaults: d).popupFontBaseSize = 1     // under min
        #expect(AppSettings(defaults: d).popupFontBaseSize == 9)
        AppSettings(defaults: d).popupFontBaseSize = 15
        #expect(AppSettings(defaults: d).popupFontBaseSize == 15)
    }

    @Test("color overrides default empty and persist")
    func popupColorOverrides() {
        let d = freshDefaults()
        #expect(AppSettings(defaults: d).popupColorOverrides.isEmpty)
        AppSettings(defaults: d).popupColorOverrides = ["claude": "#AABBCC"]
        #expect(AppSettings(defaults: d).popupColorOverrides["claude"] == "#AABBCC")
    }
}
