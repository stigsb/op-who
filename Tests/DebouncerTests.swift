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
        // A reschedule must cancel the pending closure even when a gap
        // separates the two calls. The target queue is suspended during the
        // gap so the first closure cannot run however long the gap takes,
        // which removes the wall-clock race that failed on loaded CI runners.
        let queue = DispatchQueue(label: "DebouncerTests.reschedule")
        queue.suspend()
        let debouncer = Debouncer(interval: 0.05, queue: queue)
        let recorder = Recorder()
        debouncer.schedule { recorder.record(1) }
        try? await Task.sleep(nanoseconds: 100_000_000) // past the first deadline
        debouncer.schedule { recorder.record(2) }
        queue.resume()
        for _ in 0..<50 where recorder.values.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(recorder.values == [2])
    }
}
