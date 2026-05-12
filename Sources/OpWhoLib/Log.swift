import Foundation
import os

public enum Log {
    public static let watcher = Logger(subsystem: "com.stigbakken.op-who", category: "watcher")
    public static let app = Logger(subsystem: "com.stigbakken.op-who", category: "app")
    public static let cmux = Logger(subsystem: "com.stigbakken.op-who", category: "cmux")
    public static let timing = Logger(subsystem: "com.stigbakken.op-who", category: "timing")
}

/// Run `block`, log how long it took to the timing category, and return its
/// result. Use for hot-path instrumentation when chasing latency regressions.
@inline(__always)
public func measure<T>(_ label: String, _ block: () -> T) -> T {
    let start = DispatchTime.now()
    let result = block()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
    Log.timing.info("\(label, privacy: .public) \(String(format: "%.1fms", ms), privacy: .public)")
    return result
}
