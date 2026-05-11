import Foundation

/// Classifies a 1Password approval trigger into a category understandable
/// without knowing the process model.
public enum RequestKind: String, Equatable {
    /// Trusted `op` binary signed by 1Password.
    case onePasswordCLI
    /// `op` binary that failed signature verification — surface as a warning.
    case unverifiedOp
    /// SSH-family request (ssh, scp, sftp, rsync, or git invoking ssh).
    case ssh
    /// Trigger we couldn't classify (chain empty or unfamiliar leader).
    case unknown
}

/// Human-readable summary of why a 1Password approval dialog appeared.
public struct RequestSummary: Equatable {
    public let kind: RequestKind
    /// One-sentence plain-English description: who is asking and for what.
    public let title: String
    /// Optional secondary line — terminal app and working directory.
    public let subtitle: String?
    /// True when something looks off and the user should pay attention.
    public let isWarning: Bool

    public init(kind: RequestKind, title: String, subtitle: String?, isWarning: Bool) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.isWarning = isWarning
    }
}

/// Build a RequestSummary from the structured fields collected at detection.
///
/// `chain` is the trigger-first parent chain (chain[0] is the trigger).
/// `triggerArgv` is the full argv of `chain[0]`, used to extract op subcommands,
/// git subcommands, and similar diagnostic detail. Pass `[]` if unavailable.
public func makeRequestSummary(
    chain: [ProcessNode],
    triggerArgv: [String] = [],
    tabTitle: String?,
    claudeSession: String?,
    terminalBundleID: String?,
    cwd: String?
) -> RequestSummary {
    let trigger = chain.first
    let kind = classifyKind(trigger: trigger)
    let actor = describeActor(
        chain: chain,
        tabTitle: tabTitle,
        claudeSession: claudeSession,
        terminalBundleID: terminalBundleID
    )
    let action = describeAction(kind: kind, trigger: trigger, argv: triggerArgv)
    let title = "\(actor) \(action)"

    var subtitleParts: [String] = []
    if let claudeSession = claudeSession,
       !actor.contains("’\(claudeSession)’") {
        // Subtitle echoes the session only if the title didn't already name it.
        subtitleParts.append("session: \(claudeSession)")
    }
    if let term = humanTerminalName(bundleID: terminalBundleID),
       !actor.contains(term) {
        subtitleParts.append(term)
    }
    if let cwd = cwd {
        subtitleParts.append(cwd)
    }
    let subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")

    return RequestSummary(
        kind: kind,
        title: title,
        subtitle: subtitle,
        isWarning: kind == .unverifiedOp || kind == .unknown
    )
}

/// Human-readable name for a known terminal bundle ID.
public func humanTerminalName(bundleID: String?) -> String? {
    guard let id = bundleID else { return nil }
    switch id {
    case "com.apple.Terminal": return "Terminal"
    case "com.googlecode.iterm2": return "iTerm"
    case "com.mitchellh.ghostty": return "Ghostty"
    case "dev.warp.Warp-Stable", "dev.warp.Warp": return "Warp"
    case "io.cmux", "com.cmux.cmux", "com.cmuxterm.app": return "cmux"
    default: return id
    }
}

public func isCmuxBundleID(_ id: String?) -> Bool {
    id == "io.cmux" || id == "com.cmux.cmux" || id == "com.cmuxterm.app"
}

/// Known shell process names — used to pick a driver when there's no Claude.
let shellProcessNames: Set<String> = ["bash", "zsh", "fish", "sh", "tcsh", "ksh", "dash"]

public enum DriverKind: Equatable {
    /// Claude Code is in the chain.
    case claude
    /// An editor or IDE (VS Code, Cursor, Emacs, vim, JetBrains, …) is in the chain.
    case editor
    /// Nothing more specific than a shell.
    case shell
    /// Some other parent process — best-effort fallback.
    case other
}

public struct DriverInfo: Equatable {
    public let text: String
    public let kind: DriverKind
    /// If non-nil, the macOS app bundle ID to fetch an icon for.
    /// Terminal-only editors (vim, neovim, helix, emacs CLI, …) carry no
    /// bundle ID — there's no GUI app to harvest an icon from.
    public let bundleID: String?
}

