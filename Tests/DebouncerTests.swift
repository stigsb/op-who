import Testing
import Foundation
@testable import OpWhoLib

@Suite("Debouncer")
struct DebouncerTests {

    /// Thread-safe recorder for tracking which scheduled closures fired.
    /// The debouncer's work item runs on whatever queue we pass in, which
    /// is a background queue here, so the recorder needs a lock.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Int] = []
        func record(_ v: Int) {
            lock.lock(); _values.append(v); lock.unlock()
        }
        var values: [Int] {
            lock.lock(); defer { lock.unlock() }
            return _values
        }
    }

    private static let queue = DispatchQueue(label: "DebouncerTests.queue")

    @Test func runsOnlyMostRecentlyScheduledAction() async {
        let debouncer = Debouncer(interval: 0.05, queue: Self.queue)
        let recorder = Recorder()
        debouncer.schedule { recorder.record(1) }
        debouncer.schedule { recorder.record(2) }
        debouncer.schedule { recorder.record(3) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.values == [3])
    }

    @Test func singleScheduleRunsAfterInterval() async {
        let debouncer = Debouncer(interval: 0.03, queue: Self.queue)
        let recorder = Recorder()
        debouncer.schedule { recorder.record(42) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(recorder.values == [42])
    }

    @Test func cancelPreventsExecution() async {
        let debouncer = Debouncer(interval: 0.03, queue: Self.queue)
        let recorder = Recorder()
        debouncer.schedule { recorder.record(1) }
        debouncer.cancel()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(recorder.values == [])
    }

    @Test func rescheduleResetsTimer() async {
        // Schedule, wait a fraction of the interval, then reschedule before
        // the first closure can fire. Only the most recent closure must run —
        // the original is cancelled by the reschedule, even though a gap
        // separated the two schedule calls.
        //
        // This is inherently a wall-clock race, and shared CI runners exhibit
        // severe `Task.sleep` jitter (a sleep can overrun its nominal duration
        // by 2-3x under load). Two things keep it robust: (1) a large interval
        // relative to the inter-schedule gap (300ms vs 30ms, a 10x margin) so
        // the first closure cannot fire before the reschedule even under heavy
        // oversleep; (2) no mid-flight "hasn't fired yet" assertion — we check
        // only the final value. [2] alone proves coalescing: if the reschedule
        // had not cancelled the original we would observe [1, 2].
        let debouncer = Debouncer(interval: 0.3, queue: Self.queue)
        let recorder = Recorder()
        debouncer.schedule { recorder.record(1) }
        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms << 300ms interval
        debouncer.schedule { recorder.record(2) }
        try? await Task.sleep(nanoseconds: 500_000_000) // well past the second interval
        #expect(recorder.values == [2])
    }
}
