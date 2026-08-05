import Foundation

/// Information about a cmux surface (tab), looked up by the stable panel
/// UUID (`panel.id` == `CMUX_SURFACE_ID`).
public struct CmuxSurfaceInfo: Equatable {
    /// Positional, snapshot-scoped ref (e.g. "workspace:15") — comes only
    /// from a live `cmux top` snapshot, so entries built from the session
    /// file (no socket call) leave this "".
    public let workspaceRef: String
    public let workspaceTitle: String            // raw cmux title (may be generic, e.g. "Item-0")
    public let workspaceDescription: String?     // optional longer description from cmux
    /// Positional, snapshot-scoped ref (e.g. "surface:35") — see `workspaceRef`.
    public let surfaceRef: String
    public let surfaceTitle: String               // raw cmux surface title
    public let surfaceType: String               // "terminal", "browser", etc.
    /// cmux surface UUID (`cmux_surface_id` in `cmux top`). Equals the
    /// session file's `panel.id` and is stable across the session — unlike
    /// `surfaceRef`, which is positional and snapshot-scoped. nil when no
    /// process record under the surface carried one.
    public let surfaceID: String?
    /// cmux workspace UUID (`cmux_workspace_id`).
    public let workspaceID: String?
    /// Absolute working directory of the panel as recorded by cmux.
    /// Informational only — session-file entries are keyed by the stable
    /// panel UUID, so this no longer disambiguates anything. nil when cmux
    /// didn't record one.
    public let directory: String?
    /// 1-based workspace position within its window; matches cmux's ⌘N
    /// keyboard shortcut. 0 when unknown.
    public let workspaceIndex: Int
    /// 1-based panel position within its workspace; matches cmux's ⌃N
    /// keyboard shortcut. 0 when unknown.
    public let tabIndex: Int
    /// Total number of panels in this surface's workspace. Used to suppress
    /// the ⌃N hint when there's only one tab (the shortcut is trivial then).
    /// 0 when unknown.
    public let workspaceTabCount: Int

    public init(
        workspaceRef: String,
        workspaceTitle: String,
        workspaceDescription: String? = nil,
        surfaceRef: String,
        surfaceTitle: String,
        surfaceType: String = "terminal",
        surfaceID: String? = nil,
        workspaceID: String? = nil,
        directory: String? = nil,
        workspaceIndex: Int = 0,
        tabIndex: Int = 0,
        workspaceTabCount: Int = 0
    ) {
        self.workspaceRef = workspaceRef
        self.workspaceTitle = workspaceTitle
        self.workspaceDescription = workspaceDescription
        self.surfaceRef = surfaceRef
        self.surfaceTitle = surfaceTitle
        self.surfaceType = surfaceType
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.directory = directory
        self.workspaceIndex = workspaceIndex
        self.tabIndex = tabIndex
        self.workspaceTabCount = workspaceTabCount
    }

    /// Workspace title best-suited for display. If cmux only has a generic
    /// placeholder (`Item-0`, `Workspace 1`, …) and no description, returns
    /// "" so callers can omit the field entirely.
    public var displayWorkspaceTitle: String {
        if !CmuxHelper.looksGenericTitle(workspaceTitle) { return workspaceTitle }
        if let d = workspaceDescription, !d.isEmpty { return d }
        return ""
    }
}

public enum CmuxHelper {

    /// Shared cap for anything walking a process ancestry chain (map-building
    /// recursion in `parseTopPidMap`, the leaf-first walk in `surface`).
    /// Mirrors cmux's own ancestry-walk limit (see `cmux-top.md`) — a guard
    /// against a cyclic or pathologically deep tree, not a real-world depth.
    private static let ancestryHopCap = 128