/// Map of process-name (as it appears in `ps`, max 15 chars truncated) →
/// (display name, optional bundle ID for icon lookup).
/// Process names from kinfo_proc truncate at MAXCOMLEN so patterns here
/// are kept short; the matcher uses prefix matching for helper variants.
let knownEditors: [(processName: String, display: String, bundleID: String?)] = [
    ("Code Helper", "VS Code", "com.microsoft.VSCode"),
    ("Code", "VS Code", "com.microsoft.VSCode"),
    ("Code - Insider", "VS Code Insiders", "com.microsoft.VSCodeInsiders"),
    ("Cursor Helper", "Cursor", "com.todesktop.230313mzl4w4u92"),
    ("Cursor", "Cursor", "com.todesktop.230313mzl4w4u92"),
    ("Zed Helper", "Zed", "dev.zed.Zed"),
    ("Zed", "Zed", "dev.zed.Zed"),
    ("emacs", "Emacs", nil),
    ("Emacs", "Emacs", "org.gnu.Emacs"),
    ("vim", "vim", nil),
    ("nvim", "Neovim", nil),
    ("mvim", "MacVim", "org.vim.MacVim"),
    ("hx", "Helix", nil),
    ("helix", "Helix", nil),
    ("nano", "nano", nil),
    ("micro", "micro", nil),
    ("idea", "IntelliJ IDEA", "com.jetbrains.intellij"),
    ("pycharm", "PyCharm", "com.jetbrains.pycharm"),
    ("webstorm", "WebStorm", "com.jetbrains.WebStorm"),
    ("rubymine", "RubyMine", "com.jetbrains.rubymine"),
    ("goland", "GoLand", "com.jetbrains.goland"),
    ("clion", "CLion", "com.jetbrains.CLion"),
    ("rider", "Rider", "com.jetbrains.rider"),
    ("phpstorm", "PhpStorm", "com.jetbrains.PhpStorm"),
    ("datagrip", "DataGrip", "com.jetbrains.datagrip"),
    ("sublime_text", "Sublime Text", "com.sublimetext.4"),
    ("xed", "Xed", nil),
]

/// Look up display name + bundle ID for a process name. Returns nil when
/// the process name is not in the editor list.
public func editorInfo(processName name: String) -> (display: String, bundleID: String?)? {
    for (pn, dn, bid) in knownEditors {
        if name == pn || name.hasPrefix("\(pn) ") { return (dn, bid) }
    }
    return nil
}

/// Choose the user-visible "driver" of the trigger.
///   1. Claude Code (when a claude session was detected)
///   2. A known editor / IDE process in the chain (VS Code, vim, Emacs, …)
///   3. The first shell in the chain (zsh, bash, fish, …)
///   4. Fallback: the immediate parent process name
public func driverDescription(
    chain: [ProcessNode],
    claudeSession: String?
) -> DriverInfo {
    if claudeSession != nil {
        return DriverInfo(text: "Claude Code", kind: .claude, bundleID: nil)
    }
    let afterTrigger = chain.dropFirst()
    for node in afterTrigger {
        if let info = editorInfo(processName: node.name) {
            return DriverInfo(text: info.display, kind: .editor, bundleID: info.bundleID)
        }
    }
    if let shell = afterTrigger.first(where: { shellProcessNames.contains($0.name) }) {
        return DriverInfo(text: shell.name, kind: .shell, bundleID: nil)
    }
    if let parent = afterTrigger.first {
        return DriverInfo(text: parent.name, kind: .other, bundleID: nil)
    }
    return DriverInfo(text: chain.first?.name ?? "unknown", kind: .other, bundleID: nil)
}

/// Format a trigger argv array as a one-line command for display.
/// Strips path prefix on argv[0] so we show `op item list`, not
/// `/usr/local/bin/op item list`.
public func operationDisplay(argv: [String], chain: [ProcessNode]) -> String {
    if argv.isEmpty {
        // No argv available (1Password helper, or a sandbox restriction).
        // Fall back to the trigger process name with no args.
        return chain.first?.name ?? "(unknown command)"
    }
    var parts = argv
    parts[0] = (parts[0] as NSString).lastPathComponent
    return parts.joined(separator: " ")
}

/// Parse `op` argv into a phrase like "read op://X/Y" or "use ‘op item get …’".
/// Returns nil when argv doesn't look like an op invocation.
public func describeOpInvocation(argv: [String]) -> String? {
    guard argv.count >= 2,
          (argv[0] as NSString).lastPathComponent == "op" else { return nil }

    // Skip leading flags to find the subcommand and its arguments.
    let rest = Array(argv.dropFirst()).drop(while: { $0.hasPrefix("-") })
    guard let sub = rest.first else { return nil }
    let subArgs = Array(rest.dropFirst()).filter { !$0.hasPrefix("-") }

    switch sub {
    case "read":
        if let uri = subArgs.first(where: { $0.hasPrefix("op://") }) {
            return "read \(uri)"
        }
        if let uri = subArgs.first {
            return "read \(uri)"
        }
        return "use ‘op read’"
    case "signin", "signout":
        return sub == "signin" ? "sign in to 1Password" : "sign out of 1Password"
    case "inject":
        return "inject secrets via ‘op inject’"
    case "run":
        return "run a command with ‘op run’"
    case "item", "vault", "document", "user", "group", "account", "ssh", "connect", "service-account", "events-api":
        if let action = subArgs.first {
            return "use ‘op \(sub) \(action)’"
        }
        return "use ‘op \(sub)’"
    default:
        return "run ‘op \(sub)’"
    }
}

