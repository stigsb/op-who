# op-who

macOS menu bar utility that identifies which process triggered a 1Password approval dialog (CLI or SSH agent).

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for architecture, build instructions, and release process.

## Key design decisions

- Chain stops at any process registered as a macOS app (has bundle ID in NSWorkspace) since 1Password already shows the app name
- Trigger processes with no parent chain and no TTY are filtered out (1Password's own internal `op` helper)
- Dialog detection uses window title filtering (not content scanning) because 1Password's Electron web view loads asynchronously
- SSH agent dialogs detected by finding ssh/git/scp/sftp/rsync processes alongside 1Password's internal `op` helper
- Dialog dismissal detected by polling (500ms): checks AX element validity + whether trigger process PIDs still exist
- CWD walks the process chain to find the first non-`/` directory (trigger processes often have CWD `/`)
- Claude Code detected by checking `node` process args for "claude" or "@anthropic" strings
- `LSUIElement=true` in Info.plist makes this a menu bar app (no dock icon)
- Secrets are redacted at capture (`SecretRedaction.swift`): `op` field assignments with a `password`/`concealed` type or a credential-ish name, known token shapes (AWS/GitHub/Slack/JWT/PEM/Bearer/URL-userinfo), and high-entropy blobs are replaced with `‹redacted›`. `redactArgv` covers trigger argv (popup, unified log, predicate rule matching) and preserves token count/order so argv parsers are unaffected; `redactString` covers interpreter inline-command snippets (`ProcessTree.detectScript`) and user-typed Claude Code context (`ClaudeContext` last command/prompt, redacted before truncation).
- Popup body is an aligned two-column table with a fixed row order (action / who / git-root·branch·worktree or cwd / asked) so branch and worktree land in predictable places; `bodyRows`/`processTreeNodes`/`detailsYAMLLines` (`PopupLayout.swift`) are pure builders the AppKit layer renders. Git context (`GitContext.swift`) is gathered once per trigger via `git rev-parse` (worktree shown relative to the main worktree, or absolute when it ascends >1 level). Details render as a pstree-style process tree plus YAML (tty/pid/workspace/tab/argv). Colors live in `OverlayColors.swift`, audited for WCAG AA in both appearances. `AppSettings` persists `densePopup` (collapses droppable rows) and `appearance` (system/light/dark).
- Popup fonts and colors are configurable (`PopupStyle.swift`): `AppSettings` stores an optional UI-font family, mono-font family, a base size (default 12; the popup's three tiers render at base−1/base/base+1), and per-role color overrides (`popupColorOverrides`, keyed by `PopupColorRole.rawValue`). `PopupStyle` resolves each request to a concrete `NSFont`/`NSColor`, falling back to the system font or the WCAG-audited `OverlayColors` default; `OverlayColors` stays the home of the defaults and the contrast test. The Settings window is an `NSTabView` (General / Appearance / Rules): `GeneralPane` holds only Run-on-startup; `AppearancePane` owns dense-popup, light/dark, the font pickers, size stepper, per-role color wells, and a Show/Hide Preview backed by `OverlayPanel.sampleEntry()`.

## Build & TCC permissions

`scripts/bundle.sh` re-signs the assembled `.app` with `codesign --force --sign -` after copying `Info.plist` into place. This is mandatory, not cosmetic: TCC keys Accessibility (and Automation) grants on the code signature's identifier. Without the re-sign step, the bundle's identifier is the per-build hash that `swift build` assigns (`op-who-<sha1>`), which changes every rebuild and forces the user to re-grant Accessibility every time. Re-signing the bundle ad-hoc embeds the stable `CFBundleIdentifier` (`com.stigbakken.op-who`) as the identifier, which TCC then preserves across rebuilds.

If you change `bundle.sh` or the release-signing flow, preserve this property: the assembled bundle must end up signed (ad-hoc or real) with its `CFBundleIdentifier` as the signing identifier, and `Info.plist` must be in place *before* signing (otherwise `codesign -dvv` will report `Info.plist=not bound` and TCC behavior reverts to broken).

## Testing

```bash
swift test
```

Tests use Swift Testing (`import Testing`).

### Running tests without full Xcode (CommandLineTools-only toolchains)

On a machine where `xcode-select -p` points at `/Library/Developer/CommandLineTools`
(no full Xcode installed), a bare `swift test` fails. The `Testing` framework
ships with CommandLineTools but is not on the default compile or runtime search
paths, so you hit a cascade of errors: first `no such module 'Testing'` at compile
time, then at runtime `Library not loaded: @rpath/Testing.framework/...`, then
`@rpath/lib_TestingInterop.dylib`.

The compile path is fixed by passing the framework search path; the runtime
failures happen because `swiftpm-testing-helper` strips `DYLD_*` env vars on
re-exec (SIP), so the dylibs must be reachable via the test binary's `@rpath`.
The binary searches `.build/<triple>/debug/`, so symlink both libraries there:

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
BUILD=.build/arm64-apple-macosx/debug   # adjust triple for Intel
ln -sf "$FW/Testing.framework"          "$BUILD/Testing.framework"
ln -sf "$LIB/lib_TestingInterop.dylib"  "$BUILD/lib_TestingInterop.dylib"

swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW"
```

The symlinks live under `.build/` (gitignored) and survive until the next clean.
Installing full Xcode and `xcode-select`-ing to it avoids the whole dance.
