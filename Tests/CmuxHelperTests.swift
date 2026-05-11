import Testing
@testable import OpWhoLib

@Suite("CmuxHelper parser")
struct CmuxHelperTests {

    /// A trimmed-down but realistic chunk of `cmux tree --all` output.
    private let sample = """
    window window:1 [current] ◀ active
    ├── workspace workspace:15 "/Users/stig/git/stigsb/op-who" [selected] ◀ active
    │   └── pane pane:15 [focused] ◀ active
    │       ├── surface surface:35 [terminal] "/Users/stig/git/stigsb/op-who" [selected] ◀ active ◀ here tty=ttys033
    │       └── surface surface:36 [terminal] "/Users/stig/git/stigsb/op-who" tty=ttys034
    ├── workspace workspace:11 "trusthere"
    │   └── pane pane:11 [focused]
    │       └── surface surface:26 [terminal] "main" [selected] tty=ttys019
    └── workspace workspace:1 "secret-fuse"
        └── pane pane:1 [focused]
            └── surface surface:3 [terminal] "secret-fuse" [selected] tty=ttys000
    """

    @Test func parsesAllSurfaces() {
        let map = CmuxHelper.parseTree(sample)
        #expect(map.count == 4)
        #expect(map["ttys033"]?.surfaceRef == "surface:35")
        #expect(map["ttys033"]?.workspaceRef == "workspace:15")
        #expect(map["ttys019"]?.workspaceTitle == "trusthere")
        #expect(map["ttys019"]?.surfaceTitle == "main")
        #expect(map["ttys000"]?.workspaceTitle == "secret-fuse")
        #expect(map["ttys000"]?.surfaceTitle == "secret-fuse")
    }

    @Test func workspaceContextPropagatesToSurfaces() {
        // Surface 34 should inherit workspace 15's identity even though the
        // workspace line comes several lines before it.
        let map = CmuxHelper.parseTree(sample)
        #expect(map["ttys034"]?.workspaceRef == "workspace:15")
        #expect(map["ttys034"]?.workspaceTitle == "/Users/stig/git/stigsb/op-who")
    }

    @Test func unknownTtyReturnsNil() {
        let map = CmuxHelper.parseTree(sample)
        #expect(map["ttys999"] == nil)
    }

    @Test func matchWorkspaceLine() {
        let line = "├── workspace workspace:7 \"data-platform\""
        let res = CmuxHelper.matchWorkspaceLine(line)
        #expect(res?.ref == "workspace:7")
        #expect(res?.title == "data-platform")
    }

    @Test func matchSurfaceLine() {
        let line = "│       ├── surface surface:35 [terminal] \"some title\" [selected] ◀ active tty=ttys033"
        let res = CmuxHelper.matchSurfaceLine(line)
        #expect(res?.ref == "surface:35")
        #expect(res?.title == "some title")
        #expect(res?.tty == "ttys033")
    }

    @Test func emptyOutputProducesEmptyMap() {
        #expect(CmuxHelper.parseTree("").isEmpty)
    }
}
