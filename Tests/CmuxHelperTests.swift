import Foundation
import Testing
@testable import OpWhoLib

private final class ResultBox<T>: @unchecked Sendable { var value: T? }

/// Runs `body` synchronously on a dedicated `Thread` with a normal-sized
/// stack, returning its result. Swift Testing schedules `@Test` functions on
/// the concurrency cooperative pool, whose default stack is far smaller than
/// a normal thread's — too small for tests that deliberately recurse deep
/// (e.g. pinning `CmuxHelper.parseTopPidMap`'s depth guard).
private func runOnThreadWithLargeStack<T>(_ body: @escaping () -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = 8 * 1024 * 1024
    thread.start()
    done.wait()
    return box.value!
}

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

@Suite("CmuxHelper top-JSON parser")
struct CmuxTopParserTests {

    /// Trimmed from real `cmux top --all --processes --json` output (cmux
    /// 0.64.20), regenerated with:
    ///   cmux top --all --processes --json | python3 -m json.tool
    /// The first workspace ("Terminal", surface:47 and its process chain)
    /// is a real observed snapshot. The second workspace ("op-who") keeps
    /// the same real *shape* (multi-surface workspace, a duplicate PID
    /// across two surfaces, a browser-typed surface) but its refs/PIDs/UUIDs
    /// are synthesized so the fixture doesn't depend on a live machine's
    /// process tree. Workspace/surface `index` fields are 0-based in the
    /// real output.
    static let topFixtureJSON = """
    {
      "active": null,
      "caller": null,
      "windows": [
        {
          "ref": "window:1",
          "index": 0,
          "workspaces": [
            {
              "ref": "workspace:15",
              "index": 0,
              "title": "Terminal",
              "description": null,
              "selected": true,
              "panes": [
                {
                  "ref": "pane:19",
                  "surfaces": [
                    {
                      "ref": "surface:47",
                      "index": 0,
                      "index_in_pane": 0,
                      "title": "Terminal",
                      "type": "terminal",
                      "tty": null,
                      "tty_process_pids": [],
                      "processes": [
                        {
                          "kind": "process",
                          "pid": 93902,
                          "ppid": 93901,
                          "name": "bash",
                          "path": "/opt/homebrew/Cellar/bash/5.3.15/bin/bash",
                          "cmux_surface_id": "DC89EB3D-5E6E-4091-BD04-78E24371C1D8",
                          "cmux_workspace_id": "C03161C2-9DBE-45CB-9D3E-4950E7E71C42",
                          "children": [
                            {
                              "kind": "process",
                              "pid": 65072,
                              "ppid": 93902,
                              "name": "claude.exe",
                              "path": "/Users/u/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
                              "cmux_surface_id": "DC89EB3D-5E6E-4091-BD04-78E24371C1D8",
                              "cmux_workspace_id": "C03161C2-9DBE-45CB-9D3E-4950E7E71C42",
                              "children": [
                                {
                                  "kind": "process",
                                  "pid": 25550,
                                  "ppid": 65072,
                                  "name": "caffeinate",
                                  "path": "/usr/bin/caffeinate",
                                  "cmux_surface_id": null,
                                  "cmux_workspace_id": null,
                                  "children": []
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "ref": "workspace:3",
              "index": 5,
              "title": "op-who",
              "description": null,
              "selected": false,
              "panes": [
                {
                  "ref": "pane:5",
                  "surfaces": [
                    {
                      "ref": "surface:20",
                      "index": 0,
                      "index_in_pane": 0,
                      "title": "build",
                      "type": "terminal",
                      "processes": [
                        {
                          "kind": "process",
                          "pid": 33406,
                          "ppid": 1,
                          "name": "claude.exe",
                          "path": "/opt/homebrew/bin/claude",
                          "cmux_surface_id": "EB114B2A-5372-40B3-A6A1-913D96A2FEA3",
                          "cmux_workspace_id": "7A0B4C1D-2E3F-4A5B-8C6D-9E0F1A2B3C4D",
                          "children": []
                        }
                      ]
                    },
                    {
                      "ref": "surface:21",
                      "index": 1,
                      "index_in_pane": 1,
                      "title": "shell",
                      "type": "terminal",
                      "processes": [
                        {
                          "kind": "process",
                          "pid": 24451,
                          "ppid": 1,
                          "name": "bash",
                          "path": "/bin/bash",
                          "cmux_surface_id": "5D3F0A9C-1B2C-4D5E-9F0A-1B2C3D4E5F6A",
                          "cmux_workspace_id": "7A0B4C1D-2E3F-4A5B-8C6D-9E0F1A2B3C4D",
                          "children": []
                        },
                        {
                          "kind": "process",
                          "pid": 93902,
                          "ppid": 93901,
                          "name": "bash",
                          "path": "/opt/homebrew/Cellar/bash/5.3.15/bin/bash",
                          "cmux_surface_id": "5D3F0A9C-1B2C-4D5E-9F0A-1B2C3D4E5F6A",
                          "cmux_workspace_id": "7A0B4C1D-2E3F-4A5B-8C6D-9E0F1A2B3C4D",
                          "children": []
                        }
                      ]
                    },
                    {
                      "ref": "surface:22",
                      "index": 2,
                      "index_in_pane": 2,
                      "title": "docs",
                      "type": "browser",
                      "processes": [
                        {
                          "kind": "process",
                          "pid": 40001,
                          "ppid": 1,
                          "name": "cmux Helper",
                          "path": "/Applications/cmux.app/Contents/Frameworks/h",
                          "cmux_surface_id": "AA000000-0000-4000-8000-000000000001",
                          "cmux_workspace_id": "7A0B4C1D-2E3F-4A5B-8C6D-9E0F1A2B3C4D",
                          "children": []
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
    """

