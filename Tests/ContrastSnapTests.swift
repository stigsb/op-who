import Testing
@testable import OpWhoLib

@Suite("snapToContrast")
struct ContrastSnapTests {
    // The popup's real backgrounds: white (light) and #1E1E1E (dark).
    let lightBG = (r: 1.0, g: 1.0, b: 1.0)
    let darkBG = (r: 30.0 / 255, g: 30.0 / 255, b: 30.0 / 255)

    @Test("full hue sweep snaps to passing against both backgrounds")
    func hueSweep() {
        for deg in stride(from: 0, to: 360, by: 15) {
            let c = hsbToRGB(h: Double(deg), s: 1, v: 1)
            for bg in [lightBG, darkBG] {
                let snapped = snapToContrast(c, against: bg)
                #expect(contrastRatio(snapped, bg) >= 4.5,
                        "hue \(deg) failed: got \(contrastRatio(snapped, bg))")
            }
        }
    }

    @Test("already-passing input is returned unchanged")
    func idempotent() {
        let navy = (r: 0.0, g: 0.0, b: 0.5)
        let snapped = snapToContrast(navy, against: lightBG)
        #expect(snapped == navy)
    }

    @Test("hue and saturation are preserved when reachable")
    func huePreserved() {
        let lightRed = (r: 1.0, g: 0.6, b: 0.6)   // fails on white
        let snapped = snapToContrast(lightRed, against: lightBG)
        #expect(contrastRatio(snapped, lightBG) >= 4.5)
        let (h, s, _) = rgbToHSB(snapped)
        #expect(min(h, 360 - h) < 2)   // still red
        #expect(abs(s - 0.4) < 0.02)   // saturation untouched
    }

    @Test("saturated blue desaturates against the dark background")
    func blueDesaturates() {
        // Pure blue maxes out at Y ≈ 0.072, below the ≈0.23 floor the dark
        // background demands — unreachable at full saturation.
        let blue = (r: 0.0, g: 0.0, b: 1.0)
        let snapped = snapToContrast(blue, against: darkBG)
        #expect(contrastRatio(snapped, darkBG) >= 4.5)
        let (_, s, _) = rgbToHSB(snapped)
        #expect(s < 1.0)
    }

    @Test("grayscale extremes snap fine")
    func extremes() {
        let white = (r: 1.0, g: 1.0, b: 1.0)
        let black = (r: 0.0, g: 0.0, b: 0.0)
        #expect(contrastRatio(snapToContrast(white, against: lightBG), lightBG) >= 4.5)
        #expect(contrastRatio(snapToContrast(black, against: darkBG), darkBG) >= 4.5)
    }
}
