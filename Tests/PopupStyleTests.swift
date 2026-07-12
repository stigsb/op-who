import AppKit
import Testing
@testable import OpWhoLib

@Suite("PopupStyle colors")
struct PopupStyleColorTests {
    private func srgb(_ c: NSColor) -> (r: Double, g: Double, b: Double) {
        OverlayColors.srgb(c)
    }

    @Test("no override returns the role default")
    func defaultColor() {
        let style = PopupStyle.default
        for role in PopupColorRole.allCases {
            #expect(srgb(style.color(role)) == srgb(role.defaultColor))
        }
    }

    @Test("a valid hex override wins over the default")
    func overrideColor() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overrides: ["claude": "#112233"]
        )
        let c = style.color(.claude)
        #expect(srgb(c) == srgb(NSColor(srgbRed: 0x11/255.0, green: 0x22/255.0, blue: 0x33/255.0, alpha: 1)))
    }

    @Test("an invalid hex override falls back to the default")
    func invalidOverride() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overrides: ["ssh": "not-a-color"]
        )
        #expect(srgb(style.color(.ssh)) == srgb(PopupColorRole.ssh.defaultColor))
    }

    @Test("hex round-trips through NSColor helpers")
    func hexRoundTrip() {
        let c = NSColor(popupHex: "#4A2B99")
        #expect(c != nil)
        #expect(c?.popupHexString == "#4A2B99")
        #expect(NSColor(popupHex: "zzz") == nil)
        #expect(NSColor(popupHex: "#12345") == nil)   // wrong length
    }
}

@Suite("PopupStyle fonts")
struct PopupStyleFontTests {
    @Test("default base 12 yields 11/12/13 tiers")
    func defaultTiers() {
        let s = PopupStyle.default
        #expect(s.font(.ui, weight: .regular, tier: .small).pointSize == 11)
        #expect(s.font(.ui, weight: .regular, tier: .base).pointSize == 12)
        #expect(s.font(.ui, weight: .regular, tier: .large).pointSize == 13)
    }

    @Test("custom base size shifts every tier")
    func customBase() {
        let s = PopupStyle(uiFontName: nil, monoFontName: nil, baseSize: 16, overrides: [:])
        #expect(s.font(.mono, weight: .regular, tier: .small).pointSize == 15)
        #expect(s.font(.mono, weight: .regular, tier: .base).pointSize == 16)
        #expect(s.font(.mono, weight: .regular, tier: .large).pointSize == 17)
    }

    @Test("system default mono role is monospaced")
    func systemMonoIsFixedPitch() {
        let f = PopupStyle.default.font(.mono, weight: .regular, tier: .base)
        #expect(f.isFixedPitch)
    }

    @Test("unknown family name falls back to a system font of the right size")
    func unknownFamilyFallsBack() {
        let s = PopupStyle(uiFontName: "No Such Font XYZ", monoFontName: nil, baseSize: 12, overrides: [:])
        let f = s.font(.ui, weight: .semibold, tier: .large)
        #expect(f.pointSize == 13)   // still sized correctly
    }

    @Test("a real custom family is honored")
    func customFamilyHonored() {
        let s = PopupStyle(uiFontName: "Menlo", monoFontName: nil, baseSize: 12, overrides: [:])
        let f = s.font(.ui, weight: .regular, tier: .base)
        #expect(f.familyName == "Menlo")
        #expect(f.pointSize == 12)
    }
}
