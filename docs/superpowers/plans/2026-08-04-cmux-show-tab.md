# cmux Env-First Identification + Tiered Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the cmux integration on env-first identification and a tiered focus action. cmux #7750 moved panel identity from ephemeral ttyNames to stable UUIDs — the session file's tty **index** died, not its data (confirmed live: `surfaceInfo MISS tty=ttys000 map_size=0 keys=`). Identification: read `CMUX_SURFACE_ID` from the trigger's environment, walking **up** the process chain when a node lacks it, and resolve that UUID against the session file re-keyed by `panel.id` — no socket, no spawn, no prompt. The lookup itself is the sanity check: a UUID resolving to no panel means no identification (never show raw IDs). Action: "Show Tab" degrades through three tiers — exact panel via `cmux focus-panel` ×2 over the control socket (requires `automation.socketControlMode = "automation"`), workspace-level via AppleScript `focus`-by-UUID (one-time TCC Automation grant), raise cmux. Automation mode is an **upgrade** (exact-panel focus), not a gate, and the guidance inverts accordingly. **The user chose this hybrid explicitly** (spec, third revision).

**Architecture:** Everything decision-shaped is pure and unit-tested: the UUID-keyed session-file parse (`parseSessionFileByPanelID`), the env-var chain walk (`surfaceUUID(forChain:envOf:)` with the env reader injected), the click-time tier decision (`focusTier`), ref/UUID validation, the `focus-panel` argv builder, and the details-line builder in `PopupLayout` (no AppKit, per the CLAUDE.md convention). Imperative I/O is confined to `CmuxHelper`'s `Process` spawns and `TerminalHelper`'s AppleScript call. The socket path built in Tasks 1–3 (`parseTopPidMap`, leaf-first ancestor walk, spawn/watchdog/denial latch, `surfaceInfo(forPID:)`) is **retained, not reverted**: its role changes from "the only bridge" to the click-time ref supplier for tier 1 (refs come only from `cmux top`). **Nothing spawns on the dialog path** — identification is env reads plus one file read; the socket is probed exclusively when the user clicks Show Tab, and a denial there latches and drives the upgrade hint on later dialogs. `CmuxSurfaceInfo` carries the stable surface UUID (`CMUX_SURFACE_ID` == session `panel.id` == socket `cmux_surface_id` == AppleScript `terminal id`, all verified equal); refs are positional and ephemeral, so Show Tab re-resolves them by UUID from a fresh snapshot at click time.

**Tech Stack:** Swift 5.9, AppKit, Swift Testing (`import Testing`), macOS 13+.

