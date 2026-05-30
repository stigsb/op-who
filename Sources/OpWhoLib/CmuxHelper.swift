import Foundation

/// Information about a cmux surface (tab), looked up by TTY.
public struct CmuxSurfaceInfo: Equatable {
    public let workspaceRef: String              // e.g. "workspace:15"
    public let workspaceTitle: String            // raw cmux title (may be generic, e.g. "Item-0")
    public let workspaceDescription: String?     // optional longer description from cmux
    public let surfaceRef: String                // e.g. "surface:35"
    public let surfaceTitle: String              // raw cmux surface title
    public let surfaceType: String               // "terminal", "browser", etc.
    public let tty: String                       // bare ttysNN (no /dev/ prefix)
    /// Absolute working directory of the panel as recorded by cmux, used to
    /// disambiguate panels that share a recycled tty device. nil when cmux
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
        tty: String,
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
        self.tty = tty
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

    /// Look up workspace + surface info for a TTY by reading cmux's session
    /// state file. Returns nil if the file is unreadable or no terminal panel
    /// matches the TTY. Cached briefly so multiple lookups in one dialog
    /// reuse a single file read.
    ///
    /// cmux can leave MULTIPLE panels carrying the same tty device (numbers get
    /// recycled; stale entries linger). When that happens we disambiguate by
    /// the trigger's working directory: the right panel is the one the shell is
    /// actually inside. With no usable CWD — or no panel directory matching it —
    /// we return nil rather than guess, because showing the wrong workspace is
    /// worse than showing none.
    public static func surfaceInfo(forTTY tty: String, triggerCWD: String? = nil) -> CmuxSurfaceInfo? {
        let bare = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        let map = groupedMap()
        let candidates = map?[bare] ?? []

        if candidates.isEmpty {
            let keys = map?.keys.sorted().joined(separator: ",") ?? "<nil-map>"
            Log.cmux.info("surfaceInfo MISS tty=\(bare, privacy: .public) map_size=\(map?.count ?? -1, privacy: .public) keys=\(keys, privacy: .public)")
            return nil
        }

        if candidates.count == 1 {
            let hit = candidates[0]
            Log.cmux.info("surfaceInfo HIT  tty=\(bare, privacy: .public) ws=\(hit.workspaceTitle, privacy: .public) surface=\(hit.surfaceTitle, privacy: .public)")
            return hit
        }

        // Multiple panels share this tty — disambiguate by CWD.
        guard let cwd = triggerCWD else {
            Log.cmux.info("surfaceInfo MISS tty=\(bare, privacy: .public) candidates=\(candidates.count, privacy: .public) reason=no-cwd")
            return nil
        }

        // ProcessTree.processCWD returns symlink-resolved paths (e.g.
        // /private/var/...) while cmux's panel.directory is typically unresolved
        // (/var/...). Normalize both sides so the comparison is apples-to-apples.
        let normalizedCWD = normalizePath(cwd)

        // Among panels whose directory is the CWD or a path-prefix of it,
        // prefer the most specific (longest) directory.
        let matches = candidates
            .filter { panel in
                guard let dir = panel.directory, !dir.isEmpty else { return false }
                return pathContains(normalizePath(dir), normalizedCWD)
            }
            .sorted { ($0.directory?.count ?? 0) > ($1.directory?.count ?? 0) }

        guard let chosen = matches.first else {
            Log.cmux.info("surfaceInfo MISS tty=\(bare, privacy: .public) candidates=\(candidates.count, privacy: .public) cwd=\(cwd, privacy: .public) reason=no-dir-match")
            return nil
        }

        Log.cmux.info("surfaceInfo HIT  tty=\(bare, privacy: .public) candidates=\(candidates.count, privacy: .public) chosen_ws=\(chosen.workspaceTitle, privacy: .public) chosen_dir=\(chosen.directory ?? "<nil>", privacy: .public) cwd=\(cwd, privacy: .public)")
        return chosen
    }

    /// True when `child` is equal to `parent` or lives beneath it, compared by
    /// whole path components so `/a/b` contains `/a/b/c` but NOT `/a/bc`.
    static func pathContains(_ parent: String, _ child: String) -> Bool {
        if parent == child { return true }
        let p = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(p)
    }

