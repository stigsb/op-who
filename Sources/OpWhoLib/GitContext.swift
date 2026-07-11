import Foundation

/// Git context for the directory a 1Password trigger ran in. Resolved to the
/// *main* worktree even when the trigger ran inside a linked worktree.
public struct GitContext: Equatable {
    /// Main worktree top-level, home-abbreviated (e.g. "~/git/fleet").
    public let root: String
    /// Current branch, or a short SHA when HEAD is detached. nil if unknown.
    public let branch: String?
    /// Current worktree relative to `root` (e.g. ".claude/worktrees/foo"), or a
    /// full home-abbreviated path when it ascends more than one level, or nil in
    /// the main checkout.
    public let worktreeSubpath: String?

    public init(root: String, branch: String?, worktreeSubpath: String?) {
        self.root = root
        self.branch = branch
        self.worktreeSubpath = worktreeSubpath
    }

    /// Build a GitContext from raw `git rev-parse` outputs. Pure — no I/O.
    ///
    /// - `toplevel`: absolute `--show-toplevel` (current worktree).
    /// - `gitCommonDir`: absolute `--git-common-dir` (ends in `/.git` for the
    ///   main repo, shared by all linked worktrees).
    /// - `branchRaw`: `--abbrev-ref HEAD` ("HEAD" when detached).
    /// - `detachedSHA`: short SHA used when `branchRaw == "HEAD"`.
    public static func make(
        toplevel: String,
        gitCommonDir: String,
        branchRaw: String,
        detachedSHA: String?
    ) -> GitContext {
        let rootAbs: String
        if gitCommonDir.hasSuffix("/.git") {
            rootAbs = String(gitCommonDir.dropLast("/.git".count))
        } else if (gitCommonDir as NSString).lastPathComponent == ".git" {
            rootAbs = (gitCommonDir as NSString).deletingLastPathComponent
        } else {
            rootAbs = toplevel
        }

        let branch: String? = branchRaw == "HEAD" ? detachedSHA : branchRaw

        let subpath: String?
        if toplevel == rootAbs {
            subpath = nil
        } else {
            let rel = relativePath(from: rootAbs, to: toplevel)
            if rel.hasPrefix("../../") {
                subpath = ProcessTree.tidyPath(toplevel)
            } else {
                subpath = rel
            }
        }

        return GitContext(
            root: ProcessTree.tidyPath(rootAbs),
            branch: branch,
            worktreeSubpath: subpath
        )
    }

    /// Compute `to` relative to `from` using path components.
    static func relativePath(from: String, to: String) -> String {
        let fromParts = (from as NSString).pathComponents.filter { $0 != "/" }
        let toParts = (to as NSString).pathComponents.filter { $0 != "/" }
        var i = 0
        while i < fromParts.count, i < toParts.count, fromParts[i] == toParts[i] {
            i += 1
        }
        let ups = Array(repeating: "..", count: fromParts.count - i)
        let downs = Array(toParts[i...])
        return (ups + downs).joined(separator: "/")
    }
}
