import os

public enum Log {
    public static let watcher = Logger(subsystem: "com.stigbakken.op-who", category: "watcher")
    public static let app = Logger(subsystem: "com.stigbakken.op-who", category: "app")
}
