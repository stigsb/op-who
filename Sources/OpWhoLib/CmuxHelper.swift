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

    public init(
        workspaceRef: String,
        workspaceTitle: String,
        workspaceDescription: String? = nil,
        surfaceRef: String,
        surfaceTitle: String,
        surfaceType: String = "terminal",
        tty: String
    ) {
        self.workspaceRef = workspaceRef
        self.workspaceTitle = workspaceTitle
        self.workspaceDescription = workspaceDescription
        self.surfaceRef = surfaceRef
        self.surfaceTitle = surfaceTitle
        self.surfaceType = surfaceType
        self.tty = tty
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
    public static func surfaceInfo(forTTY tty: String) -> CmuxSurfaceInfo? {
        let bare = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        let map = cachedMap()
        let hit = map?[bare]
        if hit == nil {
            let keys = map?.keys.sorted().joined(separator: ",") ?? "<nil-map>"
            Log.cmux.info("surfaceInfo MISS tty=\(bare, privacy: .public) map_size=\(map?.count ?? -1, privacy: .public) keys=\(keys, privacy: .public)")
        } else {
            Log.cmux.info("surfaceInfo HIT  tty=\(bare, privacy: .public) ws=\(hit!.workspaceTitle, privacy: .public) surface=\(hit!.surfaceTitle, privacy: .public)")
        }
        return hit
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
        guard let session = try? JSONDecoder().decode(SessionJSON.self, from: data) else {
            return [:]
        }
        var map: [String: CmuxSurfaceInfo] = [:]
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
                for panel in ws.panels {
                    guard panel.type == "terminal",
                          let tty = nonEmpty(panel.ttyName) else { continue }
                    let bare = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
                    map[bare] = CmuxSurfaceInfo(
                        workspaceRef: wsRef,
                        workspaceTitle: wsTitle,
                        workspaceDescription: wsDesc,
                        surfaceRef: "surface:\(panel.id)",
                        surfaceTitle: panel.title ?? "",
                        surfaceType: panel.type,
                        tty: bare
                    )
                }
            }
        }
        return map
    }

    /// Convenience for tests: parse a JSON string.
    public static func parseSessionFile(_ json: String) -> [String: CmuxSurfaceInfo] {
        parseSessionFile(Data(json.utf8))
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
        }
    }

    // MARK: - File caching

    private static var cacheValue: [String: CmuxSurfaceInfo]?
    private static var cacheTime: Date = .distantPast
    private static let cacheTTL: TimeInterval = 1.0
    private static let cacheLock = NSLock()

    private static func cachedMap() -> [String: CmuxSurfaceInfo]? {
        cacheLock.lock()
        if let cached = cacheValue, Date().timeIntervalSince(cacheTime) < cacheTTL {
            defer { cacheLock.unlock() }
            return cached
        }
        cacheLock.unlock()

        let fresh = readSessionFile().map(parseSessionFile)

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let fresh = fresh {
            cacheValue = fresh
            cacheTime = Date()
            return fresh
        }
        return cacheValue
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
