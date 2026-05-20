import Foundation

/// Coalesces a burst of `schedule` calls so only the final one's closure
/// runs, after a quiet period of `interval` seconds. Each call cancels
/// any previously-scheduled closure that hasn't fired yet. Used to defer
/// expensive or visually-noisy work (predicate validation, diagnostic
/// updates) until the user pauses typing — the standard pattern that
/// language servers and IDE diagnostics use to avoid flashing errors on
/// every keystroke.
public final class Debouncer {

    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var workItem: DispatchWorkItem?

    /// `queue` is where the scheduled closure runs. Defaults to main so
    /// UI updates can be scheduled directly without an extra hop.
    public init(interval: TimeInterval, queue: DispatchQueue = .main) {
        self.interval = interval
        self.queue = queue
    }

    /// Cancel any pending closure and schedule a fresh one to run after
    /// `interval`. Safe to call rapidly — only the most recent schedule
    /// will fire.
    public func schedule(_ action: @escaping () -> Void) {
        let item = DispatchWorkItem(block: action)
        lock.lock()
        workItem?.cancel()
        workItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// Cancel any pending closure without scheduling a replacement.
    public func cancel() {
        lock.lock()
        workItem?.cancel()
        workItem = nil
        lock.unlock()
    }
}
