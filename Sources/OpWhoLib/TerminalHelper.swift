import AppKit
import ApplicationServices

public enum TerminalHelper {

    // MARK: - Tab Title Lookup

    /// A tab's human-readable name (when one exists) plus an optional
    /// keyboard-shortcut hint for jumping to that tab. iTerm is the only
    /// terminal that supplies the shortcut today — other terminals leave it
    /// nil and only populate `name`.
    public struct TabInfo: Equatable {
        public let name: String?
        public let shortcut: String?
        public init(name: String?, shortcut: String? = nil) {
            self.name = name
            self.shortcut = shortcut
        }
        public static let empty = TabInfo(name: nil, shortcut: nil)
    }

    /// Get the tab name and (where available) the keyboard shortcut to jump
    /// to a TTY in a specific terminal app.
    public static func tabInfo(forTTY tty: String, terminalBundleID: String?, terminalPID: pid_t?) -> TabInfo {
        guard isValidTTYPath(tty) else {
            NSLog("[op-who] Invalid TTY path: \(tty)")
            return .empty
        }
        guard let bid = terminalBundleID else { return .empty }

        switch bid {
        case "com.apple.Terminal":
            let name = appleScriptTabTitle(tty: tty, script: """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                return name of t
                            end if
                        end repeat
                    end repeat
                end tell
                """)
            return TabInfo(name: name)

        case "com.googlecode.iterm2":
            // Probe iTerm. We need: session.name + tab.title (for the human
            // identifier), tab index/count (for the ⌘N shortcut), and a
            // *stable* window index. iTerm's `windows` collection iterates
            // frontmost-first, so a naive 1-based loop position keeps
            // reporting "window 1" for whichever window the user triggered
            // from. Capturing each window's `id` instead lets us rank
            // numerically in Swift and produce a consistent "window N"
            // ordering across triggers.
            let raw = appleScriptTabTitle(tty: tty, script: """
                tell application "iTerm2"
                    set wCount to count of windows
                    set targetWinId to 0
                    set tIdx to 0
                    set tCount to 0
                    set sName to ""
                    set tTitle to ""
                    repeat with w in windows
                        set thisTC to count of tabs of w
                        set thisTI to 0
                        repeat with t in tabs of w
                            set thisTI to thisTI + 1
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    set targetWinId to (id of w) as integer
                                    set tIdx to thisTI
                                    set tCount to thisTC
                                    try
                                        set sName to name of s
                                    end try
                                    try
                                        set tTitle to title of t
                                    end try
                                end if
                            end repeat
                        end repeat
                    end repeat
                    set winIdsStr to ""
                    repeat with w in windows
                        if winIdsStr is "" then
                            set winIdsStr to ((id of w) as string)
                        else
                            set winIdsStr to winIdsStr & "," & ((id of w) as string)
                        end if
                    end repeat
                    return "session=" & sName & "|tab=" & tTitle & "|targetWinId=" & targetWinId & "|allWinIds=" & winIdsStr & "|winCount=" & wCount & "|tabIdx=" & tIdx & "|tabCount=" & tCount
                end tell
                """)
            let parsed = parseITermProbe(raw)
            let winIdx = computeITermWindowIndex(targetWinId: parsed["targetWinId"], allWinIds: parsed["allWinIds"])
            Log.app.info("iTerm tabInfo tty=\(tty, privacy: .public) session=\(parsed["session"] ?? "", privacy: .public) tab=\(parsed["tab"] ?? "", privacy: .public) targetWinId=\(parsed["targetWinId"] ?? "", privacy: .public) allWinIds=\(parsed["allWinIds"] ?? "", privacy: .public) winIdx=\(winIdx ?? -1, privacy: .public)/\(parsed["winCount"] ?? "", privacy: .public) tabIdx=\(parsed["tabIdx"] ?? "", privacy: .public)/\(parsed["tabCount"] ?? "", privacy: .public)")
            let result = chooseiTermTitle(
                session: parsed["session"],
                tab: parsed["tab"],
                winIdx: winIdx,
                winCount: Int(parsed["winCount"] ?? ""),
                tabIdx: Int(parsed["tabIdx"] ?? ""),
                tabCount: Int(parsed["tabCount"] ?? "")
            )
            return TabInfo(name: result.name, shortcut: result.shortcut)

        default:
            // For ghostty, Warp, cmux, etc. — use Accessibility API to find
            // the window whose title contains the TTY or just get all window titles
            if let pid = terminalPID {
                return TabInfo(name: axWindowTitle(forPID: pid, tty: tty))
            }
            return .empty
        }
    }