    /// Parse cmux's session file into a map keyed by the stable panel UUID
    /// (`panel.id` == `CMUX_SURFACE_ID` == socket `cmux_surface_id` ==
    /// AppleScript `terminal id`; verified equal). cmux #7750 removed the
    /// panels' ttyName — the tty INDEX died, not the data, so this re-key
    /// replaces the old tty-keyed parse. Terminal panels only. Pure.
    ///
    /// We read this file directly instead of calling `cmux --json tree --all`
    /// because cmux's CLI talks to its GUI daemon over a Unix socket whose
    /// default auth mode (`cmuxOnly`) rejects a separate `.app` like op-who
    /// (see `surfaceInfo(forPID:)` below). The session file, by contrast, is
    /// a plain JSON written by cmux on every state change and readable by
    /// any same-user process.
    public static func parseSessionFileByPanelID(_ data: Data) -> [String: CmuxSurfaceInfo] {
        guard let session = try? JSONDecoder().decode(SessionJSON.self, from: data) else {
            return [:]
        }
        var map: [String: CmuxSurfaceInfo] = [:]
        for window in session.windows {
            for (wsi, ws) in window.tabManager.workspaces.enumerated() {
                // Workspace title preference: customTitle (user-set) wins.
                // processTitle is auto-derived; we keep it as a description
                // fallback so a generic title can still surface something
                // useful (e.g. "Terminal 1" → description = "Terminal 1").
                let wsTitle = nonEmpty(ws.customTitle)
                    ?? nonEmpty(ws.processTitle)
                    ?? nonEmpty(ws.currentDirectory)
                    ?? ""
                let wsDesc: String? = {
                    if let custom = nonEmpty(ws.customTitle),
                       let proc = nonEmpty(ws.processTitle),
                       custom != proc {
                        return proc
                    }
                    return nil
                }()
                let panelCount = ws.panels.count
                for (pi, panel) in ws.panels.enumerated() {
                    guard panel.type == "terminal" else { continue }
                    map[panel.id] = CmuxSurfaceInfo(
                        workspaceRef: "",
                        workspaceTitle: wsTitle,
                        workspaceDescription: wsDesc,
                        surfaceRef: "",
                        surfaceTitle: panel.title ?? "",
                        surfaceType: panel.type,
                        surfaceID: panel.id,
                        directory: nonEmpty(panel.directory),
                        workspaceIndex: wsi + 1,
                        tabIndex: pi + 1,
                        workspaceTabCount: panelCount
                    )
                }
            }
        }
        return map
    }

    /// Convenience for tests: parse a JSON string.
    public static func parseSessionFileByPanelID(_ json: String) -> [String: CmuxSurfaceInfo] {
        parseSessionFileByPanelID(Data(json.utf8))
    }

    /// Walk the trigger-first chain reading each node's CMUX_SURFACE_ID until
    /// one is found. Env vars are inherited, so a node lacking it (caffeinate,
    /// tail, the cmux CLI) is covered by an ancestor. The chain is already
    /// bounded (buildChain stops at the terminal app / launchd) — no extra
    /// cap. Pure — the env reader is injected.
    public static func surfaceUUID(
        forChain chain: [ProcessNode],
        envOf: (pid_t) -> String?
    ) -> String? {
        for node in chain {
            if let v = envOf(node.pid), !v.isEmpty { return v }
        }
        return nil
    }

    /// Env-first identification, step 2: resolve a CMUX_SURFACE_ID against
    /// the session file re-keyed by panel.id. The lookup IS the sanity
    /// check: nil means no identification (closed pane, stale inherited
    /// UUID) — callers show no cmux info rather than raw IDs. Cached ~1 s
    /// so one dialog's lookups share a file read.
    public static func surfaceInfo(forSurfaceID uuid: String) -> CmuxSurfaceInfo? {
        let map = sessionMapByPanelID()
        guard let hit = map?[uuid] else {
            let size = map?.count ?? -1
            Log.cmux.info("surfaceInfo MISS uuid=\(uuid, privacy: .public) map_size=\(size, privacy: .public)")
            return nil
        }
        Log.cmux.info("surfaceInfo HIT  uuid=\(uuid, privacy: .public) ws=\(hit.workspaceTitle, privacy: .public) surface=\(hit.surfaceTitle, privacy: .public)")
        return hit
    }

