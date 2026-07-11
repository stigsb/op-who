import Foundation
import Testing
@testable import OpWhoLib

@Suite("GitContext.make")
struct GitContextMakeTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    @Test("main checkout: worktreeSubpath is nil")
    func mainCheckout() {
        let g = GitContext.make(
            toplevel: "\(home)/git/fleet",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "main",
            detachedSHA: nil
        )
        #expect(g.root == "~/git/fleet")
        #expect(g.branch == "main")
        #expect(g.worktreeSubpath == nil)
    }

    @Test("linked worktree one level down: relative subpath")
    func linkedWorktree() {
        let g = GitContext.make(
            toplevel: "\(home)/git/fleet/.claude/worktrees/foo",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "foo",
            detachedSHA: nil
        )
        #expect(g.root == "~/git/fleet")
        #expect(g.worktreeSubpath == ".claude/worktrees/foo")
    }

    @Test("far-flung worktree (ascends >1 level): absolute home-abbreviated path")
    func farFlungWorktree() {
        let g = GitContext.make(
            toplevel: "\(home)/tmp/wt-foo",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "foo",
            detachedSHA: nil
        )
        #expect(g.root == "~/git/fleet")
        #expect(g.worktreeSubpath == "~/tmp/wt-foo")
    }

    @Test("sibling worktree (ascends exactly 1 level): kept relative")
    func siblingWorktree() {
        let g = GitContext.make(
            toplevel: "\(home)/git/fleet-foo",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "foo",
            detachedSHA: nil
        )
        #expect(g.worktreeSubpath == "../fleet-foo")
    }

    @Test("detached HEAD: branch falls back to short SHA")
    func detachedHead() {
        let g = GitContext.make(
            toplevel: "\(home)/git/fleet",
            gitCommonDir: "\(home)/git/fleet/.git",
            branchRaw: "HEAD",
            detachedSHA: "a1b2c3d"
        )
        #expect(g.branch == "a1b2c3d")
    }
}
