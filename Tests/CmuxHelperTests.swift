import Foundation
import Testing
@testable import OpWhoLib

@Suite("CmuxHelper session-file parser")
struct CmuxHelperTests {

    /// Trimmed-down but realistic chunk of cmux's
    /// `~/Library/Application Support/cmux/session-com.cmuxterm.app.json`.
    /// Three workspaces: one user-named ("trusthere"), one customTitle=null
    /// path-named, and one with neither customTitle nor processTitle.
    private let sampleJSON = """
    {
      "version": 1,
      "createdAt": "2026-05-12T00:00:00Z",
      "windows": [
        {
          "tabManager": {
            "workspaces": [
              {
                "customTitle": "trusthere",
                "processTitle": "Terminal 1",
                "currentDirectory": "/Users/stig/git/trusthere",
                "panels": [
                  {
                    "id": "panel-1",
                    "title": "main",
                    "ttyName": "ttys019",
                    "type": "terminal"
                  },
                  {
                    "id": "panel-2",
                    "title": "trusthere",
                    "ttyName": "ttys021",
                    "type": "terminal"
                  }
                ]
              },
              {
                "customTitle": null,
                "processTitle": "/Users/stig/git/stigsb/op-who",
                "currentDirectory": "/Users/stig/git/stigsb/op-who",
                "panels": [
                  {
                    "id": "panel-3",
                    "title": "/Users/stig/git/stigsb/op-who",
                    "ttyName": "ttys033",
                    "type": "terminal"
                  }
                ]
              },
              {
                "customTitle": null,
                "processTitle": "Terminal 7",
                "currentDirectory": "/tmp",
                "panels": [
                  {
                    "id": "panel-4",
                    "title": "",
                    "ttyName": "ttys077",
                    "type": "terminal"
                  },
                  {
                    "id": "panel-5",
                    "title": "cmux landing",
                    "ttyName": null,
                    "type": "browser"
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    """

    @Test func parsesAllTerminalPanels() {
        let map = CmuxHelper.parseSessionFile(sampleJSON)
        // 4 terminal panels (the browser panel with ttyName=null is excluded).
        #expect(map.count == 4)
        #expect(map["ttys019"]?.workspaceTitle == "trusthere")
        #expect(map["ttys019"]?.surfaceTitle == "main")
        #expect(map["ttys021"]?.surfaceTitle == "trusthere")
    }

    @Test func workspaceTitlePrefersCustomTitle() {
        // workspace 1 has customTitle="trusthere" and processTitle="Terminal 1".
        // We must take the user-set customTitle, not the auto-named processTitle.
        let map = CmuxHelper.parseSessionFile(sampleJSON)
        #expect(map["ttys019"]?.workspaceTitle == "trusthere")
        #expect(map["ttys019"]?.workspaceDescription == "Terminal 1")
    }

    @Test func workspaceTitleFallsBackToProcessTitle() {
        // workspace 2 has customTitle=null — processTitle is the path.
        let map = CmuxHelper.parseSessionFile(sampleJSON)
        #expect(map["ttys033"]?.workspaceTitle == "/Users/stig/git/stigsb/op-who")
        #expect(map["ttys033"]?.workspaceDescription == nil)
    }

    @Test func panelsWithoutTTYAreFilteredOut() {
        // Browser panel had ttyName=null; should not appear under any key.
        let map = CmuxHelper.parseSessionFile(sampleJSON)
        for info in map.values {
            #expect(info.surfaceType == "terminal")
            #expect(info.surfaceRef != "surface:panel-5")
        }
    }

    @Test func unknownTtyReturnsNil() {
        let map = CmuxHelper.parseSessionFile(sampleJSON)
        #expect(map["ttys999"] == nil)
    }

    @Test func emptyOutputProducesEmptyMap() {
        #expect(CmuxHelper.parseSessionFile(Data()).isEmpty)
        #expect(CmuxHelper.parseSessionFile("").isEmpty)
        #expect(CmuxHelper.parseSessionFile("not json at all").isEmpty)
    }

    @Test func ttyWithDevPrefixIsStripped() {
        let json = """
        {"windows":[{"tabManager":{"workspaces":[{
          "customTitle":"x","processTitle":null,"currentDirectory":null,
          "panels":[{"id":"a","title":"t","ttyName":"/dev/ttys010","type":"terminal"}]
        }]}}]}
        """
        let map = CmuxHelper.parseSessionFile(json)
        #expect(map["ttys010"]?.surfaceTitle == "t")
        #expect(map["/dev/ttys010"] == nil)
    }

