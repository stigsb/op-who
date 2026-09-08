# cmux integration: env-var identification + tiered focus (hybrid)

Third revision. v1 assumed tty → session-file identification still worked. v2
(the previous text of this spec) discovered identification was dead and
rebuilt it on the control socket — correct, but it gated the *entire* feature
on the user opting into `automation.socketControlMode = "automation"`. This
revision supersedes v2's identification design: the trigger's own environment
carries `CMUX_SURFACE_ID`, and the session file — which v2 ordered deleted —
still holds everything the popup needs, merely re-keyed. Identification now
needs **no socket**. The socket is demoted to an upgrade that buys exact-panel
focus. **The user chose this hybrid explicitly.**

## Corrected root cause

v2 said "the session file no longer carries ttys, so the session file is
dead." Half right. cmux #7750 moved panel identity from ephemeral ttyNames to
stable UUIDs; the tty **index** vanished, not the data. Every panel record
still carries `id`, `title`, `directory`, `gitBranch` (`{branch, isDirty}`),
`type` (plus `stableSurfaceId`, `terminal`). op-who's tty-keyed lookup finds
nothing — confirmed in the running app (`surfaceInfo MISS tty=ttys000
map_size=0 keys=`) — because it indexes by a field that no longer exists.
**Fix the index, keep the file: re-key by `panel.id`. Do not delete the
session-file path.**

## Measured facts (all verified live; do not re-derive)

- `CMUX_SURFACE_ID` is present in the environment of every shell-spawned
  process inside cmux (11 of 14 live processes), and where present it always
  equals that surface's UUID. Example: pid 33406 (`claude.exe`, `surface:20`)
  carries `CMUX_SURFACE_ID=EB114B2A-5372-40B3-A6A1-913D96A2FEA3`, exactly
  `surface:20`'s UUID.
- The three processes lacking it (`caffeinate`, `tail`, the `cmux` CLI
  itself) have parents that carry it — env vars are inherited, so a chain
  walk recovers them.
- It is one identifier space: `CMUX_SURFACE_ID` == session-file `panel.id`
  == socket `cmux_surface_id` == AppleScript `terminal id`. All verified
  equal.
- Session-file lookup by that UUID yields workspace `customTitle` and
  `processTitle`, panel `title`, `directory`, `gitBranch`, `type` — verified
  on live data.
- op-who already reads process environments
  (`ProcessTree.processEnvironment(pid:names:)`) and already extracts
  `CMUX_WORKSPACE_ID`/`CMUX_TAB_ID` for the trigger in
  `OnePasswordWatcher`. The plumbing exists.
- Also present: `CMUX_WORKSPACE_ID`, `CMUX_PANEL_ID`, `CMUX_BUNDLE_ID`,
  `CMUX_SOCKET_CAPABILITY`. `CMUX_TAB_ID` sometimes equals
  `CMUX_WORKSPACE_ID`. `CMUX_SURFACE_ID` is the identifier; treat the others
  as secondary/diagnostic.
- AppleScript `focus (first terminal whose id is "<uuid>")` switches the
  workspace but does not move panel focus. Needs no socket — only a TCC
  Automation grant.
- `cmux focus-panel` delivers exact panel focus but requires the socket
  (automation mode), a REF (`surface:47`) not a UUID, an explicit
  `--workspace <ref>` (its default is `$CMUX_WORKSPACE_ID`, which a GUI app
  lacks), and two calls (call 1 switches workspace only; call 2 moves the
  panel). Its `OK` output is not proof of success. Refs come only from
  `cmux top`, so exact-panel focus is inherently gated on automation mode.

## Design: hybrid

Automation mode stops being a gate and becomes an upgrade:

| Capability | Default cmux install | With automation mode |
| --- | --- | --- |
| Workspace/branch display | env var → session file | same |
| Show Tab → correct workspace | AppleScript `focus` | yes |
| Show Tab → exact panel | not available | `focus-panel` ×2 |

### Identification (primary): env var → session file

1. Read `CMUX_SURFACE_ID` from the trigger process's environment. If absent
   (or the env block is unreadable), walk **up** the already-built process
   chain (`ChainResult.chain`), reading each ancestor's environment until the
   var is found or the chain ends. The chain is already bounded (stops at the
   terminal app / launchd), so no extra cap is needed; each read is one
   sysctl via the existing `processEnvironment` API.
2. Look that UUID up in the session file, re-keyed by `panel.id`:
   `parseSessionFileGrouped` becomes a UUID-keyed parse producing workspace
   title/description (same `customTitle`/`processTitle` preference as
   today), panel title, `directory`, `gitBranch`, `type`, and the
   workspace/panel indexes that feed the ⌘N/⌃N hint. The tty key, the
   tty-recycling CWD disambiguation, and `CmuxSurfaceInfo.tty` are removed —
   UUIDs don't collide.

No socket, no spawn, no prompt: a file read plus env reads op-who already
performs.

