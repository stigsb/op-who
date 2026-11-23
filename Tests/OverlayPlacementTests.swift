import AppKit
import Testing
@testable import OpWhoLib

@Suite("OverlayPanel browser placement")
struct OverlayPlacementTests {
    private let size = NSSize(width: 400, height: 200)
    // Primary display 1600x1000 with a 25 pt menu bar.
    private let primary = OverlayPanel.ScreenGeometry(
        frame: NSRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 975))
    // Second display to the right of the primary.
    private let secondary = OverlayPanel.ScreenGeometry(
        frame: NSRect(x: 1600, y: 0, width: 1200, height: 1000),
        visibleFrame: NSRect(x: 1600, y: 0, width: 1200, height: 975))

    private func origin(_ window: CGRect, screens: [OverlayPanel.ScreenGeometry]? = nil) -> NSPoint {
        OverlayPanel.browserOverlayOrigin(
            windowFrame: window, panelSize: size, primaryHeight: 1000,
            screens: screens ?? [primary])
    }

    @Test func tallWindowCentersHorizontallySixteenAboveBottom() {
        // AppKit window: x 100…1100, y 150…950.
        #expect(origin(CGRect(x: 100, y: 50, width: 1000, height: 800)) == NSPoint(x: 400, y: 166))
    }

    @Test func windowExactlyTallEnoughKeepsOverlayInside() {
        // height 336 = 16 + 200 + 120. AppKit window y 564…900.
        #expect(origin(CGRect(x: 100, y: 100, width: 1000, height: 336)) == NSPoint(x: 400, y: 580))
    }

    @Test func shortWindowPutsOverlayDirectlyBelow() {
        // AppKit window y 600…900: 16 + 200 would reach into the top 120 pt.
        #expect(origin(CGRect(x: 100, y: 100, width: 1000, height: 300)) == NSPoint(x: 400, y: 400))
    }

    @Test func belowWindowIsClampedToVisibleFrame() {
        // AppKit window y 0…300, below would be y -200.
        #expect(origin(CGRect(x: 100, y: 700, width: 1000, height: 300)) == NSPoint(x: 400, y: 0))
    }

    @Test func horizontalClampLeft() {
        #expect(origin(CGRect(x: -100, y: 50, width: 300, height: 800)) == NSPoint(x: 0, y: 166))
    }

    @Test func usesTheScreenContainingTheWindow() {
        let screens = [primary, secondary]
        #expect(origin(CGRect(x: 1700, y: 50, width: 1000, height: 800), screens: screens)
                == NSPoint(x: 2000, y: 166))
        // Window hangs off the right edge of the secondary display.
        #expect(origin(CGRect(x: 2500, y: 50, width: 600, height: 800), screens: screens)
                == NSPoint(x: 2400, y: 166))
    }

    @Test func noScreensMeansNoClamp() {
        #expect(origin(CGRect(x: 100, y: 700, width: 1000, height: 300), screens: [])
                == NSPoint(x: 400, y: -200))
    }

    @Test func centered() {
        #expect(OverlayPanel.centeredOrigin(panelSize: size, in: primary.visibleFrame)
                == NSPoint(x: 600, y: 387.5))
    }
}
