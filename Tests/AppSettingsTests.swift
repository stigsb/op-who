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
}