The panel's `gitBranch` is deliberately **not** captured. The popup's git row
is sourced solely from op-who's own `GitContext` (CWD-derived); a second copy
of the same field would only create two truths that can disagree. The parser
must still tolerate the key being present — unmodeled session-file keys are
ignored, not parse failures.

**Sanity check (recommended, decided here): require the UUID to resolve in
the session file before using it.** The lookup *is* that check — if the UUID
matches no panel, treat it as no identification (no cmux row, no guidance)
rather than displaying env-derived IDs raw. This filters closed panes and
stale inherited UUIDs pointing at surfaces that no longer exist. It cannot
confirm the process is actually *in* that surface — see Known limitation.

**Identification fallback:** when the env walk finds no UUID and automation
mode is on, the retained socket path (`surfaceInfo(forPID:)`, below) may
still identify the surface via the PID map. Optional ordering, not a
requirement — env → session file is primary and must work alone.

### Action (tiered)

Show Tab's cmux branch degrades quietly through three tiers:

1. **Exact panel (automation mode on).** At click time take a fresh
   `cmux top --all --processes --json` snapshot, find the surface by the
   UUID captured at dialog time (falling back to the PID chain), take
   *both* refs from that snapshot, then run
   `cmux focus-panel --panel <surface-ref> --workspace <workspace-ref>`
   **twice** (call 1 switches workspace, call 2 moves panel focus). Never
   act on refs captured when the dialog appeared — refs are positional and
   ephemeral; UUIDs are stable. `OK` output is not success; any success
   check re-reads `active.surface_ref` from `cmux top`.
2. **Workspace-level (socket denied/unavailable, AppleScript works).**
   `focus (first terminal whose id is "<uuid>")` via the existing
   AppleScript machinery. Costs a one-time TCC Automation prompt for cmux,
   fired only when this tier actually runs.
3. **Raise only (neither).** Today's generic fallback: activate cmux.

Tier selection is a pure function of (socket latch state, cmux
availability, AppleScript authorization/outcome) so it is unit-testable;
the spawn and the AppleScript call are the imperative shell around it.

### Retained socket path (already built — do not revert)

Tasks 1–3 of the v2 plan are committed and stay: the `cmux top` JSON parser
(`parseTopPidMap`), the leaf-first PID ancestor walk (`surface(forTriggerPID:
parentByPID:pidMap:)`), and the subprocess spawn with timeout watchdog,
denial latch, and `surfaceInfo(forPID:)`. Their role changes from "the only
bridge" to "the ref supplier for tier 1" (and optional identification
fallback). The spawn/cache/latch rules in `cmux-top.md` and the current
`CmuxHelper` comments (peer-PID ancestry check, `Access denied` substring
match with both dash variants, ~1 s cache TTL, transient-vs-latched
classification, `retryAfterDenial` re-arm) all stand. One comment
correction: `surfaceInfo(forPID:)`'s doc claims the session file "is NOT a
substitute" — under this design it is the primary identification source;
reword when touched.

### Guidance (inverted)

v2's guidance read "enable cmux automation for workspace info" — a blocker
message. That is now wrong: the feature works without automation mode.
The message becomes an upgrade hint: automation mode buys *exact-panel*
focus, nothing else. Consequences:

- **Details block only, no body row.** A working feature must not carry a
  body-level call to action; the body stays reserved for the fixed row
  order (CLAUDE.md). One line in the details YAML when the trigger is cmux
  and the latch is set, e.g.
  `cmux: workspace focus only — automation mode enables exact-panel focus`.
- Never phrased or styled as an error. Never shown for non-cmux terminals
  or transient failures. Full instructions (config key, Settings path,
  `cmux reload-config`) live in README/docs, not the popup.

### Degraded ladder

| Condition | Popup | Show Tab |
| --- | --- | --- |
| UUID found, session-file hit, automation on | Full workspace/panel info | Exact panel (tier 1) |
| UUID found, session-file hit, automation off | Full info + details-line upgrade hint | Workspace via AppleScript (tier 2) |
| …and AppleScript denied/fails | Same | Raise cmux (tier 3); log |
| No UUID anywhere in chain | No cmux info (socket fallback may still hit if automation on) | Raise cmux |
| UUID found but not in session file | No cmux info (sanity check) | Raise cmux |
| cmux session file unreadable | No cmux info | Raise cmux |

The button stays visible and enabled in all cases (gated only on
`entry.tty != nil` today; keep that).

## Known limitation: inherited env attribution (accepted, not coded around)

Environment variables are inherited at fork and never revalidated. A
long-lived process whose pane has since closed or moved, or a process
launched from a shell that merely *inherited* `CMUX_*` (measured: op-who
itself, launched from such a shell, attributed to `surface:47`), carries a
stale or misleading `CMUX_SURFACE_ID`. Consequence: Show Tab can land on a
pane the trigger is not actually in. This is the same accuracy class as
cmux's own `attribution_reason: "cmux-environment"` — cmux accepts it too.
The session-file sanity check above narrows it to surfaces that still exist;
it cannot verify membership. State of the art, documented, accepted. Do not
add verification machinery for it.

