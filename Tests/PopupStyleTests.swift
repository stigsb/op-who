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

    @Test("an override wins for its variant, the other variant keeps the default")
    func overridePerVariant() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overrides: [PopupStyle.overrideKey(.claude, .light): "#112233"]
        )
        // The overridden (light) variant returns the override.
        #expect(srgb(style.color(.claude, variant: .light))
                == srgb(NSColor(srgbRed: 0x11 / 255.0, green: 0x22 / 255.0, blue: 0x33 / 255.0, alpha: 1)))
        // The un-overridden (dark) variant keeps the WCAG default (in dark).
        #expect(srgb(style.color(.claude, variant: .dark))
                == srgb(OverlayColors.resolved(PopupColorRole.claude.defaultColor, in: .darkAqua)))
    }

    @Test("dynamic color resolves the correct override per appearance")
    func dynamicColorPerAppearance() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overrides: [
                PopupStyle.overrideKey(.branch, .light): "#101010",
                PopupStyle.overrideKey(.branch, .dark): "#F0F0F0",
            ]
        )
        let dyn = style.color(.branch)
        var lightHex = "", darkHex = ""
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            lightHex = (dyn.usingColorSpace(.sRGB) ?? dyn).popupHexString
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            darkHex = (dyn.usingColorSpace(.sRGB) ?? dyn).popupHexString
        }
        #expect(lightHex == "#101010")
        #expect(darkHex == "#F0F0F0")
    }

    @Test("an invalid hex override falls back to the default")
    func invalidOverride() {
        let style = PopupStyle(
            uiFontName: nil, monoFontName: nil, baseSize: 12,
            overrides: [PopupStyle.overrideKey(.ssh, .light): "not-a-color"]
        )
        #expect(srgb(style.color(.ssh)) == srgb(PopupColorRole.ssh.defaultColor))
    }

    @Test("hex round-trips and rejects malformed input")
    func hexRoundTrip() {
        let c = NSColor(popupHex: "#4A2B99")
        #expect(c != nil)
        #expect(c?.popupHexString == "#4A2B99")
        #expect(NSColor(popupHex: "zzz") == nil)
        #expect(NSColor(popupHex: "#12345") == nil)   // wrong length
        #expect(NSColor(popupHex: "+12345") == nil)   // signed
        #expect(NSColor(popupHex: "-12345") == nil)   // signed
        #expect(NSColor(popupHex: "12345g") == nil)   // non-hex char
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
