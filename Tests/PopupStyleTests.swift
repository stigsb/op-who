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
