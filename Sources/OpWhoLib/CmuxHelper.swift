import Foundation

/// Information about a cmux surface (tab), looked up by TTY.
public struct CmuxSurfaceInfo: Equatable {
    public let workspaceRef: String     // e.g. "workspace:15"
    public let workspaceTitle: String   // e.g. "sunstone-cms" or a path
    public let surfaceRef: String       // e.g. "surface:35"
    public let surfaceTitle: String     // tab title (user-renameable)
    public let tty: String              // e.g. "ttys033" (no /dev/ prefix)
}

public enum CmuxHelper {

    /// Look up workspace + surface info for a TTY by running `cmux tree --all`
    /// and parsing the textual hierarchy. Returns nil if cmux is unavailable
    /// or no surface matches the TTY. Cached for a few seconds.
    public static func surfaceInfo(forTTY tty: String) -> CmuxSurfaceInfo? {
        let bare = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        return cachedMap()?[bare]
    }

    /// Pure parser: take the textual output of `cmux tree --all` and return
    /// a map from bare tty name → CmuxSurfaceInfo.
    public static func parseTree(_ output: String) -> [String: CmuxSurfaceInfo] {
        var currentWorkspaceRef = ""
        var currentWorkspaceTitle = ""
        var map: [String: CmuxSurfaceInfo] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if let ws = matchWorkspaceLine(s) {
                currentWorkspaceRef = ws.ref
                currentWorkspaceTitle = ws.title
                continue
            }
            if let sf = matchSurfaceLine(s) {
                map[sf.tty] = CmuxSurfaceInfo(
                    workspaceRef: currentWorkspaceRef,
                    workspaceTitle: currentWorkspaceTitle,
                    surfaceRef: sf.ref,
                    surfaceTitle: sf.title,
                    tty: sf.tty
                )
            }
        }
        return map
    }

    // MARK: - Private

    private static var cacheValue: [String: CmuxSurfaceInfo]?
    private static var cacheTime: Date = .distantPast
    private static let cacheTTL: TimeInterval = 3.0
    private static let cacheLock = NSLock()
    private static let subprocessQueue = DispatchQueue(
        label: "com.stigbakken.op-who.cmuxhelper", qos: .userInitiated
    )
    /// Timeout for the cmux subprocess. The wait happens via a semaphore on
    /// the calling thread (does NOT spin the runloop), so a short bound here
    /// is the safety net for a hung `cmux` binary, not the common case.
    private static let subprocessTimeout: TimeInterval = 1.0

    private static func cachedMap() -> [String: CmuxSurfaceInfo]? {
        cacheLock.lock()
        if let cached = cacheValue, Date().timeIntervalSince(cacheTime) < cacheTTL {
            defer { cacheLock.unlock() }
            return cached
        }
        cacheLock.unlock()

        // Run the subprocess on a background queue and block here via
        // DispatchSemaphore. NSTask.waitUntilExit() on the main thread spins
        // the runloop, which can re-dispatch AX callbacks while we hold the
        // cache lock — those callbacks re-enter cachedMap() and deadlock on
        // the lock. Semaphore.wait() blocks the thread without spinning the
        // runloop, so no re-entrant AX callbacks fire and no deadlock.
        var freshResult: [String: CmuxSurfaceInfo]?
        let sem = DispatchSemaphore(value: 0)
        subprocessQueue.async {
            if let output = runCmuxTree() {
                freshResult = parseTree(output)
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + subprocessTimeout)

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let fresh = freshResult {
            cacheValue = fresh
            cacheTime = Date()
            return fresh
        }
        return cacheValue
    }

    private static func runCmuxTree() -> String? {
        guard let bin = cmuxBinary() else { return nil }
        let task = Process()
        task.launchPath = bin
        task.arguments = ["tree", "--all"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func cmuxBinary() -> String? {
        // Note: /Applications/cmux.app/Contents/MacOS/cmux is the GUI launcher,
        // not the CLI. The CLI lives at .../Contents/Resources/bin/cmux. The
        // user's $PATH usually has a symlink to that, so we check both.
        let candidates = [
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "/opt/homebrew/bin/cmux",
            "/usr/local/bin/cmux",
        ]
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    // MARK: - Parsing primitives (exposed internally for tests)

    /// `… workspace workspace:NN "title" [selected]?` → (ref, title)
    static func matchWorkspaceLine(_ s: String) -> (ref: String, title: String)? {
        // Find " workspace workspace:" anchor to avoid matching the noun in
        // "list-workspaces" etc.
        guard let wsRange = s.range(of: "workspace workspace:") else { return nil }
        let after = s[wsRange.upperBound...]
        // Read digits.
        let digits = after.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let ref = "workspace:\(digits)"
        // Then find a quoted title.
        guard let title = firstQuoted(in: String(after.dropFirst(digits.count))) else {
            return (ref, "")
        }
        return (ref, title)
    }

    /// `surface surface:NN [terminal] "title" […]? tty=ttysNN` → (ref, title, tty)
    static func matchSurfaceLine(_ s: String) -> (ref: String, title: String, tty: String)? {
        guard let sfRange = s.range(of: "surface surface:") else { return nil }
        let after = s[sfRange.upperBound...]
        let digits = after.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let ref = "surface:\(digits)"
        let rest = String(after.dropFirst(digits.count))
        let title = firstQuoted(in: rest) ?? ""
        // The tty marker comes near the end of the line.
        guard let ttyRange = s.range(of: "tty=") else { return nil }
        let ttyTail = s[ttyRange.upperBound...]
        let tty = String(ttyTail.prefix(while: { $0.isLetter || $0.isNumber }))
        guard !tty.isEmpty else { return nil }
        return (ref, title, tty)
    }

    /// Return the contents of the first `"..."` substring, or nil.
    /// Handles escaped quotes minimally (cmux titles don't embed quotes
    /// in practice; we keep this simple).
    private static func firstQuoted(in s: String) -> String? {
        guard let open = s.firstIndex(of: "\"") else { return nil }
        let afterOpen = s.index(after: open)
        guard let close = s[afterOpen...].firstIndex(of: "\"") else { return nil }
        return String(s[afterOpen..<close])
    }
}
