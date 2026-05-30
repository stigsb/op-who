import Testing

@testable import OpWhoLib

/// Tests for the pure dismissal-decision logic in `OnePasswordWatcher`.
///
/// Regression context: commit 75439d9 replaced the process-liveness dismissal
/// signal with a pure AX-window-gone debounce. Because `isApprovalDialog`
/// accepts any non-excluded 1Password standard window (including the main
/// window), op-who could latch onto a window that never goes AX-gone, so the
/// debounce never fired and the overlay hung indefinitely. The fix restores
/// process-liveness as an additional OR dismissal signal.
struct DialogDismissalTests {

    private static let threshold = 3

    @Test("Regression: window never goes AX-gone but all tracked PIDs dead → dismiss")
    func dismissesWhenAllTrackedPIDsDeadDespiteWindowPresent() {
        // windowGone stays false forever (latched onto a still-open window),
        // so the tick counter never increments — yet the trigger process has
        // exited. This is the production hang scenario; it must dismiss.
        let result = OnePasswordWatcher.shouldDismiss(
            windowGone: false,
            tickCount: 0,
            threshold: Self.threshold,
            trackedPIDsNonEmpty: true,
            allTrackedPIDsDead: true
        )
        #expect(result.dismiss == true)
        #expect(result.newTickCount == 0)
    }

    @Test("windowGone reaching threshold dismisses")
    func dismissesWhenWindowGoneReachesThreshold() {
        // One more tick on a count of (threshold - 1) reaches the threshold.
        let result = OnePasswordWatcher.shouldDismiss(
            windowGone: true,
            tickCount: Self.threshold - 1,
            threshold: Self.threshold,
            trackedPIDsNonEmpty: true,
            allTrackedPIDsDead: false
        )
        #expect(result.newTickCount == Self.threshold)
        #expect(result.dismiss == true)
    }

    @Test("windowGone below threshold with live PIDs keeps overlay")
    func keepsWhenWindowGoneBelowThresholdAndPIDsAlive() {
        let result = OnePasswordWatcher.shouldDismiss(
            windowGone: true,
            tickCount: 0,
            threshold: Self.threshold,
            trackedPIDsNonEmpty: true,
            allTrackedPIDsDead: false
        )
        #expect(result.newTickCount == 1)
        #expect(result.dismiss == false)
    }

    @Test("a present tick resets the window-gone counter")
    func presentTickResetsCounter() {
        let result = OnePasswordWatcher.shouldDismiss(
            windowGone: false,
            tickCount: 2,
            threshold: Self.threshold,
            trackedPIDsNonEmpty: true,
            allTrackedPIDsDead: false
        )
        #expect(result.newTickCount == 0)
        #expect(result.dismiss == false)
    }

    @Test("empty tracked set does not trigger procsGone dismissal")
    func emptyTrackedSetDoesNotDismiss() {
        // allTrackedPIDsDead is vacuously true for an empty set; the procsGone
        // signal must be gated on the set being non-empty.
        let result = OnePasswordWatcher.shouldDismiss(
            windowGone: false,
            tickCount: 0,
            threshold: Self.threshold,
            trackedPIDsNonEmpty: false,
            allTrackedPIDsDead: true
        )
        #expect(result.dismiss == false)
        #expect(result.newTickCount == 0)
    }

    @Test("both signals firing → dismiss")
    func dismissesWhenBothSignalsFire() {
        // windowGone reaching threshold AND all tracked PIDs dead: both OR
        // operands are true. Dismissal holds and the tick counter still advances
        // to the threshold.
        let result = OnePasswordWatcher.shouldDismiss(
            windowGone: true,
            tickCount: Self.threshold - 1,
            threshold: Self.threshold,
            trackedPIDsNonEmpty: true,
            allTrackedPIDsDead: true
        )
        #expect(result.dismiss == true)
        #expect(result.newTickCount == Self.threshold)
    }

    @Test("live PIDs and window present keeps overlay")
    func keepsWhenPIDsAliveAndWindowPresent() {
        let result = OnePasswordWatcher.shouldDismiss(
            windowGone: false,
            tickCount: 0,
            threshold: Self.threshold,
            trackedPIDsNonEmpty: true,
            allTrackedPIDsDead: false
        )
        #expect(result.dismiss == false)
        #expect(result.newTickCount == 0)
    }
}
