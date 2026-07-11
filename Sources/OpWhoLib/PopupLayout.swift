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
    /// A labeled context field (git-root/branch/worktree/cwd) — dim label,
    /// bright value.
    case field
    /// The wrapping Claude "asked" prompt line.
    case asked
}

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
        whoValue += " \u{00B7} \(s.scriptName)"
    }
    rows.append(BodyRow(label: "who", value: whoValue, style: .who(driver.kind)))

    // Location block.
    if let git = entry.gitContext {
        rows.append(BodyRow(label: "git-root", value: git.root, style: .field))
        if let branch = git.branch {
            rows.append(BodyRow(label: "branch", value: branch, style: .field))
        }
        if let sub = git.worktreeSubpath {
            rows.append(BodyRow(label: "worktree", value: sub, style: .field))
        } else if !dense {
            rows.append(BodyRow(label: "worktree", value: "(main)", style: .field))
        }
    } else if let cwd = entry.cwd, cwd != "/", !cwd.isEmpty {
        rows.append(BodyRow(label: "cwd", value: cwd, style: .field))
    }

    // Asked — Claude natural-language prompt, last.
    if let prompt = entry.claudeContext?.lastUserPrompt, !prompt.isEmpty {
        rows.append(BodyRow(label: "asked", value: "\u{201C}\(prompt)\u{201D}", style: .asked))
    }

    return rows
}