    /// True when the title is empty or one of cmux's auto-generated
    /// placeholders (e.g. `Item-0`, `Item 1`, `Workspace-2`, `Workspace 3`,
    /// `Terminal 1`). Match is case-insensitive and anchored to the whole
    /// string.
    public static func looksGenericTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        return trimmed.range(
            of: #"^(Item|Workspace|Terminal)[\s-]\d+$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    // MARK: - `cmux top --all --processes --json` schema (subset)

    struct TopJSON: Decodable {
        let windows: [Window]

        struct Window: Decodable { let workspaces: [Workspace] }
        struct Workspace: Decodable {
            let ref: String
            // Optional: feeds workspaceIndex's "0 when unknown" sentinel
            // rather than emptying the map if cmux ever renames/omits it.
            // ref/pid/type stay strict — those feed focus-panel and a bad
            // guess there is worse than a missing ⌘N hint.
            let index: Int?
            let title: String?
            let description: String?
            let panes: [Pane]
        }
        struct Pane: Decodable { let surfaces: [Surface] }
        struct Surface: Decodable {
            let ref: String
            let index: Int?  // see Workspace.index
            let title: String?
            let type: String
            let processes: [ProcessRecord]?
        }
        struct ProcessRecord: Decodable {
            let pid: pid_t
            let cmuxSurfaceID: String?
            let cmuxWorkspaceID: String?
            let children: [ProcessRecord]?

            enum CodingKeys: String, CodingKey {
                case pid
                case cmuxSurfaceID = "cmux_surface_id"
                case cmuxWorkspaceID = "cmux_workspace_id"
                case children
            }
        }
    }

    /// Decodes the top-JSON payload, throwing on schema mismatch instead of
    /// swallowing the error — the caller logs it with the coding path.
    static func decodeTopJSON(_ data: Data) throws -> TopJSON {
        try JSONDecoder().decode(TopJSON.self, from: data)
    }

    /// Renders a decode failure as `<message> at <coding.path[0].like.this>`
    /// so a schema change names the exact offending field.
    static func describeDecodeError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        let context: DecodingError.Context
        let message: String
        switch decodingError {
        case .typeMismatch(let type, let ctx):
            context = ctx
            message = "type mismatch (expected \(type))"
        case .valueNotFound(let type, let ctx):
            context = ctx
            message = "value not found (expected \(type))"
        case .keyNotFound(let key, let ctx):
            context = ctx
            message = "key not found (\(key.stringValue))"
        case .dataCorrupted(let ctx):
            context = ctx
            message = "data corrupted"
        @unknown default:
            return decodingError.localizedDescription
        }
        var path = ""
        for key in context.codingPath {
            if let i = key.intValue {
                path += "[\(i)]"
            } else {
                path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return "\(message) at \(path.isEmpty ? "<root>" : path)"
    }

    /// Build the PID → surface map from `cmux top --all --processes --json`.
    /// Walks every terminal surface's `processes[]` tree recursively — the
    /// records are NESTED (each carries a `children[]` array); a flat scan of
    /// the top level misses most PIDs. A record whose `cmux_surface_id` is
    /// null (observed live) inherits its parent record's. First-encountered
    /// entry wins for a PID that appears under two surfaces; the leaf-first
    /// chain walk resolves the case that matters. The map-building walk is
    /// pure; a decode failure is logged via `Log.cmux.error` naming the
    /// offending coding path, so a schema change (like the `ttyName` removal
    /// this rework exists to survive) is diagnosable instead of silently
    /// degrading to an empty map.
    public static func parseTopPidMap(_ data: Data) -> [pid_t: CmuxSurfaceInfo] {
        let top: TopJSON
        do {
            top = try decodeTopJSON(data)
        } catch {
            Log.cmux.error("parseTopPidMap decode failed: \(describeDecodeError(error), privacy: .public)")
            return [:]
        }
        var map: [pid_t: CmuxSurfaceInfo] = [:]
        for window in top.windows {
            for ws in window.workspaces {
                let surfaces = ws.panes.flatMap(\.surfaces)
                // ⌃N indexes surfaces across the whole workspace (surface
                // `index` spans panes and types), so count them all.
                let tabCount = surfaces.count
                for surface in surfaces where surface.type == "terminal" {
                    func visit(
                        _ rec: TopJSON.ProcessRecord,
                        surfaceID: String?, workspaceID: String?, depth: Int
                    ) {
                        guard depth < ancestryHopCap else { return }
                        let sid = rec.cmuxSurfaceID ?? surfaceID
                        let wid = rec.cmuxWorkspaceID ?? workspaceID
                        if map[rec.pid] == nil {
                            map[rec.pid] = CmuxSurfaceInfo(
                                workspaceRef: ws.ref,
                                workspaceTitle: nonEmpty(ws.title) ?? "",
                                workspaceDescription: nonEmpty(ws.description),
                                surfaceRef: surface.ref,
                                surfaceTitle: nonEmpty(surface.title) ?? "",
                                surfaceType: surface.type,
                                surfaceID: sid,
                                workspaceID: wid,
                                workspaceIndex: ws.index.map { $0 + 1 } ?? 0,
                                tabIndex: surface.index.map { $0 + 1 } ?? 0,
                                workspaceTabCount: tabCount
                            )
                        }
                        for child in rec.children ?? [] {
                            visit(child, surfaceID: sid, workspaceID: wid, depth: depth + 1)
                        }
                    }
                    for rec in surface.processes ?? [] {
                        visit(rec, surfaceID: nil, workspaceID: nil, depth: 0)
                    }
                }
            }
        }
        return map
    }

    /// Resolve the surface owning a trigger by walking its parent chain
    /// leaf-first: the trigger PID itself, then its parent, and so on; the
    /// first PID present in `pidMap` wins (the trigger's own surface beats an
    /// ancestor's). Guards: a visited set (ppid data can contain cycles) and
    /// `ancestryHopCap`. Pure — the parent relation is injected.
    public static func surface(
        forTriggerPID triggerPID: pid_t,
        parentByPID: [pid_t: pid_t],
        pidMap: [pid_t: CmuxSurfaceInfo]
    ) -> CmuxSurfaceInfo? {
        var current: pid_t? = triggerPID
        var visited = Set<pid_t>()
        while let pid = current, pid > 0,
              visited.count < ancestryHopCap, visited.insert(pid).inserted {
            if let hit = pidMap[pid] { return hit }
            current = parentByPID[pid]
        }
        return nil
    }

    // MARK: - Socket access: spawn, failure classification, denial latch

    public enum CmuxTopFailure: Equatable {
        /// `automation.socketControlMode` is not "automation" — a user
        /// setting, permanent until changed. Latched: never re-shell on a
        /// timer; a fresh dialog re-arms at most one probe.
        case accessDenied
        /// cmux not running / not installed / other error. Degrade quietly.
        case transient
    }

    /// Substring match, not equality: cmux uses both "-" and "—" in the
    /// denial message across versions.
    public static func classifyFailure(stderr: String) -> CmuxTopFailure {
        stderr.contains("Access denied") ? .accessDenied : .transient
    }

    private static var deniedLatch = false

    /// True while the last probe was refused by the socket's auth gate.
    /// Drives the popup's opt-in guidance.
    public static var automationDenied: Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return deniedLatch
    }

    /// Re-arm one probe. Called by the watcher when a dialog ends, so the
    /// next 1Password dialog performs at most one fresh probe and the
    /// guidance clears without an op-who restart once the user fixes the
    /// setting.
    public static func retryAfterDenial() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        deniedLatch = false
    }