## Rejected approaches (do not re-propose)

Newly rejected in this revision:

- **Socket-only identification (v2's design).** It works, but it makes a
  zero-cost capability (display + workspace focus) contingent on a setting
  most users will never flip, and its "no new dependency" argument for the
  socket action was circular once env-var identification exists. Retained
  only as the tier-1 ref supplier. Do not re-propose the socket as a
  *requirement* for identification.
- **Deleting the session-file path (v2's instruction).** Based on the false
  premise that losing the tty index killed the file. Re-key, don't delete.

Amended:

- **AppleScript `focus`** was rejected in v2 as the action because it does
  not move panel focus and "identification already requires the socket."
  The measurement stands — it is still unfit for *exact-panel* focus — but
  the premise is void, so it returns as tier 2 (workspace-level, no socket).

Standing rejections, unchanged:

- **Tty-keyed session-file lookup.** The field is gone (cmux #7750,
  deliberate; v0.64.21/22 don't restore it). Do not wait for cmux to
  restore `ttyName`.
- **Session-file `agent.sessionId` ↔ Claude Code `--session-id` argv.**
  Verified unreliable: a panel's claimed `agent.sessionId` pointed at a
  panel whose `directory` and its own `terminal.agent.workingDirectory`
  disagree (`applicant-tracker` vs `op-who`).
- **CGEvent keystroke synthesis (⌘N/⌃N).** 1–9 ceiling, keyboard-layout
  dependence, single-window restriction; superseded twice over.
- **Accessibility tab clicking.** cmux's Electron AX tree returns `Item-0`
  placeholders; untrustworthy.

## Testability

Pure and unit-tested (Swift Testing; no AppKit in builders, per the
PopupLayout convention):

- Env extraction: `CMUX_SURFACE_ID` present on trigger; absent on trigger
  but present on an ancestor; absent everywhere; unreadable env block on an
  intermediate node (walk continues).
- Session-file parse re-keyed by `panel.id`: UUID hit with full display
  fields (title preference, directory, gitBranch, indexes), UUID miss,
  non-terminal panel types, malformed JSON.
- Sanity check: env UUID not in session file → no identification.
- Tier decision: (latch, socket result, AppleScript availability) → tier,
  for every ladder row.
- Retained from v2: top-JSON decoding, PID-map building, leaf-first chain
  walk, click-time re-resolution by stable UUID in a snapshot with shifted
  refs, `Access denied` classification (both dash variants).
- Guidance/details-line builders per ladder state (hint present only in
  the latched-with-identification row).

Imperative, manually verified:

- `Process` spawn of `cmux top` / `cmux focus-panel` from the bundled app.
- Double `focus-panel` lands on the right panel, confirmed by re-reading
  `active.surface_ref` — not by `OK` output.
- AppleScript `focus` by UUID switches the workspace; TCC prompt fires once.
- Latch set under `cmuxOnly`; tier upgrades on the next dialog after
  switching to `automation` + `cmux reload-config`.

## Non-goals

- No CGEvent/keystroke synthesis.
- No new Settings UI in op-who.
- No changes to the iTerm/Terminal AppleScript paths, "Send Message", or
  dialog detection.
- No support for cmux's `password` socket mode; no launching cmux.
- No revalidation machinery for inherited env attribution (see Known
  limitation).
- No use of `CMUX_TAB_ID` as an identifier (observed equal to
  `CMUX_WORKSPACE_ID` in some panes).

## Files touched

- `Sources/OpWhoLib/CmuxHelper.swift` — session-file parse re-keyed by
  `panel.id` (`surfaceInfo(forSurfaceID:)`); tty key, CWD disambiguation,
  and `CmuxSurfaceInfo.tty` removed; socket path retained as-is; comment
  correction in `surfaceInfo(forPID:)`.
- `Sources/OpWhoLib/OnePasswordWatcher.swift` — extend the existing env
  read to `CMUX_SURFACE_ID` with the chain walk-up; replace the
  tty-keyed lookup with the UUID lookup.
- `Sources/OpWhoLib/TerminalHelper.swift` — tiered cmux `activateTab`:
  click-time snapshot + double `focus-panel`, AppleScript `focus`-by-UUID
  fallback, raise fallback.
- `Sources/OpWhoLib/OverlayPanel.swift` / `PopupLayout.swift` — details-line
  upgrade hint (no body row); button `representedObject` carries the UUID.
- `Tests/CmuxHelperTests.swift` — UUID-keyed session fixtures, env-walk and
  tier-decision tests; top-JSON tests retained.
- `docs/architecture.md`, `CLAUDE.md` — identification/action description
  and any session-file design bullet.
- `cmux-top.md` — its "treat cmux data as opt-in and off by default" design
  consequence now applies only to the socket/exact-panel tier; scope it.