**Spec:** `docs/superpowers/specs/2026-08-04-cmux-show-tab.md` (authoritative; third revision — supersedes the socket-only v2 design this plan's Tasks 4–8 previously implemented on paper).

**Non-goals (spec decisions — do not re-open):** no CGEvent/keystroke synthesis; no new Settings UI in op-who; no `password` socket mode; no launching cmux; no changes to the iTerm/Terminal AppleScript paths, "Send Message", or dialog detection; no revalidation machinery for inherited-env attribution (accepted limitation — document only, Task 7); no `CMUX_TAB_ID` as an identifier (observed equal to `CMUX_WORKSPACE_ID` in some panes); no second git-truth (cmux's panel `gitBranch` is **not captured** — the popup's git row is sourced solely from op-who's own `GitContext`; the parser merely tolerates the key); no socket use on the dialog path (the socket is click-time only); do not re-propose socket-only identification, session-file deletion, or tty-keyed lookup (all rejected in the spec).

---

## Status: Tasks 1–3 are DONE — do not redo or revert

Branch `feat/cmux-show-tab`, committed and green:

- **Task 1** — `f602cd5` (+ review hardening `ec7ef24`): `parseTopPidMap`, nested-`children[]` recursion, null-`cmux_surface_id` inheritance.
- **Task 2** — `86a4023` (+ `8066755` cap-boundary pins, `68f24ba` attribution-caveat doc): `surface(forTriggerPID:parentByPID:pidMap:)`, shared `ancestryHopCap = 128`.
- **Task 3** — `a2f8db2` (+ `3f86934` hardening): `runCmuxTop()` with ~1 s watchdog, `classifyFailure`, denial latch (`automationDenied`/`noteFailure`/`retryAfterDenial`), `surfaceInfo(forPID:)`, `findCmuxExecutable()`, `CMUX_SOCKET_PATH` fallback from `last-socket-path`, test hooks.

Their sections below are kept as the record of what was built, marked `[x]`, with an "As built" note where the committed code superseded the listing and a framing correction where the text claimed the socket is the primary identification path — under the hybrid it is the **tier-1 ref supplier and optional fallback**; env → session file is primary.

---

## Verification baseline & test command

The suite is currently GREEN: **424 tests in 43 suites** (baseline at `3f86934`). Every task below must end with the full suite green (Task 4 replaces the tty-keyed session-file tests with UUID-keyed ones and later tasks add more, so the *count* changes; the bar is green, not 424). This machine is CommandLineTools-only, so **every** `swift test` invocation in this plan means exactly:

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
INTEROP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$INTEROP"
```

Referred to below as `<TEST>`; append `--filter <Suite>` where a task says so. Plain `swift build` needs no extra flags.

---

## File Structure

- **Modify** `Sources/OpWhoLib/CmuxHelper.swift` — session-file parse re-keyed by `panel.id` (`parseSessionFileByPanelID`, `surfaceInfo(forSurfaceID:)`); `CmuxSurfaceInfo` loses `tty`; env-var chain walk (`surfaceUUID(forChain:envOf:)`); tier decision + ref/UUID validation + click-time probe and `focus-panel` action spawn; tty-keyed lookup, CWD disambiguation, and the factually wrong "LaunchServices / Broken pipe" comment deleted. The Tasks 1–3 socket path stays as-is (comment correction in Task 7).
- **Modify** `Sources/OpWhoLib/OnePasswordWatcher.swift` — env-first identification (extend the existing `CMUX_*` env read with `CMUX_SURFACE_ID` + chain walk-up); **no socket use on the dialog path**; ring-buffer serialization (`tty` → `surfaceID`).
- **Modify** `Sources/OpWhoLib/PopupLayout.swift` — details-YAML upgrade-hint line (pure; **no body row**).
- **Modify** `Sources/OpWhoLib/OverlayPanel.swift` — `ProcessEntry.cmuxAutomationDenied` flag, `ShowTabRequest` button payload carrying the stable UUID.
- **Modify** `Sources/OpWhoLib/TerminalHelper.swift` — tiered cmux branch in `activateTab`: socket exact-panel, AppleScript `focus`-by-UUID fallback, shared raise fallback kept.
- **Modify** `Tests/CmuxHelperTests.swift` — tty-keyed session suites replaced with UUID-keyed fixtures; env-walk, tier-decision, ref/argv suites added; top-JSON/walk/latch suites (Tasks 1–3) retained; `looksGenericTitle`/`displayWorkspaceTitle` tests kept.
- **Modify** `Tests/PopupLayoutTests.swift`, `Tests/OverlayPanelTests.swift` — hint-line tests; `CmuxSurfaceInfo` factory updates (`tty:` removed).
- **Modify** `docs/architecture.md`, `CLAUDE.md`, `cmux-top.md`, `README.md` — hybrid identification/action description, inherited-env limitation, automation-mode instructions.

Task order: 1–3 done (socket plumbing, bottom-up) → 4: env-first identification + session re-key (TDD) → 5: inverted guidance (TDD) → 6: tiered action (TDD for the pure parts) → 7: docs + comment correction → 8: manual verification of BOTH tiers.

---

## Task 1: Top-JSON decoding + PID → surface map builder (TDD) — DONE

**Status: DONE** (`f602cd5`, hardened in `ec7ef24`). As built, beyond the listing below: `Workspace.index`/`Surface.index` are optional (missing → the 0-unknown sentinel, not an empty map); decode failures go through `decodeTopJSON`/`describeDecodeError` and are logged with the offending coding path; the recursion depth guard is the shared `ancestryHopCap` constant. **Framing correction:** this parser is no longer the primary identification path — it supplies the `surface:NN`/`workspace:NN` refs for tier-1 `focus-panel` (refs come only from `cmux top`) and the optional PID-based identification fallback.

Pure, automated-testable. Decode the subset of `cmux top --all --processes --json` op-who needs and build a `[pid_t: CmuxSurfaceInfo]` map. Two verified facts drive the shape: the process tree is **nested** (each record has a `children[]` array — a flat scan of `processes[]` misses most PIDs), and a record's `cmux_surface_id` can be null (observed live: a `caffeinate` child) — it inherits from its parent record. `cmux_surface_id` equals the session file's `panel.id` and is the stable identifier the Show Tab action later re-resolves refs by.

`CmuxSurfaceInfo` gains `surfaceID`/`workspaceID` (defaulted `nil` so existing call sites compile); the `tty` field is removed in Task 4 (UUIDs don't collide, so the tty key and its CWD disambiguation die), so the parser passes `tty: ""` temporarily. `directory` stays — the session file still supplies it.

**Files:**
- Modify: `Sources/OpWhoLib/CmuxHelper.swift`
- Test: `Tests/CmuxHelperTests.swift`

- [x] **Step 1: Write the failing tests** (new suite in `Tests/CmuxHelperTests.swift`)

The fixture is trimmed from real `cmux top --all --processes --json` output on cmux 0.64.20 (extra keys like `resources`/`pgid` dropped or kept sparsely — the decoder must tolerate unknown keys). It preserves: nesting two `children[]` levels deep, a null `cmux_surface_id` child, a duplicate PID across two surfaces, a multi-surface workspace, and a `browser`-type surface. (Fixture and test listing as committed in `Tests/CmuxHelperTests.swift`, suite `CmuxHelper top-JSON parser`: `mapsAllTerminalPIDs`, `nestedChild`, `nullIDInherits`, `displayFields` (0-based JSON index → 1-based ⌘N/⌃N), `duplicatePIDFirstWins`, `malformedInput`, plus review-added tests for missing-index tolerance, missing `processes`/`children`/`panes` keys, the depth guard, and decode-failure logging.)

- [x] **Step 2: Run tests to verify they fail** — `<TEST> --filter CmuxTopParserTests` failed with `type 'CmuxHelper' has no member 'parseTopPidMap'`.

- [x] **Step 3: Write the implementation** — `TopJSON` `Decodable` subset (`windows[] → workspaces[] → panes[] → surfaces[] → processes[]` with nested `ProcessRecord.children`), `parseTopPidMap(_:)` walking every terminal surface's process tree recursively, null `cmux_surface_id` inheriting from the parent record, first-encountered PID winning, `workspaceTabCount` counting **all** surfaces (⌃N spans panes and types).

- [x] **Step 4: Run tests to verify they pass** — full suite green.

- [x] **Step 5: Commit** — `feat: parse cmux top --processes JSON into a PID-to-surface map`.

---

## Task 2: Leaf-first ancestor walk (TDD) — DONE

**Status: DONE** (`86a4023`; cap-boundary tests pinned at exactly 127/128 hops in `8066755`; cmux's env-var attribution caveat documented in `68f24ba`).

Pure, automated-testable. The trigger PID (e.g. an `op` process cmux never saw) is usually a **deeper descendant** than anything in the map, so the lookup walks UP the trigger's parent chain leaf-first and takes the first PID present in the map. The parent relation is injected as a `[pid_t: pid_t]` so the walk is testable and owns its own safety: a visited set (kills ppid cycles) and the shared `ancestryHopCap` (mirrors cmux's own ancestry limit).

**Files:**
- Modify: `Sources/OpWhoLib/CmuxHelper.swift`
- Test: `Tests/CmuxHelperTests.swift`

- [x] **Step 1: Write the failing tests** — suite `CmuxHelper ancestor walk`: direct hit, hit two levels up, leaf-first wins over an ancestor's surface, no hit → nil, ppid-cycle termination, depth-cap boundaries.

- [x] **Step 2: Run tests to verify they fail** — `no member 'surface'`.

- [x] **Step 3: Write the implementation**

```swift
    public static func surface(
        forTriggerPID triggerPID: pid_t,
        parentByPID: [pid_t: pid_t],
        pidMap: [pid_t: CmuxSurfaceInfo]
    ) -> CmuxSurfaceInfo? {
        var current: pid_t? = triggerPID
        var visited = Set<pid_t>()
        while let pid = current, pid > 0,
              visited.count < ancestryHopCap, visited.insert(pid).inserted {
            if let hit = pidMap[pid] { return hit }
            current = parentByPID[pid]
        }
        return nil
    }
```

- [x] **Step 4: Run tests to verify they pass** — full suite green.

- [x] **Step 5: Commit** — `feat: leaf-first ancestor walk from trigger PID to cmux surface`.

---

## Task 3: Spawn, failure classification, denial latch, `surfaceInfo(forPID:)` — DONE

**Status: DONE** (`a2f8db2`, hardened in `3f86934`). As built, beyond the original listing: the spawn has a ~1 s watchdog (`TimedOutBox`; a timeout is transient by construction and never latches), pipes are drained to EOF **before** `waitUntilExit()` (real output measured 235 KB vs the 64 KB pipe buffer), the `ProcessTree` snapshot is captured before the spawn (250 ms cache TTL), the `CMUX_SOCKET_PATH` override is read from `~/.local/state/cmux/last-socket-path`, and the PID-map cache lives in dedicated `topPidMap*` statics. **Framing correction:** `surfaceInfo(forPID:)`'s doc comment claims the session file "is NOT a substitute" — under the hybrid that claim is wrong (the session file is the *primary* identification source); the comment is corrected in Task 7. The spawn/cache/latch rules themselves (peer-PID ancestry check, `Access denied` substring match across both dash variants, ~1 s cache TTL, transient-vs-latched classification) all stand unchanged; `retryAfterDenial`'s call site moves from the watcher's dialog-end to the Show Tab click (Task 6), where its doc comment is updated.

**Files:**
- Modify: `Sources/OpWhoLib/CmuxHelper.swift`
- Test: `Tests/CmuxHelperTests.swift`

- [x] **Step 1: Write the failing tests** — suites `CmuxHelper failure classification and latch` (`.serialized`; both dash variants of `Access denied`, transient classification, latch lifecycle) and `CmuxHelper surfaceInfo(forPID:) via installTestPidMap` (deterministic lookups, empty-map guard, no spawn).

- [x] **Step 2: Run tests to verify they fail** — `no member 'classifyFailure'`.

- [x] **Step 3: Write the implementation** — `CmuxTopFailure` (`.accessDenied` latches, `.transient` degrades quietly), `classifyFailure(stderr:)` substring match, `automationDenied`/`noteFailure`/`retryAfterDenial` under `cacheLock` (never call `noteFailure` while holding the lock — NSLock is not reentrant), `surfaceInfo(forPID:)` = ProcessTree snapshot + `topPidMap()` + the Task 2 walk, `findCmuxExecutable()` (bundle path first — Homebrew's entry is a symlink), `runCmuxTop()` per `cmux-top.md`, test hooks `installTestPidMap`/`clearTestPidMap`.

- [x] **Step 4: Run tests to verify they pass** — full suite green.

- [x] **Step 5: Commit** — `feat: cmux top spawn with denial latch and surfaceInfo(forPID:)`.

---

## Task 4: Env-first identification — re-key the session file by `panel.id`, walk the env chain, wire the watcher (TDD)

**This task was previously "delete the session-file path". That instruction is superseded: the session file's data is exactly what the popup needs — only its tty index is dead. Re-key it; delete only the tty-keyed lookup and the CWD-disambiguation logic that existed solely to work around tty collisions.**

Measured facts this task builds on (spec; do not re-derive): `CMUX_SURFACE_ID` is present on every shell-spawned process inside cmux and always equals that surface's UUID; the processes lacking it (`caffeinate`, `tail`, the `cmux` CLI) have parents that carry it, so a chain walk-up recovers them; session-file lookup by that UUID yields workspace `customTitle`/`processTitle`, panel `title`, `directory`, `type` (the file also carries `gitBranch`, which this plan deliberately does not model — see Non-goals); op-who already reads process environments (`ProcessTree.processEnvironment(pid:names:)`) and already extracts `CMUX_WORKSPACE_ID`/`CMUX_TAB_ID` for the trigger.

**The sanity check is the lookup itself:** a UUID that matches no terminal panel → nil → no cmux row, no hint. No extra verification machinery (spec decision; inherited-env misattribution is accepted and documented in Task 7).

**Files:**
- Modify: `Sources/OpWhoLib/CmuxHelper.swift`
- Modify: `Sources/OpWhoLib/OnePasswordWatcher.swift`
- Test: `Tests/CmuxHelperTests.swift`, `Tests/OverlayPanelTests.swift`, `Tests/PopupLayoutTests.swift`

- [ ] **Step 1: Write the failing tests**

Two new suites in `Tests/CmuxHelperTests.swift`. First, the UUID-keyed session parse (fixture shaped like the live `~/Library/Application Support/cmux/session-com.cmuxterm.app.json` post-#7750: no `ttyName`, panels carry `id`/`title`/`type`/`directory`/`gitBranch`; decoder must tolerate unknown keys like `stableSurfaceId`/`terminal`):

```swift
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
```

Second, the env-var chain walk (pure; env reader injected):

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `<TEST> --filter CmuxSessionByPanelIDTests`, `<TEST> --filter CmuxEnvWalkTests`
Expected: FAIL — `no member 'parseSessionFileByPanelID'` / `no member 'surfaceUUID'`.

- [ ] **Step 3: Implement in `CmuxHelper.swift`**

`CmuxSurfaceInfo` changes: **remove** `tty` (and its init parameter — UUIDs don't collide, so nothing keys on tty anymore); **keep** `directory` (session data; its disambiguation role is gone, it is informational now — update its doc comment). Do **not** model the panel's `gitBranch`: op-who's `GitContext` is the single git truth for the popup, and a second copy of the same field invites disagreement — the decoder simply ignores the key (JSONDecoder default). For session-derived entries `surfaceRef`/`workspaceRef` are `""` — refs are positional, snapshot-scoped, and come **only** from `cmux top`; document that on the properties.

New pure functions:

```swift
    /// Parse cmux's session file into a map keyed by the stable panel UUID
    /// (`panel.id` == `CMUX_SURFACE_ID` == socket `cmux_surface_id` ==
    /// AppleScript `terminal id`; verified equal). cmux #7750 removed the
    /// panels' ttyName — the tty INDEX died, not the data, so this re-key
    /// replaces the old tty-keyed parse. Terminal panels only. Pure.
    public static func parseSessionFileByPanelID(_ data: Data) -> [String: CmuxSurfaceInfo]
```

Iteration mirrors the old grouped parse: workspace title preference `customTitle` → `processTitle` → `currentDirectory`; `workspaceDescription` = `processTitle` when a distinct `customTitle` won; `workspaceIndex`/`tabIndex` are 1-based iteration positions (they fed the ⌘N/⌃N hint before #7750 and still do); `workspaceTabCount` counts **all** panels (⌃N spans types, matching the top parser). `SessionJSON.Panel` drops `ttyName`; `directory` is already modeled; `gitBranch` and `stableSurfaceId` stay unmodeled. Keep a `String` convenience overload for tests.

```swift
    /// Walk the trigger-first chain reading each node's CMUX_SURFACE_ID until
    /// one is found. Env vars are inherited, so a node lacking it (caffeinate,
    /// tail, the cmux CLI) is covered by an ancestor. The chain is already
    /// bounded (buildChain stops at the terminal app / launchd) — no extra
    /// cap. Pure — the env reader is injected.
    public static func surfaceUUID(
        forChain chain: [ProcessNode],
        envOf: (pid_t) -> String?
    ) -> String? {
        for node in chain {
            if let v = envOf(node.pid), !v.isEmpty { return v }
        }
        return nil
    }
```

Public lookup, replacing `surfaceInfo(forTTY:triggerCWD:)`:

```swift
    /// Env-first identification, step 2: resolve a CMUX_SURFACE_ID against
    /// the session file re-keyed by panel.id. The lookup IS the sanity
    /// check: nil means no identification (closed pane, stale inherited
    /// UUID) — callers show no cmux info rather than raw IDs. Cached ~1 s
    /// so one dialog's lookups share a file read.
    public static func surfaceInfo(forSurfaceID uuid: String) -> CmuxSurfaceInfo?
```

Implementation: re-type the existing session-file cache statics (`cacheValue` becomes `[String: CmuxSurfaceInfo]?`) and the `groupedMap()` reader (rename `sessionMapByPanelID()`); keep `readSessionFile()`/`sessionFilePath()` unchanged; re-type the test hooks `installTestMap`/`clearTestMap` to the UUID-keyed map. Log HIT/MISS with the UUID and map size (mirrors the old tty log that diagnosed the original breakage).

**Delete** (genuinely dead tty-era code only): `surfaceInfo(forTTY:triggerCWD:)`, `pathContains`, `normalizePath`, both flat `parseSessionFile` overloads, both tty-keyed `parseSessionFileGrouped` overloads, `SessionJSON.Panel.ttyName`, and the factually wrong comment block above `parseSessionFile` ("LaunchServices responsibility chain", "Broken pipe" — the real socket mechanism is the peer-PID ancestry check already documented on `surfaceInfo(forPID:)`). Keep: `looksGenericTitle`, `displayWorkspaceTitle`, `nonEmpty`, and everything from Tasks 1–3.

- [ ] **Step 4: Update construction sites and obsolete tests (mechanical)**

- `Tests/OverlayPanelTests.swift` — 8 `CmuxSurfaceInfo` factories pass `tty:`; drop the argument.
- `Tests/PopupLayoutTests.swift` — 1 factory (`DetailsYAMLTests`); drop `tty:`.
- `Tests/CmuxHelperTests.swift` — Task 1/2/3-era factories that pass `tty:`; drop it. Delete the old `CmuxHelper session-file parser` suite's tty fixtures and every test exercising `parseSessionFile*` (tty-keyed), `surfaceInfo(forTTY:)`, tty-collision/CWD disambiguation, `pathContains`, `normalizePath`, or symlink normalization. Re-home the `looksGenericTitle` and `displayWorkspaceTitle` tests into a small suite, updated to the new init.
- `OnePasswordWatcher.swift` ring-buffer serialization (`jsonDump`, ~line 618): replace `"tty": s.tty` with `"surfaceID": s.surfaceID ?? ""`.
- `CmuxHelper.parseTopPidMap` — remove the `tty: ""` placeholder argument.

- [ ] **Step 5: Wire the watcher to env-first identification**

In the cmux block of `handleWindowEvent` (~line 279), keep the `CMUX_WORKSPACE_ID`/`CMUX_TAB_ID` extraction (still feeds `detailsYAMLLines` and the ring buffer), add `CMUX_SURFACE_ID` to the same single env read, and replace the tty-gated lookup (delete the `if let tty = result.tty { … } else { … }` wrapper and its "no TTY — skipping" log line — env-first needs no tty):

```swift
            if isCmuxBundleID(result.terminalBundleID) {
                let env = measure("processEnvironment[\(triggerPID)]") {
                    ProcessTree.processEnvironment(
                        pid: triggerPID,
                        names: ["CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID"]
                    )
                }
                cmuxWorkspaceID = env["CMUX_WORKSPACE_ID"]
                cmuxTabID = env["CMUX_TAB_ID"]

                // Env-first identification: the trigger's own env, then the
                // chain walk-up (env vars are inherited; caffeinate-style
                // children lack them but their parents don't).
                let uuid = measure("cmuxSurfaceUUID[\(triggerPID)]") {
                    CmuxHelper.surfaceUUID(forChain: foldedChain) { pid in
                        pid == triggerPID
                            ? env["CMUX_SURFACE_ID"]
                            : ProcessTree.processEnvironment(
                                  pid: pid, names: ["CMUX_SURFACE_ID"])["CMUX_SURFACE_ID"]
                    }
                }
                cmuxSurface = uuid.flatMap { id in
                    measure("cmuxSurfaceInfo[uuid]") { CmuxHelper.surfaceInfo(forSurfaceID: id) }
                }

                Log.cmux.info("trigger pid=\(triggerPID, privacy: .public) CMUX_SURFACE_ID=\(uuid ?? "<none>", privacy: .public) sessionHit=\(cmuxSurface != nil, privacy: .public) CMUX_WORKSPACE_ID=\(cmuxWorkspaceID ?? "<unset>", privacy: .public)")
            }
```

**The dialog path spawns nothing.** Identification is env reads plus one cached file read — that cheapness is the point of the env-var pivot. The Tasks 1–3 socket path (`surfaceInfo(forPID:)` / `topPidMap()`) is exercised only at Show Tab click time (Task 6), where the socket is needed anyway for tier-1 refs. The spec's optional PID-map identification fallback is deliberately not wired here (spec: "optional ordering, not a requirement — env → session file is primary and must work alone"); a chain with no `CMUX_SURFACE_ID` anywhere shows no cmux info and Show Tab raises cmux.

- [ ] **Step 6: Build, grep for stragglers, run the full suite**

Run: `swift build`, then:

```bash
grep -rn "forTTY\|parseSessionFile\|parseSessionFileGrouped\|pathContains\|normalizePath\|ttyName" \
  Sources/OpWhoLib/CmuxHelper.swift Sources/OpWhoLib/OnePasswordWatcher.swift
```

Expected: the only remaining hits are `parseSessionFileByPanelID` call sites and `TerminalHelper`-bound `forTTY` uses in the watcher (tab info / entry tty — unrelated to cmux identification). Then `<TEST>` — full suite green (tty-keyed session tests deleted, UUID-keyed and env-walk suites added).

- [ ] **Step 7: Commit**

```bash
git add Sources/OpWhoLib/ Tests/
git commit -m "feat: env-first cmux identification — session file re-keyed by panel.id, CMUX_SURFACE_ID chain walk"
```

---

## Task 5: Inverted guidance — details-only upgrade hint (TDD)

**Inversion (spec):** the old plan's "enable cmux automation for workspace info" body row treated automation mode as a blocker. The feature now works without it, so the message becomes an upgrade hint: automation mode buys *exact-panel* focus, nothing else. Consequences, all load-bearing:

- **Details block only, never a body row.** The body keeps its fixed row order (action / who / location / asked — CLAUDE.md invariant); a working feature carries no body-level call to action. No `BodyRowStyle` change at all.
- Shown only in the **latched-with-identification** ladder row: trigger is cmux, `cmuxSurface` resolved, denial latch set. Never for non-cmux terminals, never for transient failures (the latch only sets on `Access denied`, which encodes that), never when identification failed (those rows show no cmux info at all).
- Never phrased or styled as an error, and it must not read as a blocker. Full instructions (config key, Settings path, `cmux reload-config`) live in README/docs (Task 7), not the popup.
- **Lifecycle: the latch is set only by a click-time probe (Task 6) — nothing probes on the dialog path.** So the hint is absent until the user has clicked Show Tab at least once and that click's probe was denied; it then appears on subsequent cmux dialogs, and clears after a click whose probe succeeds (user enabled automation). This is deliberate and better than a per-dialog probe: an upgrade hint for a capability the user has not reached for is noise, and the hint costs one flag plus one pure `if` — worth keeping at that price. It targets exactly the user who clicked, landed at workspace level, and would want to know why.

**Files:**
- Modify: `Sources/OpWhoLib/PopupLayout.swift`
- Modify: `Sources/OpWhoLib/OverlayPanel.swift`
- Modify: `Sources/OpWhoLib/OnePasswordWatcher.swift`
- Test: `Tests/PopupLayoutTests.swift`

- [ ] **Step 1: Write the failing tests**

Extend the `PopupLayoutTests` entry factory with `cmuxDenied: Bool = false` and (where needed) a `cmuxSurface:` parameter, passed through to `ProcessEntry(… cmuxAutomationDenied: cmuxDenied)`, then append:

```swift
@Suite("cmux automation upgrade hint")
struct CmuxUpgradeHintTests {
    // Factory: entry(cmuxSurface:cmuxDenied:) — cmuxSurface non-nil means
    // identification succeeded (env → session file).

    @Test("details line present only when identified AND latched")
    func hintWhenLatchedWithIdentification() {
        let e = entry(cmuxSurface: someSurface, cmuxDenied: true)
        #expect(detailsYAMLLines(entry: e).contains(
            "cmux: workspace focus only — automation mode enables exact-panel focus"))
    }

    @Test("no line when the latch is unset")
    func noHintWhenNotLatched() {
        let e = entry(cmuxSurface: someSurface, cmuxDenied: false)
        #expect(!detailsYAMLLines(entry: e).contains { $0.hasPrefix("cmux:") })
    }

    @Test("no line without identification (ladder: those rows show no cmux info)")
    func noHintWithoutIdentification() {
        let e = entry(cmuxSurface: nil, cmuxDenied: true)
        #expect(!detailsYAMLLines(entry: e).contains { $0.hasPrefix("cmux:") })
    }

    @Test("never a body row: bodyRows is unaffected by the flag")
    func noBodyRow() {
        let flagged = entry(cmuxSurface: someSurface, cmuxDenied: true)
        let plain = entry(cmuxSurface: someSurface, cmuxDenied: false)
        #expect(bodyRows(entry: flagged, dense: false) == bodyRows(entry: plain, dense: false))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `<TEST> --filter CmuxUpgradeHintTests`
Expected: FAIL — `extra argument 'cmuxAutomationDenied'`.

- [ ] **Step 3: Write the implementation**

`OverlayPanel.ProcessEntry` — add after `gitContext`, same `var`-with-default pattern (and the same rationale comment: a defaulted `let` would vanish from the memberwise init):

```swift
        /// True when the cmux control socket refused op-who this dialog
        /// (`automation.socketControlMode` not "automation"). Drives the
        /// details-block upgrade hint only — the feature works without the
        /// socket, so this is never a body row and never an error.
        var cmuxAutomationDenied: Bool = false
```

`PopupLayout.detailsYAMLLines` — at the very end:

```swift
    if entry.cmuxAutomationDenied, entry.cmuxSurface != nil {
        lines.append("cmux: workspace focus only — automation mode enables exact-panel focus")
    }
```

`OnePasswordWatcher` — in the cmux block: pass `cmuxAutomationDenied: CmuxHelper.automationDenied` into the `ProcessEntry(...)` construction (non-cmux triggers keep the `false` default). This is a **read of the persisted latch only** — no probe, no spawn; the latch was set (or cleared) by the last Show Tab click's probe (Task 6). Do **not** touch `stopDialogPolling()`: the latch must survive across dialogs to carry the hint, and re-arming happens at click time, not dialog end.

- [ ] **Step 4: Run tests to verify they pass**

Run: `<TEST> --filter CmuxUpgradeHintTests`, then `swift build && <TEST>`
Expected: PASS; full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpWhoLib/PopupLayout.swift Sources/OpWhoLib/OverlayPanel.swift Sources/OpWhoLib/OnePasswordWatcher.swift Tests/PopupLayoutTests.swift
git commit -m "feat: details-only upgrade hint when cmux automation mode is off"
```

---

## Task 6: "Show Tab" — tiered action (socket exact-panel, AppleScript workspace fallback, raise)

Show Tab's cmux branch degrades quietly through three tiers (spec):

1. **Exact panel (automation on).** At click time take a fresh `cmux top --all --processes --json` snapshot, find the surface by the **UUID captured at dialog time**, take *both* refs from that same snapshot, run `cmux focus-panel --panel <surface-ref> --workspace <workspace-ref>` **twice** (measured: call 1 switches a non-current workspace, call 2 moves panel focus; when already current, call 2 is an idempotent repeat). Never act on refs captured when the dialog appeared — refs are positional and ephemeral. `OK` output is **not** proof of success; nothing in code trusts it (verification is Task 8's `cmux top` read-back). `--workspace` is mandatory (defaults to `$CMUX_WORKSPACE_ID`, which op-who never has; omitting it fails `not_found`); `--panel` takes a ref, never the UUID.
2. **Workspace-level (socket denied/unavailable).** AppleScript `focus (first terminal whose id is "<uuid>")` — measured: switches the workspace but does not move panel focus, needs no socket, costs a one-time TCC Automation prompt for cmux, fired only when this tier actually runs.
3. **Raise only.** Today's shared fallback: activate cmux.

**Latch lifecycle lives here, not on the dialog path.** Every click calls `retryAfterDenial()` first, then probes — clicks are rare and user-initiated, so one spawn per click is fine and keeps the state fresh. A denial latches (that latch is what Task 5's hint reads on subsequent dialogs); a successful probe leaves the latch clear, so the hint disappears once the user enables automation — no restart, and never a spawn while a dialog is being handled.

Pure and TDD'd here: ref validation (`isValidSurfaceRef`/`isValidWorkspaceRef` — trust boundary before a value becomes a subprocess argument, mirroring `isValidTTYPath`), UUID validation (trust boundary before AppleScript interpolation), the argv builder, the UUID → surface snapshot lookup, and the **tier decision**. Imperative and manually verified in Task 8: the spawns and the AppleScript call.

**Files:**
- Modify: `Sources/OpWhoLib/CmuxHelper.swift`
- Modify: `Sources/OpWhoLib/TerminalHelper.swift`
- Modify: `Sources/OpWhoLib/OverlayPanel.swift`
- Test: `Tests/CmuxHelperTests.swift`

- [ ] **Step 1: Write the failing tests** (append)

```swift
@Suite("CmuxHelper focus tiers and focus-panel plumbing")
struct CmuxFocusTierTests {
    private func info(surfaceRef: String, workspaceRef: String, surfaceID: String?) -> CmuxSurfaceInfo {
        CmuxSurfaceInfo(
            workspaceRef: workspaceRef, workspaceTitle: "ws",
            surfaceRef: surfaceRef, surfaceTitle: "t", surfaceID: surfaceID
        )
    }
    private let uuid = "DC89EB3D-5E6E-4091-BD04-78E24371C1D8"

    @Test("ref validation accepts canonical refs only")
    func refValidation() {
        #expect(CmuxHelper.isValidSurfaceRef("surface:47"))
        #expect(CmuxHelper.isValidWorkspaceRef("workspace:8"))
        #expect(!CmuxHelper.isValidSurfaceRef("workspace:8"))
        #expect(!CmuxHelper.isValidSurfaceRef(uuid))
        #expect(!CmuxHelper.isValidSurfaceRef("surface:47 --workspace workspace:1"))
        #expect(!CmuxHelper.isValidSurfaceRef(""))
        #expect(!CmuxHelper.isValidWorkspaceRef("surface:47"))
    }

    @Test("UUID validation gates AppleScript interpolation")
    func uuidValidation() {
        #expect(CmuxHelper.isValidSurfaceUUID(uuid))
        #expect(!CmuxHelper.isValidSurfaceUUID("surface:47"))
        #expect(!CmuxHelper.isValidSurfaceUUID(""))
        #expect(!CmuxHelper.isValidSurfaceUUID("\(uuid)\" & quit"))
    }

    @Test("argv builder always includes --workspace, rejects invalid refs")
    func argvBuilder() {
        #expect(CmuxHelper.focusPanelArgv(surfaceRef: "surface:48", workspaceRef: "workspace:8")
            == ["focus-panel", "--panel", "surface:48", "--workspace", "workspace:8"])
        #expect(CmuxHelper.focusPanelArgv(surfaceRef: uuid, workspaceRef: "workspace:8") == nil)
        #expect(CmuxHelper.focusPanelArgv(surfaceRef: "surface:48", workspaceRef: "") == nil)
    }

    @Test("UUID lookup finds the surface (and its refs) in a snapshot")
    func surfaceByUUID() {
        let map: [pid_t: CmuxSurfaceInfo] = [
            100: info(surfaceRef: "surface:19", workspaceRef: "workspace:8", surfaceID: uuid),
            200: info(surfaceRef: "surface:20", workspaceRef: "workspace:8",
                      surfaceID: "3F3253D1-0000-4000-8000-000000000002"),
        ]
        #expect(CmuxHelper.surface(forSurfaceID: uuid, in: map)?.surfaceRef == "surface:19")
        #expect(CmuxHelper.surface(forSurfaceID: "missing", in: map) == nil)
        #expect(CmuxHelper.surface(forSurfaceID: uuid, in: [:]) == nil)
    }

    // Tier decision — one case per ladder row. A socket denial needs no
    // parameter of its own: the click re-arms and probes, and a denied (or
    // failed, or timed-out) probe IS a nil snapshot.
    @Test("snapshot hit: exact panel with refs from THAT snapshot")
    func tierExact() {
        let snap: [pid_t: CmuxSurfaceInfo] =
            [100: info(surfaceRef: "surface:19", workspaceRef: "workspace:8", surfaceID: uuid)]
        #expect(CmuxHelper.focusTier(surfaceUUID: uuid, snapshot: snap)
            == .exactPanel(surfaceRef: "surface:19", workspaceRef: "workspace:8"))
    }

    @Test("no snapshot (probe denied/failed) or UUID not in it: workspace tier")
    func tierNoSnapshot() {
        #expect(CmuxHelper.focusTier(surfaceUUID: uuid, snapshot: nil)
            == .workspaceOnly(surfaceUUID: uuid))
        #expect(CmuxHelper.focusTier(surfaceUUID: uuid, snapshot: [:])
            == .workspaceOnly(surfaceUUID: uuid))
    }

    @Test("no UUID or invalid UUID: raise only")
    func tierRaise() {
        #expect(CmuxHelper.focusTier(surfaceUUID: nil, snapshot: nil) == .raiseOnly)
        #expect(CmuxHelper.focusTier(surfaceUUID: "junk", snapshot: nil) == .raiseOnly)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `<TEST> --filter CmuxFocusTierTests`
Expected: FAIL — `no member 'isValidSurfaceRef'` / `no member 'focusTier'`.

- [ ] **Step 3: Implement the pure parts** (add to `CmuxHelper`)

```swift
    // MARK: - Show Tab action: tier decision + focus-panel plumbing

    /// Trust boundary before a ref becomes a subprocess argument — mirrors
    /// isValidTTYPath. `Process` args are not shell-parsed; this is defense
    /// in depth against a corrupted top snapshot.
    public static func isValidSurfaceRef(_ ref: String) -> Bool {
        ref.range(of: #"^surface:\d+$"#, options: .regularExpression) != nil
    }

    public static func isValidWorkspaceRef(_ ref: String) -> Bool {
        ref.range(of: #"^workspace:\d+$"#, options: .regularExpression) != nil
    }

    /// Trust boundary before a UUID is interpolated into AppleScript source.
    public static func isValidSurfaceUUID(_ s: String) -> Bool {
        s.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                options: .regularExpression) != nil
    }

    /// Argv for one focus-panel call. `--workspace` is mandatory: it
    /// defaults to $CMUX_WORKSPACE_ID, which op-who never has — omitting it
    /// fails with `not_found`. `--panel` takes a ref, never the UUID.
    /// nil when either ref is invalid.
    public static func focusPanelArgv(surfaceRef: String, workspaceRef: String) -> [String]? {
        guard isValidSurfaceRef(surfaceRef), isValidWorkspaceRef(workspaceRef) else { return nil }
        return ["focus-panel", "--panel", surfaceRef, "--workspace", workspaceRef]
    }

    /// First snapshot entry carrying the given stable surface UUID. Entries
    /// sharing a UUID come from the same snapshot and carry identical refs,
    /// so `first` is deterministic in effect. Pure.
    public static func surface(
        forSurfaceID id: String, in pidMap: [pid_t: CmuxSurfaceInfo]
    ) -> CmuxSurfaceInfo? {
        pidMap.values.first { $0.surfaceID == id }
    }

    /// Show Tab's degraded ladder, decided purely so every row is testable.
    /// `snapshot` is the click-time pid map — nil when the probe was denied,
    /// failed, or timed out, which is why no separate latch parameter
    /// exists. Refs in `.exactPanel` come from that snapshot and nowhere
    /// else — refs are positional and ephemeral.
    public enum CmuxFocusTier: Equatable {
        case exactPanel(surfaceRef: String, workspaceRef: String)
        case workspaceOnly(surfaceUUID: String)
        case raiseOnly
    }

    public static func focusTier(
        surfaceUUID: String?,
        snapshot: [pid_t: CmuxSurfaceInfo]?
    ) -> CmuxFocusTier {
        guard let uuid = surfaceUUID, isValidSurfaceUUID(uuid) else { return .raiseOnly }
        if let snap = snapshot,
           let hit = surface(forSurfaceID: uuid, in: snap),
           isValidSurfaceRef(hit.surfaceRef), isValidWorkspaceRef(hit.workspaceRef) {
            return .exactPanel(surfaceRef: hit.surfaceRef, workspaceRef: hit.workspaceRef)
        }
        return .workspaceOnly(surfaceUUID: uuid)
    }
```

- [ ] **Step 4: Implement the imperative tier-1 action** (add to `CmuxHelper`)

```swift
    /// Tier 1: exact-panel focus over the socket. This is the ONLY place the
    /// socket is probed — never the dialog path. Re-arms the denial latch
    /// first (`retryAfterDenial`), then takes a FRESH snapshot (refs from
    /// dialog time are never used), re-resolves refs by the stable UUID, and
    /// runs focus-panel TWICE — call 1 switches a non-current workspace,
    /// call 2 moves panel focus; when already current, call 2 is an
    /// idempotent repeat. `OK` output is not a success signal — never add
    /// logic that trusts it. A denied probe re-latches (the latch persists
    /// across dialogs and drives the details upgrade hint); a successful one
    /// leaves the latch clear. Returns false when the snapshot fails, the
    /// UUID doesn't resolve, or a call exits non-zero; the caller then tries
    /// the AppleScript workspace tier.
    public static func focusSurfaceExact(withID surfaceID: String) -> Bool {
        retryAfterDenial()  // one fresh probe per click; a denial re-latches below
        let snapshot = topPidMap()
        guard case let .exactPanel(surfaceRef, workspaceRef) =
                focusTier(surfaceUUID: surfaceID, snapshot: snapshot),
              let argv = focusPanelArgv(surfaceRef: surfaceRef, workspaceRef: workspaceRef)
        else { return false }
        return runCmux(argv) && runCmux(argv)
    }
```

Also update `retryAfterDenial()`'s doc comment (Tasks 1–3 code): its "called by the watcher when a dialog ends" contract is superseded — it is now called at the top of each Show Tab click so every click performs one fresh probe. No behavior change to the latch itself.

```swift
    /// Run one `cmux` CLI command; true on exit 0. Non-zero exits are
    /// classified like `cmux top` failures so an `Access denied` latches.
    private static func runCmux(_ args: [String]) -> Bool {
        guard let exe = findCmuxExecutable() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        if let socketPath = lastSocketPathOverride() {
            var env = ProcessInfo.processInfo.environment
            env["CMUX_SOCKET_PATH"] = socketPath
            proc.environment = env
        }
        let stderr = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = stderr
        do { try proc.run() } catch {
            Log.cmux.error("cmux \(args.first ?? "", privacy: .public) spawn failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            noteFailure(classifyFailure(stderr: msg))
            Log.cmux.error("cmux \(args.joined(separator: " "), privacy: .public) exit=\(proc.terminationStatus, privacy: .public) stderr=\(msg, privacy: .public)")
            return false
        }
        return true
    }
```

- [ ] **Step 5: Add the tiered cmux branch to `TerminalHelper.activateTab`**

Extend the signature with a defaulted parameter (existing callers/tests compile unchanged):

```swift
    public static func activateTab(
        forTTY tty: String,
        terminalBundleID: String? = nil,
        cmuxSurfaceID: String? = nil
    )
```

Add a case to the existing `switch bid` (before `default`):

```swift
        case _ where isCmuxBundleID(bid):
            // Tiered navigation INSIDE cmux. `ok` deliberately stays false so
            // the shared fallback below always activates the app — neither
            // focus-panel nor AppleScript `focus` reliably raises it, and the
            // bare raise is tier 3 on its own.
            if let sid = cmuxSurfaceID {
                if !CmuxHelper.focusSurfaceExact(withID: sid) {
                    // Tier 2: workspace-level, no socket. Fires the one-time
                    // TCC Automation prompt for cmux only when actually run.
                    _ = focusCmuxWorkspace(surfaceUUID: sid, bundleID: bid)
                }
            }
```

And the private AppleScript tier (UUID validated before interpolation; `bid` comes from the closed `isCmuxBundleID` set, safe to interpolate):

```swift
    /// Tier 2: AppleScript `focus` by stable terminal id. Measured: switches
    /// the workspace but does NOT move panel focus — workspace-level is the
    /// ceiling of this tier, which is why automation mode is worth a hint.
    private static func focusCmuxWorkspace(surfaceUUID: String, bundleID: String) -> Bool {
        guard CmuxHelper.isValidSurfaceUUID(surfaceUUID) else { return false }
        return runAppleScript("""
            tell application id "\(bundleID)"
                focus (first terminal whose id is "\(surfaceUUID)")
            end tell
            """)
    }
```

The button stays visible and enabled in all cases, gated only on `entry.tty != nil`, as today.

- [ ] **Step 6: Carry the payload through the `OverlayPanel` button**

Replace the `[tty, bundleID]` array payload with a typed struct (nested in `OverlayPanel`):

```swift
    /// Everything the "Show Tab" click handler needs at activation time.
    /// Carries the STABLE surface UUID, never refs — refs captured at
    /// trigger time could be stale by click time.
    private struct ShowTabRequest {
        let tty: String
        let terminalBundleID: String?
        let cmuxSurfaceID: String?
    }
```

In `buildEntryView` (~line 380):

```swift
            showBtn.cell?.representedObject = ShowTabRequest(
                tty: tty,
                terminalBundleID: entry.terminalBundleID,
                cmuxSurfaceID: entry.cmuxSurface?.surfaceID
            )
```

And `showTerminalTab(_:)` (~line 696):

```swift
    @objc private func showTerminalTab(_ sender: NSButton) {
        guard let req = sender.cell?.representedObject as? ShowTabRequest else { return }
        TerminalHelper.activateTab(
            forTTY: req.tty,
            terminalBundleID: req.terminalBundleID,
            cmuxSurfaceID: req.cmuxSurfaceID
        )
    }
```

- [ ] **Step 7: Run tests + build**

Run: `<TEST> --filter CmuxFocusTierTests`, then `swift build && <TEST>`
Expected: PASS; builds clean; full suite green (iTerm/Terminal `activateTab` paths untouched).

- [ ] **Step 8: Commit**

```bash
git add Sources/OpWhoLib/CmuxHelper.swift Sources/OpWhoLib/TerminalHelper.swift Sources/OpWhoLib/OverlayPanel.swift Tests/CmuxHelperTests.swift
git commit -m "feat: tiered Show Tab — socket exact-panel focus with AppleScript workspace fallback"
```

---

## Task 7: Documentation + comment correction

Short and precise per CLAUDE.md's doc rules — no debugging diary, no emoji.

**Files:**
- Modify: `Sources/OpWhoLib/CmuxHelper.swift` (one doc comment)
- Modify: `docs/architecture.md`
- Modify: `CLAUDE.md`
- Modify: `cmux-top.md`
- Modify: `README.md`

- [ ] **Step 1: Correct the `surfaceInfo(forPID:)` doc comment**

Its first paragraph claims the socket is "the only remaining bridge" and that "the session file is NOT a substitute" — both now wrong. Reword: the session file (re-keyed by `panel.id`, resolved via `CMUX_SURFACE_ID`) is the **primary** identification source; this PID-map lookup is the identification fallback and the ref supplier for tier-1 `focus-panel`. Keep the second paragraph (peer-PID auth mechanism, latch behavior, cache) unchanged — it is correct.

- [ ] **Step 2: `docs/architecture.md`**

- §2 component blurb and §4.10 `CmuxHelper`: env-first pipeline — `CMUX_SURFACE_ID` from the trigger's env, chain walk-up for nodes that lack it, resolved against the session file re-keyed by `panel.id` (the UUID equals session `panel.id` == socket `cmux_surface_id` == AppleScript `terminal id`); the lookup is the sanity check (miss → no identification). Socket path retained as the click-time tier-1 ref supplier — nothing spawns on the dialog path; `Access denied` latches at click time and drives the details upgrade hint on later dialogs.
- §4.12 `TerminalHelper` table: cmux "Tab activation" cell = tiered — socket `focus-panel` ×2 with refs re-resolved by stable UUID from a fresh snapshot (automation mode), AppleScript `focus`-by-UUID (workspace-level only, one-time TCC Automation prompt), app raise. Note the ref and UUID validation as trust boundaries alongside the TTY-path validation.
- §3 assembly bullet: cmux workspace/surface info now keys on the trigger's env-derived surface UUID, not the tty.
- §6 Key Design Decisions: one entry for the hybrid — identification is env-first because it needs no socket and no opt-in (cmux #7750 killed the tty index, not the session data); action is tiered because `focus-panel` (exact panel) requires automation mode while AppleScript `focus` (workspace-level, measured ceiling) does not; automation mode is an upgrade, never a gate. Record the `focus-panel` rules: explicit `--workspace` required, two calls, refs from a fresh snapshot only, `OK` is not a success signal.
- **Known limitation (new short subsection or §6 bullet): inherited-env attribution.** Env vars are inherited at fork and never revalidated; a process that merely inherited `CMUX_SURFACE_ID` (measured: op-who itself, attributed to `surface:47`) or whose pane has since closed carries a stale/misleading UUID, so Show Tab can land on a pane the trigger is not in. Same accuracy class as cmux's own `attribution_reason: "cmux-environment"`. The session-file lookup filters UUIDs whose surface no longer exists; it cannot verify membership. Accepted — no verification machinery.

- [ ] **Step 3: `CLAUDE.md`** — replace nothing, add one bullet under "Key design decisions":

```markdown
- cmux identification is env-first and needs no socket: read `CMUX_SURFACE_ID` from the trigger's environment (walking up the chain when a node lacks it — env vars are inherited) and resolve it against the session file re-keyed by `panel.id`. cmux #7750 killed the file's tty index, not its data — never reintroduce tty-keyed lookup, and a UUID that resolves to no panel means no identification (never surface raw IDs). "Show Tab" tiers: socket `cmux focus-panel --panel <surface-ref> --workspace <workspace-ref>` run twice with both refs re-resolved by the stable UUID from a fresh snapshot at click time (`--workspace` mandatory, refs not UUIDs, `OK` output is not proof of success); else AppleScript `focus`-by-UUID (workspace-level only — measured ceiling); else raise cmux. Automation mode is an upgrade, not a gate: the hint is one details-YAML line, never a body row, never error-styled. The socket is probed only at Show Tab click time — never on the dialog path; `Access denied` latches there and the latch drives the hint on later dialogs.
```

- [ ] **Step 4: `cmux-top.md`**

- **Scope the design consequence**: "treat cmux data as opt-in and off by default" now applies only to the socket/exact-panel tier — identification and workspace display work on every default install (env var + session file). Rewrite that paragraph accordingly.
- Update the invocation to `top --all --processes --json` throughout and extend "Output shape": surfaces sit under `windows[] → workspaces[] → panes[] → surfaces[]`; `surface.tty` is null and `tty_process_pids` empty (do not rely on them); `--processes` adds `surface.processes[]` — **nested** records (`children[]`) carrying `pid`, `ppid`, `name`, `path`, `cmux_surface_id`, `cmux_workspace_id`, where `cmux_surface_id` equals the session file's `panel.id` (stable) and can be null on leaf children (inherit from the parent record).
- Add a short `focus-panel` section with the measured rules: `--workspace` mandatory (defaults to `$CMUX_WORKSPACE_ID`), `--panel` takes a ref not a UUID (`not_found` otherwise), two calls needed for cross-workspace focus, `OK` printed even on no-op calls — verify via a `cmux top` read-back, not exit output.
- In the env-vars section, note the inherited-env attribution caveat (one sentence, pointing at architecture.md for the consequence).

- [ ] **Step 5: `README.md`** — short cmux subsection: works out of the box (workspace/branch display and workspace-level Show Tab; the AppleScript tier asks for an Automation permission once). Optional exact-panel focus: set `automation.socketControlMode = "automation"` in `~/.config/cmux/cmux.json` (or cmux Settings → Automation), then `cmux reload-config`. This is where the popup hint's full instructions live.

- [ ] **Step 6: Full suite (comment + docs only)**

Run: `<TEST>`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpWhoLib/CmuxHelper.swift docs/architecture.md CLAUDE.md cmux-top.md README.md
git commit -m "docs: env-first cmux identification, tiered Show Tab, inherited-env caveat"
```

---

## Task 8: Final verification — full suite + manual pass over BOTH tiers

**Manual — needs the user at the machine with cmux and 1Password running.** The spawns, the AppleScript call, the TCC prompt, and the two-call focus behavior are live-system behavior (spec's testability split). `focus-panel`'s `OK` output is not evidence — every exact-panel assertion below is verified by re-reading `cmux top` (`active.surface_ref`), never by trusting `OK`.

- [ ] **Step 1: Full suite**

Run: `<TEST>`
Expected: all suites PASS (baseline 424 minus the deleted tty-keyed session tests, plus the UUID-session/env-walk/hint/tier suites).

- [ ] **Step 2: Build and launch the signed bundle**

```bash
scripts/bundle.sh
open .build/op-who.app
```

Always the bundle, never the raw binary (TCC identifier stability — see CLAUDE.md). If Accessibility re-prompts, grant it once.

- [ ] **Step 3: Tier 2 path — automation OFF (default install; this is the headline feature)**

With `automation.socketControlMode` at its default `cmuxOnly` (or set it back + `cmux reload-config`):

1. Trigger a 1Password approval (`op item get <item>` or an SSH command via the 1Password agent) from a cmux pane in a **named workspace**.
2. **Identification without the socket:** the popup's terminal row shows the workspace title and the " ⌘N ⌃M" hint — sourced from the env var + session file, no spawn. If ⌘N/⌃M don't match the workspace's actual shortcuts (session-file iteration order vs on-screen order), drop the mismatching component rather than guessing, and note it.
3. **No upgrade hint yet:** expanding details shows **no** `cmux:` line — the latch is unset because nothing has probed (the hint only appears after a click's probe has been denied).
4. **Show Tab, tier 2:** click while a *different* workspace is frontmost. The click probes the socket (denied → latches), then falls to AppleScript. First ever click fires the one-time TCC Automation prompt for cmux — grant it, and confirm the prompt does not leave the popup in a bad state (popup still dismissable, app responsive; re-click if the first click was consumed by the prompt). Then confirm cmux comes frontmost with the **right workspace** selected. Panel focus not moving is *expected* at this tier.
5. **Upgrade hint after a denied click:** trigger a second dialog. Details now show exactly `cmux: workspace focus only — automation mode enables exact-panel focus` — one line, not styled as an error, no body row.
6. **AppleScript denied:** in System Settings → Privacy & Security → Automation, revoke op-who → cmux, click again: cmux is still raised (tier 3), no error dialog, popup healthy. Re-grant afterward.
7. **Probe discipline:** via `log stream --predicate 'subsystem == "com.stigbakken.op-who"'`, confirm **no** `cmux top` spawn at dialog time (any number of dialogs) and exactly one probe per Show Tab click.

- [ ] **Step 4: Tier 1 path — automation ON**

Set `{"automation": {"socketControlMode": "automation"}}` + `cmux reload-config`:

1. **Exact panel, cross-workspace, MULTI-surface:** the target workspace must have **2+ surfaces**, and the trigger pane must not be the workspace's selected surface — a single-surface workspace cannot detect a panel-focus failure (the workspace switch alone looks like success; exactly how the AppleScript ceiling hid). Trigger a dialog, switch cmux to a different workspace and focus a different panel there, then click Show Tab. Verify with a read-back:
   ```bash
   cmux top --all --json | python3 -c "import json,sys; print(json.load(sys.stdin)['active']['surface_ref'])"
   ```
   Expected: the trigger pane's `surface:` ref. No TCC prompt (tier 1 is socket-only).
2. **Hint clears via the successful click:** after that click (probe succeeded, latch cleared), trigger a new dialog — the details `cmux:` line is gone, workspace info unchanged, no op-who restart.
3. **Workspace already current:** stay in the trigger's workspace but focus a *different* surface of it; click Show Tab; same read-back. This is the call-1-suffices case — the idempotent second call must not disturb the result.
4. **Claude Code trigger:** trigger from inside a Claude Code session in a cmux pane (deep descendant — exercises the env chain walk on live data, since `op` itself may carry the var but children like `caffeinate` don't). Identification resolves; Show Tab lands exactly.

- [ ] **Step 5: Ladder edge rows**

1. **Stale UUID:** close the trigger pane after the popup is up (keep the trigger alive if possible, e.g. a long-running ssh) or use a shell whose pane was closed — the UUID resolves to no panel: popup shows no cmux row (sanity check), Show Tab raises cmux only.
2. **cmux gone at click time:** quit cmux after a popup is up, then click Show Tab — the probe fails transiently (**no latch**, so no hint on later dialogs), the AppleScript tier fails quietly, the raise no-ops; popup healthy, nothing in the log beyond the expected classification.

- [ ] **Step 6: Regression spot-check**

Trigger from iTerm2 or Terminal.app: Show Tab still selects the exact tab (their AppleScript paths are untouched), tab titles still render, no cmux lines in their details.

- [ ] **Step 7: Commit any fixes surfaced by the manual pass; final state is a green suite + verified manual checklist for both tiers.**

---

## Self-Review Notes

- **Spec coverage:** env-first identification (env walk + session re-key + sanity-check-is-the-lookup) → Task 4; retained socket path as the click-time tier-1 ref supplier → Tasks 1–3 (done) framing-corrected here, wired in Task 6; inverted guidance (details-only upgrade hint, fixed body order preserved) → Task 5; tiered action with all measured `focus-panel` rules (fresh snapshot, both refs from it, explicit `--workspace`, ×2, `OK` untrusted) and the AppleScript workspace tier → Task 6; degraded ladder → Tasks 4–6 + Task 8 Steps 3–5; docs incl. inherited-env limitation and the `surfaceInfo(forPID:)` comment correction → Task 7; both-tier manual verification → Task 8. Testability split per spec: env walk, UUID session parse, sanity check, tier decision, ref/argv/UUID validation are pure and TDD'd; spawns and AppleScript are imperative and manually verified.
- **Deliberate deviations (decided with the coordinator — do not silently revert):**
  1. **No socket probe on the dialog path — probing is click-time only** (Tasks 4–6). Env identification exists precisely to keep the dialog path spawn-free; the click needs the socket anyway for tier-1 refs, so the probe lives there: each click re-arms (`retryAfterDenial` moves from dialog-end to click-start), a denial latches, a success clears. Consequences accepted: the upgrade hint appears only *after* a click's probe was denied (an upgrade hint for a capability never reached for is noise — the hint survives because it now costs one flag plus one pure `if` and targets exactly the user who clicked and landed at workspace level), and the spec's *optional* dialog-time PID-map identification fallback is dropped (spec marks it "not a requirement — env → session file … must work alone").
  2. **Decode-failure details line dropped.** With the socket no longer on the identification path, a top-JSON decode failure only affects the upgrade tier; the committed coding-path logging (`describeDecodeError`, Task 1 as-built) remains log-only. Proportionate; confirmed by the coordinator.
  3. **`gitBranch` not captured**, deviating from the spec's "captured on `CmuxSurfaceInfo`" sentence: it has no consumer (the git row is `GitContext`-sourced by spec), and a second source of truth for the same field invites disagreement. The session parser tolerates the key without modeling it.
- **Under-specified points resolved here — flag on review if wrong:**
  1. **`directory` kept** (spec lists it among the yielded session fields) though its tty-disambiguation role is deleted; now informational only.
  2. **Hint requires `cmuxSurface != nil`** — the ladder shows the hint only in the "UUID found, session-file hit, automation off" row; latched-but-unidentified rows show no cmux info at all.
  3. **Tier-2 also runs when tier 1 *fails* mid-flight** (spawn ok but `focus-panel` exits non-zero), not only when the snapshot is missing — `focusSurfaceExact` returns false and `activateTab` falls through. The spec's ladder only names "socket denied/unavailable"; treating a failed call the same way errs toward the user still landing in the right workspace.
  4. **AppleScript tell target** is `application id "<terminalBundleID>"` with the entry's bundle id (closed `isCmuxBundleID` set — `io.cmux`, `com.cmux.cmux`, `com.cmuxterm.app`); the spec verified the `focus (first terminal whose id is …)` command works but did not record the tell target. Task 8 Step 3 verifies live; if `application id` misresolves, fall back to `tell application "cmux"`.
  5. **Session-derived `surfaceRef`/`workspaceRef` are empty strings** — refs exist only in top snapshots; ref validation makes an accidental use of an empty ref fail closed.
  6. **⌘N/⌃M from session-file iteration order** (as pre-#7750). If Task 8 Step 3.2 shows a mismatch with on-screen order, drop the mismatching hint component (spec's drop-the-hint fallback) rather than guessing.
- **Type consistency:** `CmuxSurfaceInfo` (− `tty`; `surfaceID`/`workspaceID`/`directory` retained; `gitBranch` deliberately not modeled), `parseSessionFileByPanelID(_:) -> [String: CmuxSurfaceInfo]`, `surfaceUUID(forChain:envOf:)`, `surfaceInfo(forSurfaceID:)`, `surfaceInfo(forPID:)` (unchanged), `CmuxFocusTier` / `focusTier(surfaceUUID:snapshot:)`, `isValidSurfaceRef`/`isValidWorkspaceRef`/`isValidSurfaceUUID`, `focusPanelArgv(surfaceRef:workspaceRef:)`, `surface(forSurfaceID:in:)`, `focusSurfaceExact(withID:)`, `ProcessEntry.cmuxAutomationDenied`, `TerminalHelper.activateTab(forTTY:terminalBundleID:cmuxSurfaceID:)`, `TerminalHelper.focusCmuxWorkspace(surfaceUUID:bundleID:)`, `OverlayPanel.ShowTabRequest` — used identically across tasks.
- **Environment facts this plan relies on (spec, all verified live — do not re-derive):** `CMUX_SURFACE_ID` present on every shell-spawned process and equal to the surface UUID where present; the identifier space is one (`CMUX_SURFACE_ID` == `panel.id` == `cmux_surface_id` == AppleScript `terminal id`); AppleScript `focus` switches the workspace but not panel focus; `focus-panel` needs refs, explicit `--workspace`, and two calls, and prints `OK` on no-op calls; `Access denied` appears with both dash variants; `cmux reload-config` applies without restarting cmux; the running app confirmed the tty index dead (`surfaceInfo MISS tty=ttys000 map_size=0 keys=`); op-who itself measured as inherited-env-attributed to `surface:47` (the accepted limitation).
