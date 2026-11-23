# op-who

macOS menu bar utility that identifies which process triggered a 1Password approval dialog (CLI or SSH agent).

Where things live: [docs/architecture.md](docs/architecture.md) for components, data flow, and the full design-decision list with rationale; [CONTRIBUTORS.md](CONTRIBUTORS.md) for build, test, and release instructions.

**This file holds invariants, not descriptions.** If a sentence describes what the code currently does rather than what a change must not break, it belongs in `docs/architecture.md`.

## Key design decisions

Full list with rationale: [docs/architecture.md §6](docs/architecture.md#6-key-design-decisions). Below are the ones most easily broken by a careless edit.

- Chain stops at any process registered as a macOS app (has bundle ID in NSWorkspace). The app is recorded (`ChainResult.appBundleID/appPID`, outermost bundle when nested) but never added to the chain. 1Password overlays do not show it, since 1Password already shows the app name; OIDC overlays do.
- Trigger processes with no parent chain and no TTY are filtered out (1Password's own internal `op` helper)
- Dialog detection uses window title filtering (not content scanning) because 1Password's Electron web view loads asynchronously
- SSH agent dialogs detected by finding ssh/git/scp/sftp/rsync processes alongside 1Password's internal `op` helper
- Dismissal fires when *either* signal trips, not both: the AX window reporting gone for 3 consecutive 500 ms polls (~1.5 s, debounced to ride out Electron re-renders), **or** every tracked trigger PID having exited
- CWD walks the process chain to find the first non-`/` directory (trigger processes often have CWD `/`)
- Claude Code is detected in two passes: a direct `claude` process-name match (Homebrew/Bun build), then a scan of `node` process args for "claude" or "@anthropic" (npm build)
- `LSUIElement=true` in Info.plist makes this a menu bar app (no dock icon)
- The popup's command subtitle for a shell `-c` wrapper comes from the **real process the shell invoked**, not from parsing the `-c` string — Claude Code's Bash-tool wrapper makes that string unparseable (`ProcessTree.resolveScriptInfo`). It deliberately shows nothing when the invoked process *is* the trigger, since the title already names it. CWD comes from the ordinary `bestCWD` chain walk; don't add `cd`-parsing.
- Secrets are redacted **at capture** (`SecretRedaction.swift`), never per-sink, so no downstream consumer (popup, unified log, rule matching) can hold a raw one. Two invariants when editing: `redactArgv` preserves argv token count and order (position-based parsers depend on it), and `argv[0]` is exempt from the `maxArgvArgLength` truncation because its basename drives command detection.
- Popup body rows have a **fixed order** (action / who / git-root·branch·worktree or cwd / asked) so branch and worktree land in predictable places. The `PopupLayout.swift` builders (`bodyRows`/`processTreeNodes`/`detailsYAMLLines`) are pure — keep AppKit out of them, that is what makes them testable. Git context is gathered once per trigger (`GitContext.swift`).
- Popup fonts and colors are user-overridable (`PopupStyle.swift`), but `OverlayColors.swift` stays the single home of the WCAG-audited defaults and the contrast test. Two invariants: overrides are **per appearance** (`role.light`/`role.dark`), and `color(role)` must return a *dynamic* `NSColor` so a variant left unset still resolves to the default's matching component at draw time. The Appearance pane's contrast badges (`ContrastSnap.swift`) are guidance — never enforced.
- OIDC login notifications are unauthenticated. `OidcLoginWatcher` takes only the PID (and a frame used for placement) from them, requires that PID's `proc_pidpath` basename to be `kubectl-oidc_login` or `kubelogin` (never argv[0], the `KERN_PROCARGS2` path or the kinfo name), and derives all displayed text from the live process tree. Never display text taken from the notification.
- OIDC-only behavior is gated on `RequestSource.oidcLogin` or an opt-in parameter (`placement:`, `appName:`): 1Password overlays keep their text, rows and placement. `OidcLogin.rules` is fixed; the Rules pane must not offer `RequestKind.oidcLogin`, and OIDC requests are not recorded in the ring buffer.
- Each watcher owns one `OverlayPanel` and reuses it: at most one 1Password panel and one OIDC panel at a time.

## Build & TCC permissions

TCC keys Accessibility (and Automation) grants on the code signature's identifier, so `scripts/bundle.sh` re-signs the assembled `.app` after copying `Info.plist` into place — preferring the `op-who Local Dev` cert, falling back to ad-hoc. Without a re-sign the identifier is the per-build hash `swift build` assigns (`op-who-<sha1>`), which changes every rebuild.

If you change `bundle.sh` or the release-signing flow, preserve this property: the assembled bundle must end up signed with its `CFBundleIdentifier` (`com.stigbakken.op-who` for release, `com.stigbakken.op-who.dev` for debug) as the signing identifier, and `Info.plist`, including the debug identity edits, must be in place *before* signing — otherwise `codesign -dvv` reports `Info.plist=not bound` and TCC re-prompts on every rebuild. Local cert setup: [CONTRIBUTORS.md](CONTRIBUTORS.md#keeping-the-accessibility-grant-across-rebuilds).

## Testing

`swift test` — tests use Swift Testing (`import Testing`). On a CommandLineTools-only Mac it needs extra compiler/linker flags: see [CONTRIBUTORS.md](CONTRIBUTORS.md#running-tests-without-full-xcode).
