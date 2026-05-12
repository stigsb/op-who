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
