import AppKit
import Testing
@testable import OpWhoLib

@Suite("OverlayColors contrast")
struct OverlayColorsContrastTests {
    private func ratio(_ fg: NSColor, on bg: NSColor, appearance: NSAppearance.Name) -> Double {
        var r = 0.0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            r = contrastRatio(OverlayColors.srgb(fg), OverlayColors.srgb(bg))
        }
        return r
    }

    private let bodyColors: [NSColor] = [
        OverlayColors.claude, OverlayColors.editor,
        OverlayColors.verifiedOp, OverlayColors.unverifiedOp,
        OverlayColors.ssh, OverlayColors.dimLabel,
        OverlayColors.gitRoot, OverlayColors.branch, OverlayColors.worktree,
    ]

    @Test("body colors pass AA 4.5:1 in light mode")
    func lightMode() {
        for c in bodyColors {
            #expect(ratio(c, on: OverlayColors.background, appearance: .aqua) >= 4.5)
        }
    }

    @Test("body colors pass AA 4.5:1 in dark mode")
    func darkMode() {
        for c in bodyColors {
            #expect(ratio(c, on: OverlayColors.background, appearance: .darkAqua) >= 4.5)
        }
    }
}
