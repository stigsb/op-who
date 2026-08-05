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