    /// Resolves symlinks so the resolved and unresolved forms of the same
    /// directory compare equal (e.g. /var/x ↔ /private/var/x). Note:
    /// `resolvingSymlinksInPath` hits the filesystem and only resolves paths that
    /// exist — fine here, these are live working directories.
    static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Parse the raw bytes of cmux's session JSON file
    /// (`~/Library/Application Support/cmux/session-com.cmuxterm.app.json`).
    /// Returns a map from bare tty name → CmuxSurfaceInfo for every
    /// terminal-typed panel that carries a ttyName.
    ///
    /// We read this file directly instead of calling `cmux --json tree --all`
    /// because cmux's CLI talks to its GUI daemon over a Unix socket that
    /// keys auth on the connecting process's LaunchServices responsibility
    /// chain. op-who is a separate `.app`, so the daemon rejects the
    /// handshake with "Failed to write to socket (Broken pipe)" no matter
    /// how we wrap the spawn (shell, launchctl, osascript). The session
    /// file, by contrast, is a plain JSON written by cmux on every state
    /// change and readable by any same-user process.
    public static func parseSessionFile(_ data: Data) -> [String: CmuxSurfaceInfo] {
        // Flat (last-writer-wins) view, kept for back-compat with callers/tests
        // that don't care about tty collisions.
        parseSessionFileGrouped(data).reduce(into: [:]) { acc, kv in
            if let last = kv.value.last { acc[kv.key] = last }
        }
    }

    /// Like `parseSessionFile`, but groups all panels that share a bare tty so
    /// collisions can be disambiguated downstream. Insertion order within each
    /// bucket follows window → workspace → panel iteration order.
    public static func parseSessionFileGrouped(_ data: Data) -> [String: [CmuxSurfaceInfo]] {
        guard let session = try? JSONDecoder().decode(SessionJSON.self, from: data) else {
            return [:]
        }
        var map: [String: [CmuxSurfaceInfo]] = [:]
        for (wi, window) in session.windows.enumerated() {
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
                let wsRef = "workspace:\(wi):\(wsi)"
                let panelCount = ws.panels.count
                for (pi, panel) in ws.panels.enumerated() {
                    guard panel.type == "terminal",
                          let tty = nonEmpty(panel.ttyName) else { continue }
                    let bare = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
                    map[bare, default: []].append(CmuxSurfaceInfo(
                        workspaceRef: wsRef,
                        workspaceTitle: wsTitle,
                        workspaceDescription: wsDesc,
                        surfaceRef: "surface:\(panel.id)",
                        surfaceTitle: panel.title ?? "",
                        surfaceType: panel.type,
                        tty: bare,
                        directory: nonEmpty(panel.directory),
                        workspaceIndex: wsi + 1,
                        tabIndex: pi + 1,
                        workspaceTabCount: panelCount
                    ))
                }
            }
        }
        return map
    }

    /// Convenience for tests: parse a JSON string.
    public static func parseSessionFile(_ json: String) -> [String: CmuxSurfaceInfo] {
        parseSessionFile(Data(json.utf8))
    }

    /// Convenience for tests: parse a JSON string into the grouped form.
    public static func parseSessionFileGrouped(_ json: String) -> [String: [CmuxSurfaceInfo]] {
        parseSessionFileGrouped(Data(json.utf8))
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
            let ttyName: String?
            let type: String
            let directory: String?
        }
    }

    // MARK: - File caching

    private static var cacheValue: [String: [CmuxSurfaceInfo]]?
    private static var cacheTime: Date = .distantPast
    private static let cacheTTL: TimeInterval = 1.0
    private static let cacheLock = NSLock()
    /// Test override: when set, lookups use this map and skip the file read.
    private static var testMap: [String: [CmuxSurfaceInfo]]?

    private static func groupedMap() -> [String: [CmuxSurfaceInfo]]? {
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

        let fresh = readSessionFile().map(parseSessionFileGrouped)

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

    /// Install a fixed grouped map so `surfaceInfo` lookups are deterministic
    /// in tests (no dependency on the real cmux session file).
    public static func installTestMap(_ map: [String: [CmuxSurfaceInfo]]) {
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