    // MARK: - Colliding TTYs disambiguated by trigger CWD

    /// Two terminal panels in different workspaces share the SAME ttyName
    /// ("ttys015") — tty device numbers get recycled and cmux leaves stale
    /// entries. They live in different directories. surfaceInfo must pick the
    /// panel whose directory the trigger is actually inside (by CWD), not
    /// whichever the parser happened to insert last.
    private let collidingTTYJSON = """
    {
      "windows": [
        {
          "tabManager": {
            "workspaces": [
              {
                "customTitle": "api-token-broker",
                "processTitle": null,
                "currentDirectory": "/Users/x/otel-token-broker",
                "panels": [
                  {
                    "id": "panel-a",
                    "title": "api-token-broker",
                    "ttyName": "ttys015",
                    "type": "terminal",
                    "directory": "/Users/x/otel-token-broker"
                  }
                ]
              },
              {
                "customTitle": "agent-vent",
                "processTitle": null,
                "currentDirectory": "/Users/x/claude-plugins/.claude/worktrees/agent-vent",
                "panels": [
                  {
                    "id": "panel-b",
                    "title": "claude-plugins",
                    "ttyName": "ttys015",
                    "type": "terminal",
                    "directory": "/Users/x/claude-plugins/.claude/worktrees/agent-vent"
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    """

    @Test func collidingTTYDisambiguatedByTriggerCWD() {
        // The regression case: ttys015 is shared by api-token-broker and
        // agent-vent. The trigger's CWD is inside agent-vent — we must return
        // the agent-vent panel, NOT api-token-broker.
        CmuxHelper.installTestMap(CmuxHelper.parseSessionFileGrouped(collidingTTYJSON))
        defer { CmuxHelper.clearTestMap() }
        let info = CmuxHelper.surfaceInfo(
            forTTY: "/dev/ttys015",
            triggerCWD: "/Users/x/claude-plugins/.claude/worktrees/agent-vent"
        )
        #expect(info?.workspaceTitle == "agent-vent")
        #expect(info?.workspaceTitle != "api-token-broker")
    }

    @Test func singleCandidateReturnedRegardlessOfTriggerCWD() {
        // No collision: a single panel for ttys015. It must be returned even
        // when the trigger CWD doesn't match its directory (no regression vs.
        // the old behaviour where any matching tty was returned).
        let json = """
        {"windows":[{"tabManager":{"workspaces":[{
          "customTitle":"solo","processTitle":null,"currentDirectory":"/Users/x/solo",
          "panels":[{"id":"s","title":"t","ttyName":"ttys015","type":"terminal","directory":"/Users/x/solo"}]
        }]}}]}
        """
        CmuxHelper.installTestMap(CmuxHelper.parseSessionFileGrouped(json))
        defer { CmuxHelper.clearTestMap() }
        #expect(CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: "/totally/unrelated").map(\.workspaceTitle) == "solo")
        #expect(CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: nil).map(\.workspaceTitle) == "solo")
    }

    @Test func multipleCandidatesNoMatchReturnsNil() {
        // Two candidates, but the trigger CWD is inside neither panel's dir.
        // We must NOT guess — return nil (showing no workspace is correct).
        CmuxHelper.installTestMap(CmuxHelper.parseSessionFileGrouped(collidingTTYJSON))
        defer { CmuxHelper.clearTestMap() }
        let info = CmuxHelper.surfaceInfo(
            forTTY: "/dev/ttys015",
            triggerCWD: "/Users/x/somewhere/else"
        )
        #expect(info == nil)
    }