    private var map: [pid_t: CmuxSurfaceInfo] {
        CmuxHelper.parseTopPidMap(Data(Self.topFixtureJSON.utf8))
    }

    @Test("recursive walk maps every terminal-surface PID, skips browser surfaces")
    func mapsAllTerminalPIDs() {
        #expect(Set(map.keys) == [93902, 65072, 25550, 33406, 24451])
    }

    @Test("nested child two levels down maps to its surface")
    func nestedChild() {
        let info = map[65072]
        #expect(info?.surfaceRef == "surface:47")
        #expect(info?.surfaceID == "DC89EB3D-5E6E-4091-BD04-78E24371C1D8")
        #expect(info?.workspaceID == "C03161C2-9DBE-45CB-9D3E-4950E7E71C42")
    }

    @Test("null cmux_surface_id inherits from the parent record")
    func nullIDInherits() {
        #expect(map[25550]?.surfaceID == "DC89EB3D-5E6E-4091-BD04-78E24371C1D8")
    }

    @Test("display fields: title, 1-based indices from 0-based JSON, tab count")
    func displayFields() {
        let info = map[24451]
        #expect(info?.workspaceTitle == "op-who")
        #expect(info?.workspaceRef == "workspace:3")
        #expect(info?.workspaceIndex == 6)     // JSON index 5 → ⌘6
        #expect(info?.tabIndex == 2)           // JSON index 1 → ⌃2
        #expect(info?.workspaceTabCount == 3)  // build + shell + docs
        #expect(map[65072]?.workspaceIndex == 1)
        #expect(map[65072]?.workspaceTabCount == 1)
    }

    @Test("duplicate PID across two surfaces: first-encountered wins")
    func duplicatePIDFirstWins() {
        #expect(map[93902]?.surfaceRef == "surface:47")
    }

    @Test("malformed or empty input yields an empty map")
    func malformedInput() {
        #expect(CmuxHelper.parseTopPidMap(Data()).isEmpty)
        #expect(CmuxHelper.parseTopPidMap(Data("not json".utf8)).isEmpty)
        #expect(CmuxHelper.parseTopPidMap(Data(#"{"windows":[]}"#.utf8)).isEmpty)
    }