/// Parse `git` argv to find the subcommand (e.g. "fetch", "push").
/// Skips `-C <path>`, `-c key=val`, and other global flags.
public func describeGitInvocation(argv: [String]) -> String? {
    guard !argv.isEmpty,
          (argv[0] as NSString).lastPathComponent == "git" else { return nil }

    var i = 1
    while i < argv.count {
        let a = argv[i]
        if a == "-C" || a == "-c" || a == "--git-dir" || a == "--work-tree" || a == "--namespace" {
            i += 2  // flag with value
            continue
        }
        if a.hasPrefix("-") {
            i += 1
            continue
        }
        return a
    }
    return nil
}

/// Git subcommands that may need network access — and therefore may trigger
/// an SSH key approval via 1Password's SSH agent.  Anything outside this set
/// is local-only and should be filtered out as a trigger candidate (so e.g.
/// a `git show` running in another tab never appears as a 1P dialog cause).
private let networkGitSubcommands: Set<String> = [
    "fetch", "pull", "push", "clone", "ls-remote", "archive",
    "remote", "submodule", "send-pack", "receive-pack", "upload-pack",
    "fetch-pack",
]

/// True iff the given git argv is for a subcommand that may need network /
/// SSH access. Unknown / local subcommands return false.
public func isRemoteGitSubcommand(argv: [String]) -> Bool {
    guard let sub = describeGitInvocation(argv: argv) else { return false }
    return networkGitSubcommands.contains(sub)
}

// MARK: - Private classification

private func classifyKind(trigger: ProcessNode?) -> RequestKind {
    guard let trigger = trigger else { return .unknown }
    switch trigger.name {
    case "op":
        return trigger.isVerifiedOnePasswordCLI ? .onePasswordCLI : .unverifiedOp
    case "ssh", "scp", "sftp", "rsync":
        return .ssh
    case "git":
        // The only reason `git` would trigger a 1Password approval is its SSH
        // transport — HTTPS auth goes through git-credential helpers, not 1P.
        return .ssh
    default:
        return .unknown
    }
}

private let shellNames: Set<String> = ["bash", "zsh", "fish", "sh", "tcsh", "ksh", "dash"]

private func describeActor(
    chain: [ProcessNode],
    tabTitle: String?,
    claudeSession: String?,
    terminalBundleID: String?
) -> String {
    let isCmux = isCmuxBundleID(terminalBundleID)
    let workspaceName: String? = (isCmux && tabTitle != nil && !looksGeneric(tabTitle: tabTitle!)) ? tabTitle : nil

    if claudeSession != nil {
        if let workspace = workspaceName {
            return "Claude Code in cmux workspace ‘\(workspace)’"
        }
        if let term = humanTerminalName(bundleID: terminalBundleID),
           !isCmux,
           let title = tabTitle,
           !looksGeneric(tabTitle: title) {
            return "Claude Code in \(term) tab ‘\(title)’"
        }
        return "Claude Code session ‘\(claudeSession!)’"
    }

    if let workspace = workspaceName {
        return "cmux workspace ‘\(workspace)’"
    }
    if let title = tabTitle, !looksGeneric(tabTitle: title) {
        if let term = humanTerminalName(bundleID: terminalBundleID), !isCmux {
            return "\(term) tab ‘\(title)’"
        }
        return "Terminal tab ‘\(title)’"
    }
    if let shell = chain.first(where: { shellNames.contains($0.name) }) {
        return "Your \(shell.name) shell"
    }
    if let term = humanTerminalName(bundleID: terminalBundleID) {
        return "Your \(term) session"
    }
    if let pid = chain.first?.pid {
        return "Process \(pid)"
    }
    return "An unknown process"
}

/// Filter out tab titles that are just default shell prompts and add no clarity.
/// (e.g. "bash", "zsh", "user@host", "user@host: /Users/x".)
private func looksGeneric(tabTitle: String) -> Bool {
    let trimmed = tabTitle.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return true }
    if shellNames.contains(trimmed) { return true }
    if trimmed.contains("@") && trimmed.range(of: " ") == nil { return true }
    if trimmed.contains("@") && trimmed.contains(": ") { return true }
    return false
}

private func describeAction(kind: RequestKind, trigger: ProcessNode?, argv: [String]) -> String {
    switch kind {
    case .onePasswordCLI:
        if let phrase = describeOpInvocation(argv: argv) {
            return "wants to \(phrase)"
        }
        return "is using the 1Password CLI"
    case .unverifiedOp:
        if let phrase = describeOpInvocation(argv: argv) {
            return "is running an unverified ‘op’ binary (\(phrase))"
        }
        return "is running an unverified ‘op’ binary"
    case .ssh:
        let cmd = trigger?.name ?? "ssh"
        if cmd == "git", let sub = describeGitInvocation(argv: argv) {
            return "needs an SSH key for ‘git \(sub)’"
        }
        if cmd == "ssh" {
            return "needs an SSH key"
        }
        return "needs an SSH key (via ‘\(cmd)’)"
    case .unknown:
        let cmd = trigger?.name ?? "?"
        return "triggered 1Password (via ‘\(cmd)’)"
    }
}