    @Test func multipleCandidatesNilTriggerCWDReturnsNil() {
        // Two candidates, trigger CWD unknown → can't disambiguate → nil.
        CmuxHelper.installTestMap(CmuxHelper.parseSessionFileGrouped(collidingTTYJSON))
        defer { CmuxHelper.clearTestMap() }
        let info = CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: nil)
        #expect(info == nil)
    }

    @Test func prefixMatchIsPathComponentAware() {
        // Two candidates: /a/b and /a/bc. A trigger CWD of /a/b/sub must match
        // /a/b (subdir) but NOT /a/bc (sibling sharing a name prefix).
        let json = """
        {"windows":[{"tabManager":{"workspaces":[
          {"customTitle":"bee","processTitle":null,"currentDirectory":"/a/b",
           "panels":[{"id":"p1","title":"t","ttyName":"ttys015","type":"terminal","directory":"/a/b"}]},
          {"customTitle":"beecee","processTitle":null,"currentDirectory":"/a/bc",
           "panels":[{"id":"p2","title":"t","ttyName":"ttys015","type":"terminal","directory":"/a/bc"}]}
        ]}}]}
        """
        CmuxHelper.installTestMap(CmuxHelper.parseSessionFileGrouped(json))
        defer { CmuxHelper.clearTestMap() }
        #expect(CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: "/a/b/sub").map(\.workspaceTitle) == "bee")
        // Exact match of the sibling resolves to that sibling, not /a/b.
        #expect(CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: "/a/bc").map(\.workspaceTitle) == "beecee")
        // A CWD that is a prefix-sharing non-subdir of /a/b matches neither
        // (it's /a/bc-style); /a/bcd is under neither panel dir.
        #expect(CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: "/a/bcd") == nil)
    }

    @Test func longestDirectoryWinsAmongMultipleMatches() {
        // Nested panels both prefix the trigger CWD; the more specific
        // (longest) directory must win.
        let json = """
        {"windows":[{"tabManager":{"workspaces":[
          {"customTitle":"outer","processTitle":null,"currentDirectory":"/a",
           "panels":[{"id":"p1","title":"t","ttyName":"ttys015","type":"terminal","directory":"/a"}]},
          {"customTitle":"inner","processTitle":null,"currentDirectory":"/a/b",
           "panels":[{"id":"p2","title":"t","ttyName":"ttys015","type":"terminal","directory":"/a/b"}]}
        ]}}]}
        """
        CmuxHelper.installTestMap(CmuxHelper.parseSessionFileGrouped(json))
        defer { CmuxHelper.clearTestMap() }
        #expect(CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: "/a/b/c").map(\.workspaceTitle) == "inner")
    }

    @Test func parsedPanelCarriesDirectory() {
        let map = CmuxHelper.parseSessionFileGrouped(collidingTTYJSON)
        let candidates = map["ttys015"] ?? []
        #expect(candidates.count == 2)
        #expect(candidates.contains { $0.directory == "/Users/x/otel-token-broker" })
        #expect(candidates.contains { $0.directory == "/Users/x/claude-plugins/.claude/worktrees/agent-vent" })
    }

    /// ProcessTree.processCWD returns symlink-resolved paths (e.g. /private/var)
    /// while cmux records the unresolved panel directory (e.g. /var). The
    /// disambiguation must still match across that difference. We build a real
    /// temp symlink so the test is deterministic and doesn't depend on any
    /// machine-specific symlink layout.
    @Test func surfaceInfoMatchesAcrossSymlinkedPaths() throws {
        let fm = FileManager.default
        let realDir = fm.temporaryDirectory
            .appendingPathComponent("op-who-real-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        let linkDir = fm.temporaryDirectory
            .appendingPathComponent("op-who-link-\(UUID().uuidString)", isDirectory: true)
        try fm.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        defer {
            try? fm.removeItem(at: linkDir)
            try? fm.removeItem(at: realDir)
        }

        // Panel directory is the UNRESOLVED symlink path; trigger CWD is the
        // RESOLVED real path. They differ as raw strings but normalize equal.
        let panelDir = linkDir.path
        let triggerCWD = realDir.resolvingSymlinksInPath().path
        #expect(panelDir != triggerCWD)  // guard against a vacuous test

        let map: [String: [CmuxSurfaceInfo]] = [
            "ttys015": [
                CmuxSurfaceInfo(
                    workspaceRef: "workspace:0:0",
                    workspaceTitle: "other",
                    surfaceRef: "surface:o",
                    surfaceTitle: "t",
                    tty: "ttys015",
                    directory: "/some/unrelated/dir"
                ),
                CmuxSurfaceInfo(
                    workspaceRef: "workspace:0:1",
                    workspaceTitle: "linked",
                    surfaceRef: "surface:l",
                    surfaceTitle: "t",
                    tty: "ttys015",
                    directory: panelDir
                ),
            ]
        ]
        CmuxHelper.installTestMap(map)
        defer { CmuxHelper.clearTestMap() }

        let info = CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: triggerCWD)
        #expect(info?.workspaceTitle == "linked")
    }

    /// An empty panel directory must never match: "" + "/" == "/" would otherwise
    /// prefix every absolute path and win over real candidates.
    @Test func emptyPanelDirectoryIsNotMatched() {
        let map: [String: [CmuxSurfaceInfo]] = [
            "ttys015": [
                CmuxSurfaceInfo(
                    workspaceRef: "workspace:0:0",
                    workspaceTitle: "empty",
                    surfaceRef: "surface:e",
                    surfaceTitle: "t",
                    tty: "ttys015",
                    directory: ""
                ),
                CmuxSurfaceInfo(
                    workspaceRef: "workspace:0:1",
                    workspaceTitle: "real",
                    surfaceRef: "surface:r",
                    surfaceTitle: "t",
                    tty: "ttys015",
                    directory: "/Users/x/real"
                ),
            ]
        ]
        CmuxHelper.installTestMap(map)
        defer { CmuxHelper.clearTestMap() }

        // CWD inside the real panel → must pick "real", never the empty one.
        #expect(CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: "/Users/x/real/sub")?.workspaceTitle == "real")
        // CWD matching neither → nil (the empty dir must not act as a catch-all).
        #expect(CmuxHelper.surfaceInfo(forTTY: "/dev/ttys015", triggerCWD: "/Users/x/elsewhere") == nil)
    }

    // MARK: - Generic-title detection

    @Test func looksGenericTitleMatchesCmuxPlaceholders() {
        #expect(CmuxHelper.looksGenericTitle("Item-0"))
        #expect(CmuxHelper.looksGenericTitle("Item-12"))
        #expect(CmuxHelper.looksGenericTitle("Item 3"))
        #expect(CmuxHelper.looksGenericTitle("item-0"))           // case-insensitive
        #expect(CmuxHelper.looksGenericTitle("Workspace 1"))
        #expect(CmuxHelper.looksGenericTitle("Workspace-7"))
        #expect(CmuxHelper.looksGenericTitle("Terminal 1"))       // processTitle auto-name
        #expect(CmuxHelper.looksGenericTitle("Terminal-2"))
        #expect(CmuxHelper.looksGenericTitle(""))
        #expect(CmuxHelper.looksGenericTitle("   "))
    }

    @Test func looksGenericTitleRejectsRealNames() {
        #expect(!CmuxHelper.looksGenericTitle("trusthere"))
        #expect(!CmuxHelper.looksGenericTitle("/Users/stig/git/stigsb/op-who"))
        #expect(!CmuxHelper.looksGenericTitle("Item"))            // no number
        #expect(!CmuxHelper.looksGenericTitle("Item-0-extra"))    // trailing junk
        #expect(!CmuxHelper.looksGenericTitle("My Item-0"))       // not anchored
        #expect(!CmuxHelper.looksGenericTitle("WorkspaceX"))
        #expect(!CmuxHelper.looksGenericTitle("TerminalApp"))
    }

    // MARK: - displayWorkspaceTitle

    @Test func displayUsesRealTitleAsIs() {
        let map = CmuxHelper.parseSessionFile(sampleJSON)
        #expect(map["ttys019"]?.displayWorkspaceTitle == "trusthere")
        #expect(map["ttys033"]?.displayWorkspaceTitle == "/Users/stig/git/stigsb/op-who")
    }

    @Test func displayFallsBackToDescriptionForGenericTitle() {
        // Workspace 3 has no customTitle and processTitle="Terminal 7" (generic).
        // displayWorkspaceTitle should be "" (description also generic).
        let info = CmuxSurfaceInfo(
            workspaceRef: "workspace:0:2",
            workspaceTitle: "Terminal 7",
            workspaceDescription: nil,
            surfaceRef: "surface:panel-4",
            surfaceTitle: "anything",
            tty: "ttys077"
        )
        #expect(info.displayWorkspaceTitle == "")
    }

    @Test func displayReturnsEmptyWhenGenericAndNoDescription() {
        let info = CmuxSurfaceInfo(
            workspaceRef: "workspace:1",
            workspaceTitle: "Item-0",
            workspaceDescription: nil,
            surfaceRef: "surface:1",
            surfaceTitle: "anything",
            tty: "ttys001"
        )
        #expect(info.displayWorkspaceTitle == "")
    }
}