    /// Never call while holding `cacheLock` — `NSLock` is not reentrant, this
    /// takes it itself, and a lock-holding caller would self-deadlock.
    static func noteFailure(_ failure: CmuxTopFailure) {
        guard failure == .accessDenied else { return }
        cacheLock.lock(); defer { cacheLock.unlock() }
        deniedLatch = true
    }

    /// Look up workspace + surface info for a trigger PID via cmux's control
    /// socket (`cmux top --all --processes --json`). Under the hybrid design
    /// this is NOT the primary identification path — `surfaceInfo(forSurfaceID:)`
    /// (env var → session file) is, and works with no socket at all. This is
    /// the click-time ref supplier for exact-panel `focus-panel` (and an
    /// optional identification fallback when the env walk finds no UUID).
    ///
    /// The socket authorizes each connection by peer PID (`LOCAL_PEERPID`),
    /// walking the caller's parent chain and requiring it to reach the
    /// running cmux.app process. op-who's ancestry is launchd → op-who, so
    /// under the default `cmuxOnly` mode every call fails with "Access
    /// denied …" — the user must set `automation.socketControlMode` to
    /// "automation". Denials latch (see `automationDenied`); other failures
    /// degrade quietly. The parsed map is cached ~1 s so one dialog's
    /// lookups share a spawn.
    public static func surfaceInfo(forPID triggerPID: pid_t) -> CmuxSurfaceInfo? {
        // Capture the ProcessTree snapshot BEFORE topPidMap() (which may
        // spawn, ~80ms): ProcessTree's cache TTL is only 250ms and a cold
        // scan costs ~200ms, so spending 80ms first materially raises the
        // odds it expired here — forcing the extra sysctl pass this design
        // exists to avoid.
        let parents = Dictionary(
            ProcessTree.allProcesses().map { ($0.pid, $0.ppid) },
            uniquingKeysWith: { a, _ in a }
        )
        guard let map = topPidMap(), !map.isEmpty else { return nil }
        return surface(forTriggerPID: triggerPID, parentByPID: parents, pidMap: map)
    }

