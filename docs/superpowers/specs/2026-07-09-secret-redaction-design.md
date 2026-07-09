# Secret redaction — design

**Date:** 2026-07-09
**Status:** Approved, pending implementation

## Problem

op-who reads the full `argv` of the trigger process (and of interpreter
processes in the chain) and surfaces it in two places:

- the **popup** — the main operation line (`operationDisplay`) and the `argv:`
  detail row (`OverlayPanel.detailLines`), plus the interpreter inline-command
  snippet (`ScriptInfo.scriptName`)
- the **logs** — e.g. the git-non-network drop line
  (`OnePasswordWatcher.swift:222`) joins the full argv

Ideally argv never contains a secret, but tools do sometimes pass one on the
command line (e.g. `op item create password[password]=hunter2`, or a token
pasted into a `curl -H "Authorization: Bearer …"` inside `bash -c '…'`). When
that happens op-who must not write the secret to the unified log or render it
in the popup.

## Approach

A small, pure, self-contained redaction module redacts secret-bearing
substrings out of argv **at capture time**, so every downstream consumer
(display, detail row, logs, predicate rule matching) only ever sees the
redacted form. There is no mature native-Swift secret scanner, so detection is
implemented in-repo as regex + entropy heuristics — no new dependency, no
shelling out.

### Redact-at-capture

Chosen over an output-boundary approach: it is the strongest guarantee that no
raw secret ever reaches a sink, and it does not require every present and
future output path to remember to call the redactor.

This is safe for the existing argv-based logic **only because redaction
preserves argv structure** — see the invariant below. The redactor replaces
secret *values*, never subcommands, flags, `op://` references, or paths, so
`describeOpInvocation`, `parseSubcommand`, git-network detection, and predicate
rules all keep working on the redacted argv exactly as before.

## Module: `Sources/OpWhoLib/SecretRedaction.swift`

Pure functions, no I/O, fully unit-testable.

### Public API

```swift
/// Redact secret-bearing substrings from an argv array.
/// Invariant: the returned array has the SAME count and order as the input;
/// each token maps to itself or to a token with secret substrings replaced by
/// the placeholder. Never drops, merges, or reorders tokens.
public func redactArgv(_ argv: [String]) -> [String]

/// Redact secrets inside a single string (used for interpreter inline-command
/// snippets such as `bash -c '…'`).
public func redactString(_ s: String) -> String
```

Placeholder constant: `‹redacted›` (U+2039 / U+203A single angle quotes).

### Detection layers

Applied per token; the op-field layer runs first, then the value (or whole
token) is checked against the pattern and entropy layers.

**1. `op` field assignments.** A token of shape `name[type]=value` or
`name=value`. Redact `value` when:

- `type` (when present) is `password` or `concealed`, **or**
- `name` (case-insensitive) contains one of: `credential`, `password`,
  `passwd`, `secret`, `token`, `apikey`, `api_key`; or matches the regex
  `private.?key`.

The `name[type]=` prefix is preserved, so the popup still reads
`password[password]=‹redacted›`. A non-matching field name (e.g.
`username=admin`) is left untouched but still passes through layers 2–3.

**2. Known token patterns.** Redact any substring matching a curated regex set:

- AWS access key id: `AKIA[0-9A-Z]{16}`
- GitHub tokens: `gh[pousr]_[A-Za-z0-9]{36,}`
- Slack tokens: `xox[baprs]-[A-Za-z0-9-]{10,}`
- Google API key: `AIza[0-9A-Za-z_-]{35}`
- JWT: `eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`
- PEM private key header: `-----BEGIN [A-Z ]*PRIVATE KEY-----`
- Bearer / auth header value: `(?i)(authorization:\s*)?bearer\s+[A-Za-z0-9._-]+`
- URL userinfo credentials: `://[^/\s:@]+:[^/\s@]+@` (redact the password part)

**3. High-entropy blob.** For a token — or the value after `=` — redact when
**all** hold:

- length ≥ 20
- Shannon entropy ≥ 3.5 bits/char
- charset is base64/hex-ish (only `[A-Za-z0-9+/=_-]`)
- **guards to skip** (limit false positives): the candidate contains `/`
  (filesystem path), starts with `op://`, or starts with `-` (a flag)

## Integration

**`OnePasswordWatcher.swift` (~line 220).** Wrap the captured argv immediately:

```swift
let triggerArgv = redactArgv(measure("processArgv[\(triggerPID)]") {
    ProcessTree.processArgv(pid: triggerPID)
})
```

This single site covers the git-drop log at :222, the popup main line, the
`argv:` detail row, and predicate rule matching, because they all read the
stored `triggerArgv`.

**`ProcessTree.detectScript`.** Apply `redactString` to each inline snippet
before `truncateSnippet(...)`, for the shell `-c`, python `-c`, perl/ruby
`-e`, and node `-e`/`-p` branches. (The `-m module` and script-path branches
are not secret-bearing and are left as-is.)

## Testing

Swift Testing (`import Testing`) table tests in
`Tests/OpWhoLibTests/SecretRedactionTests.swift`:

- **op field cases** — each keyword (`credential`, `password`, `passwd`,
  `secret`, `token`, `apikey`, `api_key`, `private.?key`) and each secret type
  (`[password]`, `[concealed]`) redacts the value and preserves the prefix.
- **known patterns** — one positive per regex above.
- **entropy** — a long random base64 blob redacts; a long filesystem path,
  an `op://vault/item/field` URI, and a `--long-flag=value` do **not**.
- **negatives / false-positive pins** — subcommands (`item`, `create`, `get`),
  normal words, short flags, `username=admin`, and `op://` references pass
  through unchanged.
- **`redactArgv` invariant** — output count and order equal input; a mixed
  argv with one secret token redacts exactly that token.

## Out of scope

- Environment-variable scrubbing — env values are not displayed or logged.
- Any network/file-based secret scanning.
- Redacting the trigger process name or chain names (never secret-bearing).
