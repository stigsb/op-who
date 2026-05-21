# Rules

A **rule** is what op-who uses to turn a captured 1Password approval into the one-line description it shows in the overlay. Every approval flows through an ordered list of rules; the first match wins; that rule's template is rendered against the captured context to produce the title.

The rules engine ships with a default set of built-ins covering the common cases (`git push`, `op read`, SSH key signing, Claude plugin update checks, etc.). You can disable any built-in or add your own user rules; user rules always run first, so a custom rule can shadow a built-in without removing it.

This document explains the concepts (actor, template, predicate, kind), gives an NSPredicate cheatsheet, and walks through example rules.

## Anatomy of a rule

A rule has eight user-visible fields. Five are required, three are flags or notes.

| Field | Purpose |
|---|---|
| **Name** | Human-friendly label, shown in the Rules pane. Doesn't affect matching. |
| **Predicate** | Boolean expression in NSPredicate format. If it evaluates true against the request, this rule is a candidate. |
| **Template** | String with `{placeholders}`. Rendered to produce the overlay text. |
| **Kind** | One of `onePasswordCLI`, `unverifiedOp`, `ssh`, `unknown`. Determines icon and grouping. |
| **Replaces actor** | If true, the template is the *whole* title. If false, op-who prefixes an auto-computed actor. |
| **Is warning** | If true, the entry is rendered with the warning style (used for the unverified-`op` rule, for example). |
| **Comment** | Free-form note for your future self. Never used by the engine. |
| **Enabled** | On/off switch. Disabled rules are skipped during evaluation. |

User rules live in `~/Library/Application Support/com.stigbakken.op-who/rules.json` and are reloaded whenever you save in the Settings window — no restart needed.

## The actor

The **actor** is the auto-computed prefix that identifies *who* triggered the request. It's derived from the process chain, the terminal app, and any detected Claude Code session. You don't write the actor — op-who picks it for you. Examples:

- `Claude Code session 'op-who'`
- `Claude Code in cmux workspace 'work'`
- `iTerm tab 'build'`
- `Your zsh shell`
- `Process 12345`

The **template** is the verb phrase that follows the actor. So a rule with template `is signing a commit in {cwd}` and an iTerm tab named `build` produces:

> iTerm tab 'build' **is signing a commit in /Users/stig/git/op-who**

If your template names its own subject (e.g. the Claude plugin update rule, which says *"Claude plugin update check for org/repo (marketplace)"*), the actor prefix would be noise. Set **Replaces actor** on the rule and op-who will use the template as the whole title.

## How matching works

For each approval the engine builds a `MatchContext` from the process chain, trigger argv, working directories, Claude session, and 1Password plugin metadata. It then walks the rule list in order:

1. Skip rules where `enabled == false`.
2. Parse the predicate. If NSPredicate rejects it, log and skip.
3. Evaluate the predicate against the context. If false, continue.
4. Render the template. **If any `{placeholder}` resolves to an empty string, treat the rule as a non-match and continue.**
5. Otherwise: this is the match. Return it.

The placeholder-empty-means-fall-through behaviour is how the built-ins do "structured render, then raw fallback" — two rules with the same predicate, the first using `{repo}` and the second using `{plugin_remote}`. If the structured lookup misses, the engine falls through to the simpler rule.

The final built-in is `TRUEPREDICATE` with template `triggered 1Password (via '{process}')` — it always matches, so you'll always get *something*.

## Predicate context: keys you can reference

These are the identifiers a predicate can mention. Everything else is unknown to the engine. The editor's syntax checker flags references to unknown keys.