    private static func topPidMap() -> [pid_t: CmuxSurfaceInfo]? {
        cacheLock.lock()
        if let testMap = testPidMap {
            defer { cacheLock.unlock() }
            return testMap
        }
        // Read the raw static `deniedLatch` here, NOT `automationDenied`
        // (which also takes `cacheLock`) — this lock is held right now and
        // NSLock is not reentrant; calling in would self-deadlock on the
        // main thread, in the dialog path, on the first denial.
        if deniedLatch {
            cacheLock.unlock()
            return nil  // latched: no re-shelling until retryAfterDenial()
        }
        if let cached = topPidMapCacheValue, Date().timeIntervalSince(topPidMapCacheTime) < topPidMapCacheTTL {
            defer { cacheLock.unlock() }
            return cached
        }
        cacheLock.unlock()

        // The spawn must stay outside the lock: `runCmuxTop()` can call
        // `noteFailure`, which takes `cacheLock` itself.
        let fresh = runCmuxTop().map(parseTopPidMap)

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let fresh = fresh {
            topPidMapCacheValue = fresh
            topPidMapCacheTime = Date()
        }
        return fresh
    }

    private static func findCmuxExecutable() -> String? {
        let candidates = [
            "/Applications/cmux.app/Contents/Resources/bin/cmux",  // real binary
            "/opt/homebrew/bin/cmux",                              // symlink to the above
            "/usr/local/bin/cmux",                                 // Intel Homebrew
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// cmux falls back to a user-scoped socket path when it can't bind the
    /// default `~/.local/state/cmux/cmux.sock`, and records the live path in
    /// this file (see `cmux-top.md`). Without reading it, every probe on such
    /// an install fails as `.transient` forever — indistinguishable from cmux
    /// not running at all. `cmux --help` documents no `--socket-path` CLI
    /// flag, only the `CMUX_SOCKET_PATH` env var; that's what we set.
    private static func lastSocketPathOverride() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/last-socket-path").path
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ~1s ceiling on `cmux top`. This runs on the MAIN thread (op-who's AX
    /// observer source is attached to `CFRunLoopGetMain()`), and unlike
    /// `runGit`'s bounded local-repo call, `cmux top` is an IPC round-trip to
    /// a third-party GUI app — if cmux.app is wedged, an unbounded wait here
    /// freezes the whole menu bar app and stalls the dialog-dismissal poll.
    private static let cmuxTopTimeout: TimeInterval = 1.0

    /// Spawn `cmux top --all --processes --json`. Returns stdout on exit 0;
    /// on failure classifies stderr (latching a denial) and returns nil.
    /// `--all` is required: `caller` is null for a GUI process with no cmux
    /// env vars, so the implicit current-window default cannot resolve.
    private static func runCmuxTop() -> Data? {
        guard let exe = findCmuxExecutable() else {
            Log.cmux.info("cmux top: binary not found (checked bundle + Homebrew paths)")
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["top", "--all", "--processes", "--json"]
        if let socketPath = lastSocketPathOverride() {
            var env = ProcessInfo.processInfo.environment
            env["CMUX_SOCKET_PATH"] = socketPath
            proc.environment = env
        }
        let stdout = Pipe(), stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do { try proc.run() } catch {
            Log.cmux.error("cmux top spawn failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Watchdog: terminate the process if it overruns cmuxTopTimeout, so a
        // wedged cmux.app can't block the main run loop forever. Cancelled on
        // normal completion below so it can never fire after this function
        // returns.
        let timedOutBox = TimedOutBox()
        let watchdog = DispatchWorkItem {
            timedOutBox.set()
            proc.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + cmuxTopTimeout, execute: watchdog)

        // Drain both pipes to EOF BEFORE waitUntilExit(): real output measured
        // 235 KB against a 64 KB pipe buffer, so waiting first hangs forever
        // on the full pipe.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        if timedOutBox.value {
            // Transient by construction: no noteFailure() call, so a wedged
            // cmux — which is not a permission problem — can never latch.
            Log.cmux.error("cmux top timed out after \(cmuxTopTimeout, privacy: .public)s, terminated")
            return nil
        }

        guard proc.terminationStatus == 0 else {
            let msg = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let failure = classifyFailure(stderr: msg)
            noteFailure(failure)
            Log.cmux.error("cmux top exit=\(proc.terminationStatus, privacy: .public) failure=\(String(describing: failure), privacy: .public) stderr=\(msg, privacy: .public)")
            return nil
        }
        Log.cmux.info("cmux top: \(outData.count, privacy: .public) bytes")
        return outData
    }

    /// Lock-guarded flag shared between `runCmuxTop()` and its watchdog
    /// `DispatchWorkItem`, which fires on a different thread.
    private final class TimedOutBox: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    // MARK: - Test hooks (PID map)

    private static var testPidMap: [pid_t: CmuxSurfaceInfo]?

    /// Install a fixed PID map so `surfaceInfo(forPID:)` is deterministic in
    /// tests (no spawn, no dependency on a live cmux).
    public static func installTestPidMap(_ map: [pid_t: CmuxSurfaceInfo]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        testPidMap = map
    }

    public static func clearTestPidMap() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        testPidMap = nil
    }

    // Dedicated statics, separate from the session-file cache's
    // `cacheValue`/`cacheTime`/`cacheTTL` below — the two caches key
    // different lookups (PID vs. UUID) and refresh independently.
    // `cacheLock` is shared safely because no path that holds it ever calls
    // back into a function that takes it again — that non-reentrancy, not
    // brevity, is what makes one `NSLock` enough.
    private static var topPidMapCacheValue: [pid_t: CmuxSurfaceInfo]?
    private static var topPidMapCacheTime: Date = .distantPast
    private static let topPidMapCacheTTL: TimeInterval = 1.0

    // MARK: - JSON schema (subset of cmux's session state file)

    struct SessionJSON: Decodable {
        let windows: [Window]

        struct Window: Decodable {
            let tabManager: TabManager
        }

        struct TabManager: Decodable {
            let workspaces: [Workspace]
        }

        struct Workspace: Decodable {
            let customTitle: String?
            let processTitle: String?
            let currentDirectory: String?
            let panels: [Panel]
        }

        struct Panel: Decodable {
            let id: String
            let title: String?
            let type: String
            let directory: String?
        }
    }

    // MARK: - File caching

    private static var cacheValue: [String: CmuxSurfaceInfo]?
    private static var cacheTime: Date = .distantPast
    private static let cacheTTL: TimeInterval = 1.0
    private static let cacheLock = NSLock()
    /// Test override: when set, lookups use this map and skip the file read.
    private static var testMap: [String: CmuxSurfaceInfo]?

    private static func sessionMapByPanelID() -> [String: CmuxSurfaceInfo]? {
        cacheLock.lock()
        if let testMap = testMap {
            defer { cacheLock.unlock() }
            return testMap
        }
        if let cached = cacheValue, Date().timeIntervalSince(cacheTime) < cacheTTL {
            defer { cacheLock.unlock() }
            return cached
        }
        cacheLock.unlock()

        let fresh = readSessionFile().map(parseSessionFileByPanelID)

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let fresh = fresh {
            cacheValue = fresh
            cacheTime = Date()
            return fresh
        }
        return cacheValue
    }

    // MARK: - Test hooks

    /// Install a fixed UUID-keyed map so `surfaceInfo(forSurfaceID:)` lookups
    /// are deterministic in tests (no dependency on the real cmux session file).
    public static func installTestMap(_ map: [String: CmuxSurfaceInfo]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        testMap = map
    }

    /// Remove any test override installed by `installTestMap`.
    public static func clearTestMap() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        testMap = nil
    }

    private static func readSessionFile() -> Data? {
        let path = sessionFilePath()
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            Log.cmux.info("readSessionFile: \(data.count, privacy: .public) bytes")
            return data
        } catch {
            Log.cmux.error("readSessionFile failed: \(error.localizedDescription, privacy: .public) path=\(path, privacy: .public)")
            return nil
        }
    }

    private static func sessionFilePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/cmux/session-com.cmuxterm.app.json"
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
