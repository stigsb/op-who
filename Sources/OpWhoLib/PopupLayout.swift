import Foundation

/// A single rendered row of the popup body. `label` nil = the label-less
/// action row. Styling is decided by `style`; the renderer maps it to colors.
public struct BodyRow: Equatable {
    public let label: String?
    public let value: String
    public let style: BodyRowStyle
}

public enum BodyRowStyle: Equatable {
    /// Top action line, colored by request kind.
    case action(RequestKind)
    /// "who" line, colored by driver kind.
    case who(DriverKind)
    /// A labeled context field — dim label, value colored by `FieldColor`.
    case field(FieldColor)
    /// The wrapping Claude "asked" prompt line.
    case asked
}

/// Value tint for a `.field` row. git-root/branch/worktree each get a dedicated
/// hue so they're findable by color as well as position; `plain` (cwd) keeps
/// the neutral bright value.
public enum FieldColor: Equatable { case gitRoot, branch, worktree, plain }

/// Build the ordered body rows for an entry. Pure — no AppKit, no I/O.
///
/// Canonical order (identical for every trigger): action, who, location block
/// (git-root/branch/worktree in a repo, else a single cwd), asked.
func bodyRows(entry: OverlayPanel.ProcessEntry, dense: Bool) -> [BodyRow] {
    var rows: [BodyRow] = []

    // Action — cwd:nil so commit-signing renders "signing a commit" (location
    // lives in its own row).
    let actionText: String
    if let update = entry.pluginUpdate {
        actionText = "plugin update check from \(update.remoteURL)"
    } else {
        actionText = operationDisplay(argv: entry.triggerArgv, chain: entry.chain, cwd: nil)
    }
    rows.append(BodyRow(label: nil, value: actionText, style: .action(entry.summary.kind)))

    // Who — driver + optional script (cwd is no longer appended here).
    let driver = driverDescription(chain: entry.chain, claudeSession: entry.claudeSession)
    var whoValue = driver.text
    if entry.claudeSession == nil, let s = entry.scriptInfo {
        // Show the command name too — for a plain invoked command the name is
        // the leading argv token (`git commit -m msg`); scriptName alone would
        // drop it. For an interpreter it prepends `python app.py` etc.
        whoValue += " \u{00B7} \(s.interpreter) \(s.scriptName)"
    }
    rows.append(BodyRow(label: "who", value: whoValue, style: .who(driver.kind)))

    // Location block.
    if let git = entry.gitContext {
        rows.append(BodyRow(label: "git-root", value: git.root, style: .field(.gitRoot)))
        if let branch = git.branch {
            rows.append(BodyRow(label: "branch", value: branch, style: .field(.branch)))
        }
        if let sub = git.worktreeSubpath {
            rows.append(BodyRow(label: "worktree", value: sub, style: .field(.worktree)))
        } else if !dense {
            rows.append(BodyRow(label: "worktree", value: "(main)", style: .field(.worktree)))
        }
    } else if let cwd = entry.cwd, cwd != "/", !cwd.isEmpty {
        rows.append(BodyRow(label: "cwd", value: cwd, style: .field(.plain)))
    }

    // Asked — Claude natural-language prompt, last.
    if let prompt = entry.claudeContext?.lastUserPrompt, !prompt.isEmpty {
        rows.append(BodyRow(label: "asked", value: "\u{201C}\(prompt)\u{201D}", style: .asked))
    }

    return rows
}

/// One node of the rendered process tree.
public struct TreeNode: Equatable {
    public let name: String
    public let pid: pid_t
    /// 0 = parent-est (usually the terminal app); each child is +1.
    public let depth: Int
    /// Coloring hint for the `op` node; `.none` for every other node.
    public let opColor: OpColor
}

public enum OpColor: Equatable { case none, verified, unverified }

/// Build the process tree parent-first. `chain` is trigger-first (chain[0] is
/// the trigger); it is reversed here. The terminal app, when known, is
/// prepended as the root (`<name>.app`). Pure — no AppKit.
func processTreeNodes(appName: String?, appPID: pid_t?, chain: [ProcessNode]) -> [TreeNode] {
    var nodes: [TreeNode] = []
    var depth = 0
    if let appName = appName {
        nodes.append(TreeNode(name: "\(appName).app", pid: appPID ?? 0,
                              depth: depth, opColor: .none))
        depth += 1
    }
    for node in chain.reversed() {
        let color: OpColor
        if node.name == "op" {
            color = node.isVerifiedOnePasswordCLI ? .verified : .unverified
        } else {
            color = .none
        }
        nodes.append(TreeNode(name: node.name, pid: node.pid, depth: depth, opColor: color))
        depth += 1
    }
    return nodes
}

/// The YAML lines shown under the process tree in the details block.
/// No cwd (spec). Pure — argv is already redacted at capture.
func detailsYAMLLines(entry: OverlayPanel.ProcessEntry) -> [String] {
    var lines: [String] = []
    if let tty = entry.tty { lines.append("tty: \(tty)") }
    lines.append("pid: \(entry.pid)")

    if let ws = entry.cmuxWorkspaceID {
        let title = entry.cmuxSurface?.displayWorkspaceTitle ?? ""
        lines.append(title.isEmpty ? "workspace: \(ws)" : "workspace: \(title) (\(ws))")
    }
    if let tab = entry.cmuxTabID {
        let raw = entry.cmuxSurface?.surfaceTitle ?? ""
        let title = CmuxHelper.looksGenericTitle(raw) ? "" : raw
        lines.append(title.isEmpty ? "tab: \(tab)" : "tab: \(title) (\(tab))")
    }

    if !entry.triggerArgv.isEmpty {
        lines.append("argv:")
        for token in entry.triggerArgv { lines.append("  - \(token)") }
    }
    return lines
}