| Key | Type | Notes |
|---|---|---|
| `triggerName` | String | Short name of the trigger process (`op`, `git`, `ssh`, `op-ssh-sign`, …). This is `kinfo_proc`'s name — argv[0] isn't used. |
| `triggerArgv` | [String] | Full argv of the trigger. Use `ANY` / `ALL` to match elements. |
| `subcommand` | String? | First non-flag argv token after argv[0] — `"push"` for `git -C /tmp push origin`. Honours `-C`, `-c`, `--git-dir`, `--work-tree`, `--namespace` pair-flags. |
| `chainNames` | [String] | Names of every process in the chain, trigger first. |
| `cwd` | String? | Tidied working directory found by walking up the chain. `nil` or `"/"` when nothing better was available. |
| `triggerCwd` | String? | The trigger's *own* CWD, un-tidied. Good for prefix matches like `triggerCwd BEGINSWITH "~/.claude/plugins"`. |
| `binaryVerified` | Bool | True iff the trigger is `op` and its on-disk binary is signed by 1Password's Apple Team ID. False for everything else. |
| `claudeSession` | String? | Claude Code session name (project basename) when Claude was in the chain. |
| `terminalBundleID` | String? | Bundle ID of the terminal app (`com.apple.Terminal`, `com.googlecode.iterm2`, …). |
| `pluginRemoteURL` | String? | Git remote URL when a Claude plugin update was detected. |
| `pluginRepo` | String? | `org/repo` form of the plugin remote when resolvable. |
| `pluginSourceType` | String? | Where the plugin came from (`marketplace`, `github`, …). |
| `pluginMarketplaceName` | String? | Friendly marketplace name when resolved via the known-marketplaces table. |
| `pluginUpdateAvailable` | Bool | True iff op-who detected a Claude plugin update check on this request. |

Quoted string literals starting with `~/` (or just `~`) are expanded to the current user's home before parsing. So `triggerCwd BEGINSWITH "~/git/foo"` is equivalent to `triggerCwd BEGINSWITH "/Users/you/git/foo"` and travels between machines.

## Template placeholders

These are the placeholders the template renderer understands. Anything else inside `{…}` is replaced with an empty string, which (per the matching rules above) causes the rule to fall through to the next one.

| Placeholder | Resolves to |
|---|---|
| `{process}` | `triggerName`, or `?` when the chain was empty. |
| `{subcommand}` | First non-flag argv token after argv[0]. Empty if not parseable. |
| `{argv}` | Pretty-printed command line, with argv[0] stripped to its basename. Empty if argv is empty. |
| `{cwd}` | Tidied working directory. Empty if `nil`, `""`, or `/`. |
| `{op_uri}` | First argv element starting with `op://`. Empty if none. |
| `{op_phrase}` | Phrase like `read op://X/Y` or `use 'op item get'` parsed from the `op` argv. Empty when argv isn't a recognizable `op` invocation. |
| `{plugin_remote}` | Plugin git remote URL. Empty when no Claude plugin update was detected. |
| `{repo}` | Plugin `org/repo`. Empty when unresolvable. |
| `{source}` | Plugin source type (marketplace name, etc.). |
| `{marketplace}` | Resolved marketplace name. |
| `{argv[N]}` | The Nth argv element, 0-indexed. Empty if out of range. |

## NSPredicate quick reference

op-who uses Apple's NSPredicate parser, which means you get the same syntax as Core Data fetch requests, AppleScript `where` clauses, etc. The relevant subset:

### Comparison

```
triggerName == "git"
binaryVerified == YES
subcommand != "status"
```

`YES`/`NO`, `TRUE`/`FALSE`, and `NIL`/`NULL` are the recognised literals. Keywords are case-insensitive (`and`, `AND`, `And` all work).

### Logical connectives

```
triggerName == "git" AND subcommand == "push"
triggerName == "ssh" OR triggerName == "scp"
NOT binaryVerified
```

### Set membership

```
triggerName IN {"op-ssh-sign", "ssh-keygen"}
subcommand IN {"fetch", "pull", "push", "clone"}
```

### Quantifiers on collections

`triggerArgv` and `chainNames` are arrays. Use `ANY` to match if *any* element satisfies the test, `ALL` for *every* element, `NONE` for none of them:

```
ANY triggerArgv == "sign"
ANY chainNames == "claude"
NONE triggerArgv BEGINSWITH "--debug"
```

### String tests

```
triggerCwd BEGINSWITH "~/git/sunstone"
cwd ENDSWITH "/tests"
triggerName CONTAINS "ssh"
pluginRemoteURL MATCHES ".*github\\.com.*"
```