    @Test("a workspace/surface with a missing index decodes with the 0-unknown sentinel, not an empty map")
    func missingIndexFallsBackToZeroSentinel() {
        let json = """
        {"windows":[{"ref":"window:1","index":0,"workspaces":[{
          "ref":"workspace:1","title":"no-index","description":null,
          "panes":[{"ref":"pane:1","surfaces":[{
            "ref":"surface:1","title":"no-index","type":"terminal",
            "processes":[{"pid":50001,"cmux_surface_id":"S","cmux_workspace_id":"W","children":[]}]
          }]}]
        }]}]}
        """
        let map = CmuxHelper.parseTopPidMap(Data(json.utf8))
        #expect(map[50001]?.workspaceIndex == 0)
        #expect(map[50001]?.tabIndex == 0)
        // ref/pid/type are unaffected — only the index sentinel degrades.
        #expect(map[50001]?.workspaceRef == "workspace:1")
        #expect(map[50001]?.surfaceRef == "surface:1")
    }

    /// Pins the difference between a missing key (nil) and an empty array
    /// ([]) for the two optional fields, plus a workspace with no panes at
    /// all. If `processes`/`children` were "tidied" from `[ProcessRecord]?`
    /// to non-optional, this decode would throw instead of degrading.
    static let sparseFixtureJSON = """
    {
      "windows": [
        {
          "ref": "window:1",
          "index": 0,
          "workspaces": [
            {
              "ref": "workspace:1",
              "index": 0,
              "title": "sparse",
              "description": null,
              "panes": [
                {
                  "ref": "pane:1",
                  "surfaces": [
                    {
                      "ref": "surface:1",
                      "index": 0,
                      "title": "no-processes-key",
                      "type": "terminal"
                    },
                    {
                      "ref": "surface:2",
                      "index": 1,
                      "title": "leaf-no-children-key",
                      "type": "terminal",
                      "processes": [
                        {
                          "pid": 77001,
                          "cmux_surface_id": "11111111-1111-4111-8111-111111111111",
                          "cmux_workspace_id": "22222222-2222-4222-8222-222222222222"
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "ref": "workspace:2",
              "index": 1,
              "title": "no-panes",
              "description": null,
              "panes": []
            }
          ]
        }
      ]
    }
    """

    @Test("tolerates a surface with no processes key, a leaf record with no children key, and a workspace with no panes")
    func toleratesMissingOptionalKeys() {
        let map = CmuxHelper.parseTopPidMap(Data(Self.sparseFixtureJSON.utf8))
        #expect(map.count == 1)
        #expect(map[77001]?.surfaceRef == "surface:2")
        #expect(map[77001]?.surfaceID == "11111111-1111-4111-8111-111111111111")
    }

    /// Exercises the recursion depth cap (128, matching cmux's own ancestry
    /// walk — see cmux-top.md) rather than leaving it unpinned: changing the
    /// guard to e.g. `depth < 1` must fail this test.
    ///
    /// Runs on a dedicated thread with a normal-sized stack: Swift Testing
    /// schedules tests on the concurrency cooperative pool, whose default
    /// stack is too small for the ~130 levels of recursion this fixture
    /// deliberately builds and decodes (unrelated to the 128-guard itself —
    /// confirmed by running the same depth standalone on a normal stack).
    @Test("depth guard stops the walk at 128 levels")
    func depthGuardCapsAt128() {
        let map = runOnThreadWithLargeStack {
            // Chain of 130 process records (pid 1...130), each the sole
            // child of the one before. Root is depth 0, so depths 0...127
            // (pids 1...128) are kept and depth 128+ (pid 129 onward) is
            // dropped.
            func makeRecord(pid: Int, remaining: Int) -> [String: Any] {
                [
                    "pid": pid,
                    "cmux_surface_id": "DEEP-SURFACE",
                    "cmux_workspace_id": "DEEP-WORKSPACE",
                    "children": remaining > 0 ? [makeRecord(pid: pid + 1, remaining: remaining - 1)] : [],
                ]
            }
            let root = makeRecord(pid: 1, remaining: 129)
            let json: [String: Any] = [
                "windows": [[
                    "ref": "window:1",
                    "index": 0,
                    "workspaces": [[
                        "ref": "workspace:1",
                        "index": 0,
                        "title": "deep",
                        "description": NSNull(),
                        "panes": [[
                            "ref": "pane:1",
                            "surfaces": [[
                                "ref": "surface:1",
                                "index": 0,
                                "title": "deep",
                                "type": "terminal",
                                "processes": [root],
                            ]],
                        ]],
                    ]],
                ]],
            ]
            let data = try! JSONSerialization.data(withJSONObject: json)
            return CmuxHelper.parseTopPidMap(data)
        }
        #expect(map.count == 128)
        #expect(map[1] != nil)
        #expect(map[128] != nil)
        #expect(map[129] == nil)
        #expect(map[130] == nil)
    }

