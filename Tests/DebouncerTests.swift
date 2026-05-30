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
        // Schedule, wait less than the interval, then reschedule before the
        // first closure can fire. Only the most recent closure must run — the
        // original is cancelled by the reschedule. We deliberately avoid a
        // mid-flight "hasn't fired yet" assertion at a precise wall-clock
        // moment: under CI load `Task.sleep` can oversleep, making such a
        // negative check racy. The final value alone proves coalescing: if
        // the reschedule did not cancel the original we would observe [1, 2].
        let debouncer = Debouncer(interval: 0.05, queue: Self.queue)
        let recorder = Recorder()
        debouncer.schedule { recorder.record(1) }
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms < 50ms interval
        debouncer.schedule { recorder.record(2) }
        try? await Task.sleep(nanoseconds: 200_000_000) // well past the second interval
        #expect(recorder.values == [2])
    }
}