Append `[c]` for case-insensitive (`BEGINSWITH[c]`), `[d]` for diacritic-insensitive, `[cd]` for both. `MATCHES` takes an ICU regex; `LIKE` takes glob-style `?`/`*` wildcards.

### Whole-predicate literals

```
TRUEPREDICATE     // always matches
FALSEPREDICATE    // never matches
```

`TRUEPREDICATE` is what the catch-all final built-in uses.

### Operator precedence

`NOT` binds tighter than `AND`, which binds tighter than `OR`. Use parentheses when you want to be explicit:

```
triggerName == "git" AND (subcommand == "push" OR subcommand == "fetch")
```

## Examples

### Match a specific tool

```
Name:      ssh into staging
Predicate: triggerName == "ssh" AND ANY triggerArgv CONTAINS "staging.example.com"
Template:  is opening an SSH session to staging
Kind:      ssh
```

### Project-scoped rule

```
Name:      Sunstone repos — git operations
Predicate: triggerName == "git" AND cwd BEGINSWITH "~/git/sunstone"
Template:  is running 'git {subcommand}' in a Sunstone repo
Kind:      ssh
```

### Highlight a specific 1Password vault read

```
Name:      Production secrets
Predicate: triggerName == "op" AND binaryVerified == YES AND ANY triggerArgv CONTAINS "op://prod"
Template:  wants to read a production secret ({op_uri})
Kind:      onePasswordCLI
Warning:   ✓
```

### Replace the actor entirely

When your template names the actor itself, set **Replaces actor**:

```
Name:           Nightly backup script
Predicate:      triggerName == "op" AND ANY triggerArgv CONTAINS "backup.sh"
Template:       Nightly backup script wants to read a credential ({op_uri})
Replaces actor: ✓
Kind:           onePasswordCLI
```

Without **Replaces actor**, op-who would render this as `Your zsh shell Nightly backup script wants to read…`, which reads badly.

### Structured render with a fallback

This is the pattern the built-in plugin-update rules use. Both rules have the same predicate; the first uses a `{repo}` placeholder that's empty when marketplace metadata is missing, so the engine falls through to the second.

```
Name:           Plugin update (known marketplace)
Predicate:      triggerName == "git" AND pluginUpdateAvailable == YES
Template:       Claude plugin update check for {repo} ({source})
Replaces actor: ✓

Name:           Plugin update (fallback)
Predicate:      triggerName == "git" AND pluginUpdateAvailable == YES
Template:       Claude plugin update check from {plugin_remote}
Replaces actor: ✓
```

## Testing a rule

The Rules pane has two affordances for trying a rule before relying on it in production:

- **Live preview.** As you edit a rule's template, the panel renders it against the most recent matching request in the ring buffer. If the template references a placeholder that doesn't resolve, you'll see a "no preview" message — that's the signal the rule would fall through.
- **Test Predicate sheet.** Lets you replay a draft predicate against every entry in the recent-requests ring buffer (up to 20 entries by default) and shows which ones it matches. Useful when you're trying to write a predicate that catches *just* the requests you mean to catch and nothing else.

The recent-requests buffer lives at `~/Library/Application Support/com.stigbakken.op-who/recent-requests.json` if you want to inspect it directly.

## How user rules and built-ins compose

User rules always run first, then built-ins (in their shipped order). Disabling a built-in doesn't remove it from the list — it just sets `enabled = false` so the engine skips it. This means:

- You can author a more specific rule that intercepts requests before a built-in catches them, without disabling the built-in.
- Disabled built-ins still appear (greyed-out) in the Rules pane so you can re-enable them later.
- Built-ins are keyed by a stable `builtInID` slug, not by name or UUID — so renaming or rewording a built-in across releases keeps your disabled-state intact.

If you ever want to start over, the Built-in Rules tab has an "Enable all built-ins" affordance, and deleting `rules.json` returns op-who to a fresh-install state on next launch.

## See also

- [architecture.md](architecture.md) — how requests are detected, what feeds the `MatchContext`, the process-chain walk.
- Apple's [NSPredicate](https://developer.apple.com/documentation/foundation/nspredicate) and [Predicate Format String Syntax](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Predicates/Articles/pSyntax.html) docs for the full predicate grammar.
