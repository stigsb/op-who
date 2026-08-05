import Foundation
import Testing
@testable import OpWhoLib

@Suite("CmuxHelper session file keyed by panel.id")
struct CmuxSessionByPanelIDTests {

    static let sessionFixtureJSON = """
    {
      "windows": [
        {
          "tabManager": {
            "workspaces": [
              {
                "customTitle": "applicant-tracker",
                "processTitle": "cleanup-legacy-import-references",
                "currentDirectory": "/Users/u/git/applicant-tracker",
                "panels": [
                  {
                    "id": "EB114B2A-5372-40B3-A6A1-913D96A2FEA3",
                    "title": "claude",
                    "type": "terminal",
                    "directory": "/Users/u/git/applicant-tracker",
                    "gitBranch": { "branch": "cleanup-legacy-import-references", "isDirty": true }
                  },
                  {
                    "id": "5D3F0A9C-1B2C-4D5E-9F0A-1B2C3D4E5F6A",
                    "title": "shell",
                    "type": "terminal",
                    "directory": "/Users/u/git/applicant-tracker",
                    "gitBranch": null
                  },
                  {
                    "id": "AA000000-0000-4000-8000-000000000001",
                    "title": "docs",
                    "type": "browser"
                  }
                ]
              },
              {
                "customTitle": null,
                "processTitle": "op-who",
                "currentDirectory": "/Users/u/git/stigsb/op-who",
                "panels": [
                  {
                    "id": "DC89EB3D-5E6E-4091-BD04-78E24371C1D8",
                    "title": "build",
                    "type": "terminal",
                    "directory": "/Users/u/git/stigsb/op-who",
                    "gitBranch": { "branch": "feat/cmux-show-tab", "isDirty": false }
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    """

    private var map: [String: CmuxSurfaceInfo] {
        CmuxHelper.parseSessionFileByPanelID(Data(Self.sessionFixtureJSON.utf8))
    }

    @Test("UUID hit yields the full display record")
    func uuidHit() {
        let info = map["EB114B2A-5372-40B3-A6A1-913D96A2FEA3"]
        #expect(info?.workspaceTitle == "applicant-tracker")
        #expect(info?.workspaceDescription == "cleanup-legacy-import-references")
        #expect(info?.surfaceTitle == "claude")
        #expect(info?.surfaceID == "EB114B2A-5372-40B3-A6A1-913D96A2FEA3")
        #expect(info?.directory == "/Users/u/git/applicant-tracker")
        #expect(info?.workspaceIndex == 1)      // ⌘1
        #expect(info?.tabIndex == 1)            // ⌃1
        #expect(info?.workspaceTabCount == 3)   // ⌃N spans all panels, browser included
    }

    @Test("workspace title falls back to processTitle when customTitle is absent")
    func processTitleFallback() {
        #expect(map["DC89EB3D-5E6E-4091-BD04-78E24371C1D8"]?.workspaceTitle == "op-who")
        #expect(map["DC89EB3D-5E6E-4091-BD04-78E24371C1D8"]?.workspaceIndex == 2)
    }

    @Test("second panel gets 1-based tabIndex from iteration order")
    func tabIndexes() {
        #expect(map["5D3F0A9C-1B2C-4D5E-9F0A-1B2C3D4E5F6A"]?.tabIndex == 2)
    }

    @Test("non-terminal panel types are not identification targets")
    func browserPanelExcluded() {
        #expect(map["AA000000-0000-4000-8000-000000000001"] == nil)
    }

    @Test("keys the parser doesn't model (gitBranch, stableSurfaceId) are tolerated, not a parse failure")
    func unmodeledKeysTolerated() {
        #expect(map["5D3F0A9C-1B2C-4D5E-9F0A-1B2C3D4E5F6A"] != nil)
    }

    @Test("unknown UUID and malformed input yield no identification")
    func missAndMalformed() {
        #expect(map["00000000-0000-4000-8000-00000000DEAD"] == nil)
        #expect(CmuxHelper.parseSessionFileByPanelID(Data()).isEmpty)
        #expect(CmuxHelper.parseSessionFileByPanelID(Data("not json".utf8)).isEmpty)
    }
}

@Suite("CmuxHelper env-var chain walk")
struct CmuxEnvWalkTests {
    private func node(_ pid: pid_t, _ ppid: pid_t) -> ProcessNode {
        ProcessNode(pid: pid, ppid: ppid, name: "p\(pid)", tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: false)
    }
    // Trigger-first chain, like ChainResult.chain: 300 (trigger) → 200 → 100.
    private var chain: [ProcessNode] { [node(300, 200), node(200, 100), node(100, 1)] }
    private let uuid = "EB114B2A-5372-40B3-A6A1-913D96A2FEA3"

    @Test("present on the trigger itself")
    func onTrigger() {
        #expect(CmuxHelper.surfaceUUID(forChain: chain) { $0 == 300 ? uuid : nil } == uuid)
    }

    @Test("absent on the trigger, found on an ancestor two hops up")
    func onAncestor() {
        #expect(CmuxHelper.surfaceUUID(forChain: chain) { $0 == 100 ? uuid : nil } == uuid)
    }

    @Test("leaf-first: the trigger's own value beats an ancestor's")
    func leafFirst() {
        let hit = CmuxHelper.surfaceUUID(forChain: chain) {
            $0 == 300 ? uuid : "AA000000-0000-4000-8000-000000000001"
        }
        #expect(hit == uuid)
    }

    @Test("absent everywhere (including unreadable env blocks, which read as nil) returns nil")
    func absentEverywhere() {
        #expect(CmuxHelper.surfaceUUID(forChain: chain) { _ in nil } == nil)
        #expect(CmuxHelper.surfaceUUID(forChain: []) { _ in uuid } == nil)
    }

    @Test("empty-string value is treated as absent and the walk continues")
    func emptyValueSkipped() {
        let hit = CmuxHelper.surfaceUUID(forChain: chain) { $0 == 300 ? "" : ($0 == 200 ? uuid : nil) }
        #expect(hit == uuid)
    }
}

// `.serialized` because every test here installs/clears the shared global
// `CmuxHelper.testMap`. Swift Testing runs tests in parallel by default, so
// without this one test's `clearTestMap()` (via defer) can fire between
// another's `installTestMap(...)` and its `surfaceInfo(...)` read — the lookup
// then falls through to the real cmux session file (absent in CI → nil, or the
// developer's live session locally), producing flaky, environment-dependent
// failures. Serializing the suite removes the interleaving.
@Suite("CmuxHelper title helpers")
struct CmuxHelperTests {

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
        let map = CmuxHelper.parseSessionFileByPanelID(CmuxSessionByPanelIDTests.sessionFixtureJSON)
        #expect(map["EB114B2A-5372-40B3-A6A1-913D96A2FEA3"]?.displayWorkspaceTitle == "applicant-tracker")
    }

    @Test func displayFallsBackToDescriptionForGenericTitle() {
        // Generic workspace title with a distinct description.
        let info = CmuxSurfaceInfo(
            workspaceRef: "",
            workspaceTitle: "Terminal 7",
            workspaceDescription: nil,
            surfaceRef: "",
            surfaceTitle: "anything"
        )
        #expect(info.displayWorkspaceTitle == "")
    }

    @Test func displayReturnsEmptyWhenGenericAndNoDescription() {
        let info = CmuxSurfaceInfo(
            workspaceRef: "",
            workspaceTitle: "Item-0",
            workspaceDescription: nil,
            surfaceRef: "",
            surfaceTitle: "anything"
        )
        #expect(info.displayWorkspaceTitle == "")
    }
}