    /// Legacy single-string accessor kept for callers (RequestSummary) that
    /// only care about the tab's human name.
    public static func tabTitle(forTTY tty: String, terminalBundleID: String?, terminalPID: pid_t?) -> String? {
        tabInfo(forTTY: tty, terminalBundleID: terminalBundleID, terminalPID: terminalPID).name
    }

    // MARK: - Tab Activation

    /// Try to activate the terminal tab that owns a given TTY.
    public static func activateTab(forTTY tty: String, terminalBundleID: String? = nil) {
        guard isValidTTYPath(tty) else {
            NSLog("[op-who] Invalid TTY path: \(tty)")
            return
        }
        let bid = terminalBundleID ?? detectTerminalBundleID()
        guard let bid = bid else {
            NSLog("[op-who] No supported terminal found for TTY \(tty)")
            return
        }

        var ok = false

        switch bid {
        case "com.googlecode.iterm2":
            ok = runAppleScript("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select s
                                    set index of w to 1
                                    return "found"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)

        case "com.apple.Terminal":
            ok = runAppleScript("""
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                end tell
                """)

        default:
            break
        }

        // Fall back to activating the app if AppleScript failed or wasn't attempted
        if !ok {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.activate()
            }
        }
    }

    /// Write a message to a TTY device.
    public static func writeMessage(to tty: String, message: String) {
        guard isValidTTYPath(tty) else {
            NSLog("[op-who] Invalid TTY path: \(tty)")
            return
        }
        guard let fh = FileHandle(forWritingAtPath: tty) else {
            NSLog("[op-who] Cannot open \(tty) for writing")
            return
        }
        defer { fh.closeFile() }

        if let data = message.data(using: .utf8) {
            fh.write(data)
        }
    }

    // MARK: - Private

    /// Validate that a TTY path matches the expected macOS format `/dev/ttys[0-9]+`.
    public static func isValidTTYPath(_ tty: String) -> Bool {
        let pattern = #"^/dev/ttys\d+$"#
        return tty.range(of: pattern, options: .regularExpression) != nil
    }

    private static func detectTerminalBundleID() -> String? {
        let knownTerminals = [
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "dev.warp.Warp",
        ]
        for bid in knownTerminals {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                return bid
            }
        }
        return nil
    }

    /// Parse iTerm probe output of the form
    /// "key1=val1|key2=val2|...". Values that are exactly "missing value"
    /// (AppleScript's stringification of nil) become empty.
    static func parseITermProbe(_ raw: String?) -> [String: String] {
        guard let raw = raw else { return [:] }
        var result: [String: String] = [:]
        for part in raw.split(separator: "|", omittingEmptySubsequences: false) {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let k = String(part[..<eq])
            var v = String(part[part.index(after: eq)...])
            if v == "missing value" { v = "" }
            result[k] = v
        }
        return result
    }

    /// Heuristic for "this looks like an auto-generated session name, not a
    /// user-set tab title." iTerm's default Title Components produce values
    /// like "op", "zsh", "ssh user@host". Single short command words are
    /// almost certainly auto-named — skip them so a deliberate user rename
    /// (which is usually a phrase) gets preferred. Bare common shells and
    /// the running command don't help identify the tab.
    static func isGenericiTermSessionName(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let autoNames: Set<String> = [
            "zsh", "bash", "fish", "sh", "tmux", "screen",
            "op", "ssh", "git", "scp", "sftp", "rsync",
            "claude", "node", "python", "python3", "ruby",
        ]
        return autoNames.contains(trimmed.lowercased())
    }

    /// Result of evaluating an iTerm tab's probed identity. `name` is a
    /// human-readable label when one exists (user rename or non-generic
    /// session name); `shortcut` is a synthesized keyboard-shortcut hint
    /// (`⌘N`, `window K ⌘N`) that's always available when we got tab and
    /// window indices. Both can be present — the overlay shows the name as
    /// the primary identifier and the shortcut as a trailing hint.
    public struct ITermTitleResult: Equatable {
        public let name: String?
        public let shortcut: String?
        public init(name: String?, shortcut: String?) {
            self.name = name
            self.shortcut = shortcut
        }
    }

    /// Pick a usable title for an iTerm tab given the probed `name of session`
    /// and `title of tab`. iTerm composes `title of tab` from Title Components
    /// (default includes "Job"), so for an unrenamed tab the tab title equals
    /// the session name (e.g. both = "op" while op is running). Only treat
    /// the tab title as a user override when it actually differs from the
    /// auto-updating session name. Independently, when window+tab indices
    /// are available, build the keyboard-shortcut hint — useful for both
    /// unnamed tabs (as a fallback identifier) and named ones (so the user
    /// knows which key combination to press to jump there).
    static func chooseiTermTitle(
        session: String?,
        tab: String?,
        winIdx: Int? = nil,
        winCount: Int? = nil,
        tabIdx: Int? = nil,
        tabCount: Int? = nil
    ) -> ITermTitleResult {
        let s = session?.trimmingCharacters(in: .whitespaces) ?? ""
        let t = tab?.trimmingCharacters(in: .whitespaces) ?? ""
        var name: String? = nil
        if !t.isEmpty && t != s && !isGenericiTermSessionName(t) {
            name = t
        } else if !s.isEmpty && !isGenericiTermSessionName(s) {
            name = s
        }
        var shortcut: String? = nil
        if let wi = winIdx, let wc = winCount, let ti = tabIdx, let tc = tabCount,
           wc > 0, tc > 0 {
            shortcut = formatITermShortcut(winIdx: wi, winCount: wc, tabIdx: ti, tabCount: tc)
        }
        return ITermTitleResult(name: name, shortcut: shortcut)
    }

    /// Given the matching window's id and a comma-separated list of every
    /// iTerm window id, return a stable 1-based "window N" index ranked by
    /// numeric id (older windows first). iTerm's AppleScript `windows`
    /// collection iterates frontmost-first, so we can't use loop position
    /// directly — that would always report 1 for whichever window the user
    /// triggered from. Returns nil when either input is missing/unparseable.
    static func computeITermWindowIndex(targetWinId: String?, allWinIds: String?) -> Int? {
        guard let targetStr = targetWinId, let target = Int(targetStr), target != 0 else { return nil }
        guard let ids = allWinIds, !ids.isEmpty else { return nil }
        let parsed = ids.split(separator: ",").compactMap { Int($0) }
        guard !parsed.isEmpty else { return nil }
        let sorted = parsed.sorted()
        guard let pos = sorted.firstIndex(of: target) else { return nil }
        return pos + 1  // 1-based
    }

    /// Build a keyboard-shortcut-style identifier for an iTerm tab.
    /// - tab 1..8: `⌘1..⌘8`
    /// - last tab: `⌘9` (iTerm's special "switch to last tab" binding)
    /// - tab N ≥ 9 and not last: `tab N` (no single-key shortcut)
    /// - when more than one window exists, prefix `window K ` so the user
    ///   knows which window holds the tab. iTerm has no default cmd-N
    ///   shortcut for windows, so we just name the position.
    static func formatITermShortcut(winIdx: Int, winCount: Int, tabIdx: Int, tabCount: Int) -> String {
        let tabPart: String
        if tabIdx >= 1 && tabIdx <= 8 {
            tabPart = "⌘\(tabIdx)"
        } else if tabIdx == tabCount {
            tabPart = "⌘9"
        } else {
            tabPart = "tab \(tabIdx)"
        }
        if winCount > 1 {
            return "window \(winIdx) \(tabPart)"
        }
        return tabPart
    }

    private static func appleScriptTabTitle(tty: String, script: String) -> String? {
        guard let s = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = s.executeAndReturnError(&error)
        if let error = error {
            NSLog("[op-who] AppleScript error getting tab title: \(error)")
            return nil
        }
        let title = result.stringValue
        return (title?.isEmpty ?? true) ? nil : title
    }

    /// Use the Accessibility API to get window titles for a terminal process.
    /// Falls back to finding a window whose title mentions the TTY path, or
    /// just returns the first window title.
    private static func axWindowTitle(forPID pid: pid_t, tty: String) -> String? {
        let appEl = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        // Try to find a window whose title contains the tty device name
        let ttyShort = tty.replacingOccurrences(of: "/dev/", with: "")
        var firstTitle: String? = nil

        for win in windows {
            var titleValue: AnyObject?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String, !title.isEmpty {
                if firstTitle == nil { firstTitle = title }
                if title.contains(ttyShort) || title.contains(tty) {
                    return title
                }
            }
        }

        return firstTitle
    }

    /// Run an AppleScript and return whether it succeeded.
    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error {
            NSLog("[op-who] AppleScript error: \(error)")
            return false
        }
        return true
    }
}
