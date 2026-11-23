import AppKit
import Testing
@testable import OpWhoLib

@Suite("oidcLogin kind and color role")
struct OidcKindColorTests {
    @Test func kindRawValueIsStable() {
        #expect(RequestKind.oidcLogin.rawValue == "oidcLogin")
    }

    @Test func roleDefaultsToOverlayColor() {
        let a = OverlayColors.srgb(PopupColorRole.oidcLogin.defaultColor)
        let b = OverlayColors.srgb(OverlayColors.oidcLogin)
        #expect(a == b)
    }

    @Test func roleIsOverridablePerAppearance() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overrides: [PopupStyle.overrideKey(.oidcLogin, .light): "#112233"]
        )
        #expect(style.color(.oidcLogin, variant: .light).popupHexString == "#112233")
        let dark = OverlayColors.srgb(style.color(.oidcLogin, variant: .dark))
        let defaultDark = OverlayColors.srgb(
            OverlayColors.resolved(OverlayColors.oidcLogin, in: .darkAqua))
        #expect(dark == defaultDark)
    }
}
