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

## Build & TCC permissions

`scripts/bundle.sh` re-signs the assembled `.app` with `codesign --force --sign -` after copying `Info.plist` into place. This is mandatory, not cosmetic: TCC keys Accessibility (and Automation) grants on the code signature's identifier. Without the re-sign step, the bundle's identifier is the per-build hash that `swift build` assigns (`op-who-<sha1>`), which changes every rebuild and forces the user to re-grant Accessibility every time. Re-signing the bundle ad-hoc embeds the stable `CFBundleIdentifier` (`com.stigbakken.op-who`) as the identifier, which TCC then preserves across rebuilds.

If you change `bundle.sh` or the release-signing flow, preserve this property: the assembled bundle must end up signed (ad-hoc or real) with its `CFBundleIdentifier` as the signing identifier, and `Info.plist` must be in place *before* signing (otherwise `codesign -dvv` will report `Info.plist=not bound` and TCC behavior reverts to broken).

## Testing

```bash
swift test
```

Tests use Swift Testing (`import Testing`).