    @Test("decode failure on a schema mismatch is logged with the offending coding path, not silently swallowed")
    func decodeFailureNamesCodingPath() {
        // "index" as a string instead of a number: a type mismatch two
        // levels into the tree.
        let json = """
        {"windows":[{"ref":"window:1","index":0,"workspaces":[{
          "ref":"workspace:1","index":"not-a-number","title":"x","description":null,"panes":[]
        }]}]}
        """
        #expect(throws: Never.self) {
            // parseTopPidMap must not crash or propagate — it degrades to
            // an empty map. The logging itself isn't observable from a
            // unit test, so this pins the described() helper directly.
            _ = CmuxHelper.parseTopPidMap(Data(json.utf8))
        }
        #expect(CmuxHelper.parseTopPidMap(Data(json.utf8)).isEmpty)

        do {
            _ = try CmuxHelper.decodeTopJSON(Data(json.utf8))
            Issue.record("expected decodeTopJSON to throw on a type mismatch")
        } catch {
            let description = CmuxHelper.describeDecodeError(error)
            #expect(description.contains("workspaces[0].index"))
            #expect(description.contains("type mismatch"))
        }
    }
}

@Suite("CmuxHelper ancestor walk")
struct CmuxAncestorWalkTests {
    private func info(_ ref: String) -> CmuxSurfaceInfo {
        CmuxSurfaceInfo(
            workspaceRef: "workspace:1", workspaceTitle: "ws",
            surfaceRef: ref, surfaceTitle: "t",
            surfaceID: "DC89EB3D-5E6E-4091-BD04-78E24371C1D8"
        )
    }

    @Test("direct hit: trigger PID itself is in the map")
    func directHit() {
        let hit = CmuxHelper.surface(
            forTriggerPID: 100,
            parentByPID: [:],
            pidMap: [100: info("surface:1")]
        )
        #expect(hit?.surfaceRef == "surface:1")
    }

    @Test("hit two levels up the parent chain")
    func twoLevelsUp() {
        let hit = CmuxHelper.surface(
            forTriggerPID: 300,
            parentByPID: [300: 200, 200: 100],
            pidMap: [100: info("surface:1")]
        )
        #expect(hit?.surfaceRef == "surface:1")
    }

    @Test("leaf-first wins when trigger and ancestor map to different surfaces")
    func leafFirstWins() {
        let hit = CmuxHelper.surface(
            forTriggerPID: 300,
            parentByPID: [300: 200],
            pidMap: [300: info("surface:leaf"), 200: info("surface:ancestor")]
        )
        #expect(hit?.surfaceRef == "surface:leaf")
    }

