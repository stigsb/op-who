import Testing
import AppKit
@testable import OpWhoLib

@Suite("Elapsed format & color")
struct ElapsedFormatTests {

    @Test func formatsUnderOneMinuteAsSeconds() {
        #expect(formatElapsed(0) == "0s")
        #expect(formatElapsed(1) == "1s")
        #expect(formatElapsed(49) == "49s")
        #expect(formatElapsed(59.9) == "59s")  // floors to whole seconds
    }

    @Test func formatsMinutesAndSeconds() {
        #expect(formatElapsed(60) == "1m0s")
        #expect(formatElapsed(72) == "1m12s")
        #expect(formatElapsed(125) == "2m5s")
    }

    @Test func formatClampsNegative() {
        #expect(formatElapsed(-5) == "0s")
    }

    @Test func colorDefaultUntilTenSeconds() {
        #expect(elapsedColor(0) == .secondaryLabelColor)
        #expect(elapsedColor(9.9) == .secondaryLabelColor)
    }

    @Test func colorWarningBetweenTenAndThirty() {
        #expect(elapsedColor(10) == .systemOrange)
        #expect(elapsedColor(29.9) == .systemOrange)
    }

    @Test func colorErrorAtThirtyAndBeyond() {
        #expect(elapsedColor(30) == .systemRed)
        #expect(elapsedColor(120) == .systemRed)
    }
}