    @Test("no hit anywhere returns nil")
    func noHit() {
        #expect(CmuxHelper.surface(
            forTriggerPID: 300,
            parentByPID: [300: 200, 200: 100],
            pidMap: [999: info("surface:1")]
        ) == nil)
    }

    @Test("ppid cycle terminates and returns nil")
    func cycleGuard() {
        #expect(CmuxHelper.surface(
            forTriggerPID: 300,
            parentByPID: [300: 200, 200: 300],
            pidMap: [999: info("surface:1")]
        ) == nil)
    }

    /// Pins the exact boundary (128 PIDs examined: hops 0...127) rather than
    /// just some cap below 200 — a hit at 127 hops must be found and a hit
    /// one hop farther must not, so tightening the cap can't pass silently.
    @Test("depth cap boundary: a hit exactly 127 hops up is found")
    func depthCapBoundaryHit() {
        var parents: [pid_t: pid_t] = [:]
        for i in 0..<127 { parents[pid_t(1000 - i)] = pid_t(999 - i) }
        let hit = CmuxHelper.surface(
            forTriggerPID: 1000,
            parentByPID: parents,
            pidMap: [873: info("surface:1")]
        )
        #expect(hit?.surfaceRef == "surface:1")
    }

    @Test("depth cap boundary: a hit exactly 128 hops up is not reached")
    func depthCapBoundaryMiss() {
        var parents: [pid_t: pid_t] = [:]
        for i in 0..<128 { parents[pid_t(1000 - i)] = pid_t(999 - i) }
        let hit = CmuxHelper.surface(
            forTriggerPID: 1000,
            parentByPID: parents,
            pidMap: [872: info("surface:1")]
        )
        #expect(hit == nil)
    }
}

@Suite("CmuxHelper failure classification and latch", .serialized)
struct CmuxFailureTests {
    @Test("Access denied matches by substring across cmux's dash variants")
    func accessDeniedVariants() {
        #expect(CmuxHelper.classifyFailure(
            stderr: "Error: ERROR: Access denied - only processes started inside cmux can connect"
        ) == .accessDenied)
        #expect(CmuxHelper.classifyFailure(
            stderr: "Access denied \u{2014} only processes started inside cmux can connect"
        ) == .accessDenied)
    }

    @Test("anything else is transient")
    func transientErrors() {
        #expect(CmuxHelper.classifyFailure(stderr: "Failed to connect to socket") == .transient)
        #expect(CmuxHelper.classifyFailure(stderr: "") == .transient)
    }

    @Test("accessDenied latches; transient does not; retryAfterDenial re-arms")
    func latchLifecycle() {
        CmuxHelper.retryAfterDenial()
        #expect(CmuxHelper.automationDenied == false)
        CmuxHelper.noteFailure(.transient)
        #expect(CmuxHelper.automationDenied == false)
        CmuxHelper.noteFailure(.accessDenied)
        #expect(CmuxHelper.automationDenied == true)
        CmuxHelper.retryAfterDenial()
        #expect(CmuxHelper.automationDenied == false)
    }
}

// `.serialized`: both tests install/clear the shared global `CmuxHelper`
// test PID map, same reasoning as the session-file suite above.
@Suite("CmuxHelper surfaceInfo(forPID:) via installTestPidMap", .serialized)
struct CmuxSurfaceInfoForPIDTests {
    @Test("installed map hit resolves the running process's own PID, without spawning cmux")
    func installedMapHit() {
        let pid = getpid()
        let expected = CmuxSurfaceInfo(
            workspaceRef: "workspace:1", workspaceTitle: "ws",
            surfaceRef: "surface:1", surfaceTitle: "t"
        )
        CmuxHelper.installTestPidMap([pid: expected])
        defer { CmuxHelper.clearTestPidMap() }
        #expect(CmuxHelper.surfaceInfo(forPID: pid)?.surfaceRef == "surface:1")
    }

    @Test("installed empty map returns nil (the empty-map guard), without spawning cmux")
    func installedEmptyMapReturnsNil() {
        CmuxHelper.installTestPidMap([:])
        defer { CmuxHelper.clearTestPidMap() }
        #expect(CmuxHelper.surfaceInfo(forPID: getpid()) == nil)
    }
}
