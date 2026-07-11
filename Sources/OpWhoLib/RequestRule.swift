import Foundation

/// Inputs the rule engine evaluates against. Built from the same fields the
/// overlay already extracts; nothing new is computed here.
public struct MatchContext {
    public let chain: [ProcessNode]
    public let triggerArgv: [String]
    /// `bestCWD` of the chain, already tidied. nil/"" when unavailable.
    public let cwd: String?
    /// The trigger process's own CWD, untidied. Used for prefix matching
    /// against locations like `~/.claude/plugins/`.
    public let triggerCwd: String?
    public let claudeSession: String?
    public let pluginUpdate: ClaudePluginUpdate?
    public let terminalBundleID: String?

    public init(
        chain: [ProcessNode],
        triggerArgv: [String],
        cwd: String?,
        triggerCwd: String?,
        claudeSession: String?,
        pluginUpdate: ClaudePluginUpdate?,
        terminalBundleID: String?
    ) {
        self.chain = chain
        self.triggerArgv = triggerArgv
        self.cwd = cwd
        self.triggerCwd = triggerCwd
        self.claudeSession = claudeSession
        self.pluginUpdate = pluginUpdate
        self.terminalBundleID = terminalBundleID
    }

    /// The canonical trigger process name, as reported by kinfo_proc.
    /// (argv[0] may be a path; this is the short name the engine matches on.)
    public var triggerName: String { chain.first?.name ?? "" }

    /// True iff the trigger binary is signed by 1Password's Apple Team
    /// ID. ProcessTree only computes this for `op` today; other
    /// processes always read false.
    public var binaryVerified: Bool { chain.first?.isVerifiedOnePasswordCLI ?? false }
}

/// One ordered rule in the matcher list: NSPredicate-format predicate +
/// the description shown in the overlay when it wins.
///
/// The predicate is a string in NSPredicate's standard syntax, evaluated
/// against the properties exposed by `PredicateContext` (see
/// `PredicateContext.exposedKeys` for the full list). Examples:
///
///   triggerName == "git" AND subcommand IN {"push","fetch","pull"}
///   triggerName == "op" AND binaryVerified == NO
///   triggerName IN {"op-ssh-sign","ssh-keygen"} AND ANY triggerArgv == "sign"
///   triggerCwd BEGINSWITH "/Users/stig/git"
///
/// An empty or `TRUEPREDICATE` predicate matches every context.
public struct RequestRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// NSPredicate format string. Parsed lazily by the engine; a string
    /// the parser rejects causes the engine to skip the rule (with a
    /// log) rather than crash.
    public var predicate: String
    /// Template with `{process}`, `{subcommand}`, `{argv}`, `{cwd}`,
    /// `{op_uri}`, `{plugin_remote}`, `{repo}`, `{source}`, `{marketplace}`,
    /// and `{argv[N]}` named placeholders. A rule that references a
    /// placeholder which resolves to empty does NOT match — the engine
    /// falls through to the next rule. That's how 1a/1b style pairs
    /// (structured render then raw-URL fallback) coexist on the same
    /// predicate.
    public var template: String
    /// When true, `template` is the full title (actor prefix is suppressed).
    public var replacesActor: Bool
    public var kind: RequestKind
    public var isWarning: Bool
    /// Free-form human note attached to this rule. Surfaced in the
    /// Settings UI; never used by the engine. Nil for built-ins by default.
    public var comment: String?
    /// User-facing on/off switch. False means the engine skips this rule
    /// during evaluation, exactly as if it weren't in the list. For
    /// built-ins this mirrors the legacy `disabledBuiltInIDs` set — the
    /// store maintains both representations so older releases that only
    /// read `disabledBuiltInIDs` still honour the user's intent.
    public var enabled: Bool
    /// Stable, release-spanning identifier for rules shipped in
    /// `RequestRule.builtIns`. Nil for user-authored rules. Used by the
    /// store to track which built-ins the user has disabled and by
    /// `RequestRule.builtIn(id:)` to look one up. Must never change
    /// across releases once shipped — renaming a builtIn means picking
    /// a new ID counts as removing the old one for users who disabled it.
    public var builtInID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        predicate: String,
        template: String,
        replacesActor: Bool = false,
        kind: RequestKind,
        isWarning: Bool = false,
        comment: String? = nil,
        enabled: Bool = true,
        builtInID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.predicate = predicate
        self.template = template
        self.replacesActor = replacesActor
        self.kind = kind
        self.isWarning = isWarning
        self.comment = comment
        self.enabled = enabled
        self.builtInID = builtInID
    }

    /// Decoder that treats missing `enabled` / `comment` as defaults so
    /// rules.json files written without those fields decode cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.predicate = try c.decode(String.self, forKey: .predicate)
        self.template = try c.decode(String.self, forKey: .template)
        self.replacesActor = try c.decodeIfPresent(Bool.self, forKey: .replacesActor) ?? false
        self.kind = try c.decode(RequestKind.self, forKey: .kind)
        self.isWarning = try c.decodeIfPresent(Bool.self, forKey: .isWarning) ?? false
        self.comment = try c.decodeIfPresent(String.self, forKey: .comment)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.builtInID = try c.decodeIfPresent(String.self, forKey: .builtInID)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, predicate, template, replacesActor, kind, isWarning
        case comment, enabled, builtInID
    }
}

/// Result of running the rule engine over a context.
public struct MatchResult: Equatable {
    public let rule: RequestRule
    public let rendered: String
}

public enum RequestRuleEngine {
    // Rule predicates are static strings but `evaluate` runs once per candidate
    // (and more than once per candidate on a single dialog), so parsing each
    // one afresh every time is pure waste. Memoize the compiled NSPredicate
    // keyed by predicate text; the key space is bounded by the user's ruleset.
    private static let predicateCacheLock = NSLock()
    private static var predicateCache: [String: NSPredicate] = [:]

    private static func compiledPredicate(_ text: String) throws -> NSPredicate {
        predicateCacheLock.lock()
        if let cached = predicateCache[text] {
            predicateCacheLock.unlock()
            return cached
        }
        predicateCacheLock.unlock()

        let parsed = try PredicateParser.parse(text)

        predicateCacheLock.lock()
        predicateCache[text] = parsed
        predicateCacheLock.unlock()
        return parsed
    }

    /// First-match-wins. A rule whose template references a placeholder
    /// that resolves to empty is treated as a non-match so the engine
    /// falls through to the next rule. Rules with `enabled == false`
    /// are skipped without being consulted. Rules whose `predicate` is
    /// rejected by NSPredicate's parser are skipped too (logged once);
    /// crashing on a bad user-authored predicate would be worse than
    /// silently falling through.
    public static func evaluate(rules: [RequestRule], context: MatchContext) -> MatchResult? {
        let bridge = context.predicateBridge()
        for rule in rules {
            guard rule.enabled else { continue }
            let predicate: NSPredicate
            do {
                predicate = try compiledPredicate(rule.predicate)
            } catch {
                Log.app.error(
                    "Skipping rule \(rule.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            guard predicate.evaluate(with: bridge) else { continue }
            guard let rendered = renderTemplate(rule.template, context: context) else {
                continue
            }
            return MatchResult(rule: rule, rendered: rendered)
        }
        return nil
    }
}

/// Render `template` against `context`. Returns nil when the template
/// references a placeholder that resolves to an empty string — the engine
/// uses that signal to fall through to the next rule.
///
/// Only `{name}` placeholders are supported. The `{argv[N]}` form indexes
/// into the trigger argv directly.
public func renderTemplate(_ template: String, context: MatchContext) -> String? {
    var out = ""
    var i = template.startIndex
    while i < template.endIndex {
        let c = template[i]
        if c == "{" {
            guard let close = template[i...].firstIndex(of: "}") else {
                out.append(c)
                i = template.index(after: i)
                continue
            }
            let key = String(template[template.index(after: i)..<close])
            let value = resolvePlaceholder(key, context: context)
            if value.isEmpty { return nil }
            out.append(value)
            i = template.index(after: close)
        } else {
            out.append(c)
            i = template.index(after: i)
        }
    }
    return out
}

private func resolvePlaceholder(_ key: String, context: MatchContext) -> String {
    switch key {
    case "process":
        // The fallback rule's template references {process}; without a known
        // trigger we still want it to render (with a "?" placeholder) so the
        // rule never fails purely because chain[] was empty.
        let name = context.triggerName
        return name.isEmpty ? "?" : name
    case "subcommand":
        return parseSubcommand(argv: context.triggerArgv) ?? ""
    case "argv":
        guard !context.triggerArgv.isEmpty else { return "" }
        return operationDisplay(argv: context.triggerArgv, chain: context.chain, cwd: context.cwd)
    case "cwd":
        guard let c = context.cwd, !c.isEmpty, c != "/" else { return "" }
        return c
    case "op_uri":
        return context.triggerArgv.first(where: { $0.hasPrefix("op://") }) ?? ""
    case "op_phrase":
        // Preserves the original `describeOpInvocation` phrasing — useful
        // for the "unverified op" rule which wraps the parsed phrase in
        // parens. Returns "" when argv is too short to parse, which
        // (intentionally) causes the rule to fall through.
        return describeOpInvocation(argv: context.triggerArgv) ?? ""
    case "plugin_remote":
        return context.pluginUpdate?.remoteURL ?? ""
    case "repo":
        return context.pluginUpdate?.repo ?? ""
    case "source":
        return context.pluginUpdate?.sourceType ?? ""
    case "marketplace":
        return context.pluginUpdate?.marketplaceName ?? ""
    default:
        if key.hasPrefix("argv[") && key.hasSuffix("]") {
            let inside = key.dropFirst("argv[".count).dropLast()
            if let idx = Int(inside), idx >= 0, idx < context.triggerArgv.count {
                return context.triggerArgv[idx]
            }
            return ""
        }
        return ""
    }
}

/// All positional (non-flag) argv tokens after argv[0], in order. Skips:
///   - `-C value`, `-c value`, `--git-dir value`, `--work-tree value`,
///     `--namespace value` (two-token flag forms)
///   - any other token starting with `-` (including `--key=value`)
public func positionalArgvTokens(argv: [String]) -> [String] {
    guard !argv.isEmpty else { return [] }
    let pairFlags: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace"]
    var tokens: [String] = []
    var i = 1
    while i < argv.count {
        let a = argv[i]
        if pairFlags.contains(a) {
            i += 2
            continue
        }
        if a.hasPrefix("-") {
            i += 1
            continue
        }
        tokens.append(a)
        i += 1
    }
    return tokens
}

/// Parse the first non-flag argv token after argv[0]. See `positionalArgvTokens`
/// for the flag-skipping rules. Returns nil when no positional token remains.
public func parseSubcommand(argv: [String]) -> String? {
    positionalArgvTokens(argv: argv).first
}

// MARK: - Built-in ruleset

extension RequestRule {
    /// Rules shipped with the binary. The store merges these (filtered
    /// by `disabledBuiltInIDs`) after any user-authored rules.
    ///
    /// `static let` (not `var`) so the per-process UUIDs are assigned
    /// once per program run — keeps rule identity stable for the ring
    /// buffer's `matchedRuleID` links within a session. Across releases,
    /// `builtInID` (the stable string slug) is what survives.
    ///
    /// **Stability contract**: once shipped, a built-in's `builtInID` is
    /// frozen. Renaming or rewording a rule keeps the same ID so users
    /// who disabled it keep it disabled across upgrades. Retiring a rule
    /// means removing the entry; its ID then dangles harmlessly in
    /// users' `disabledBuiltInIDs` sets.
    public static let builtIns: [RequestRule] = [
        // 1a. Claude plugin housekeeping — structured display when
        // we can resolve the marketplace via known_marketplaces.json
        // ({repo} and {source} both empty → rule falls through).
        RequestRule(
            name: "Claude plugin update (known marketplace)",
            predicate: #"triggerName == "git" AND pluginUpdateAvailable == YES"#,
            template: "Claude plugin update check for {repo} ({source})",
            replacesActor: true,
            kind: .ssh,
            builtInID: "plugin-update-known-marketplace"
        ),
        // 1b. Claude plugin housekeeping — fallback when the
        // marketplace lookup missed (file absent, entry not yet
        // written, or non-marketplace plugin repo). Shows the raw
        // remote URL.
        RequestRule(
            name: "Claude plugin update",
            predicate: #"triggerName == "git" AND pluginUpdateAvailable == YES"#,
            template: "Claude plugin update check from {plugin_remote}",
            replacesActor: true,
            kind: .ssh,
            builtInID: "plugin-update-fallback"
        ),
        // 2a. Commit signing with a known cwd.
        RequestRule(
            name: "Commit signing (with cwd)",
            predicate: #"triggerName IN {"op-ssh-sign","ssh-keygen"} AND ANY triggerArgv == "sign" AND ANY triggerArgv == "git""#,
            template: "is signing a commit in {cwd}",
            kind: .ssh,
            builtInID: "commit-signing-with-cwd"
        ),
        // 2b. Commit signing fallback (no cwd).
        RequestRule(
            name: "Commit signing",
            predicate: #"triggerName IN {"op-ssh-sign","ssh-keygen"} AND ANY triggerArgv == "sign" AND ANY triggerArgv == "git""#,
            template: "is signing a commit",
            kind: .ssh,
            builtInID: "commit-signing"
        ),
        // 3. Other SSH signing (key conversion, fingerprinting via 1Password agent).
        RequestRule(
            name: "Other SSH signing",
            predicate: #"triggerName IN {"op-ssh-sign","ssh-keygen"}"#,
            template: "is signing with an SSH key",
            kind: .ssh,
            builtInID: "other-ssh-signing"
        ),
        // 4. Git network subcommand.
        RequestRule(
            name: "Git network operation",
            predicate: #"triggerName == "git" AND subcommand IN {"fetch","pull","push","clone","ls-remote","archive","remote","submodule","send-pack","receive-pack","upload-pack","fetch-pack"}"#,
            template: "needs an SSH key for ‘git {subcommand}’",
            kind: .ssh,
            builtInID: "git-network"
        ),
        // 5. Git fallback (no recognized subcommand — preserves legacy test).
        RequestRule(
            name: "Git fallback",
            predicate: #"triggerName == "git""#,
            template: "needs an SSH key (via ‘git’)",
            kind: .ssh,
            builtInID: "git-fallback"
        ),
        // 6. Plain ssh — no "via" qualifier per existing UX.
        RequestRule(
            name: "ssh",
            predicate: #"triggerName == "ssh""#,
            template: "needs an SSH key",
            kind: .ssh,
            builtInID: "ssh"
        ),
        // 7. scp / sftp / rsync — qualified with the tool name.
        RequestRule(
            name: "scp / sftp / rsync",
            predicate: #"triggerName IN {"scp","sftp","rsync"}"#,
            template: "needs an SSH key (via ‘{process}’)",
            kind: .ssh,
            builtInID: "scp-sftp-rsync"
        ),
        // 8a. Unverified op CLI with a parseable op invocation. Uses the
        // {op_phrase} placeholder so the parens read identically to the
        // pre-engine output ("(read op://X/Y)") rather than including
        // the binary name twice.
        RequestRule(
            name: "Unverified op (with phrase)",
            predicate: #"triggerName == "op" AND binaryVerified == NO"#,
            template: "is running an unverified ‘op’ binary ({op_phrase})",
            kind: .unverifiedOp,
            isWarning: true,
            builtInID: "unverified-op-with-phrase"
        ),
        // 8b. Unverified op fallback.
        RequestRule(
            name: "Unverified op",
            predicate: #"triggerName == "op" AND binaryVerified == NO"#,
            template: "is running an unverified ‘op’ binary",
            kind: .unverifiedOp,
            isWarning: true,
            builtInID: "unverified-op"
        ),
        // 9a. op read with explicit URI.
        RequestRule(
            name: "op read (URI)",
            predicate: #"triggerName == "op" AND subcommand == "read" AND binaryVerified == YES"#,
            template: "wants to read {op_uri}",
            kind: .onePasswordCLI,
            builtInID: "op-read-uri"
        ),
        // 9b. op read fallback (no URI parsed).
        RequestRule(
            name: "op read",
            predicate: #"triggerName == "op" AND subcommand == "read" AND binaryVerified == YES"#,
            template: "wants to use ‘op read’",
            kind: .onePasswordCLI,
            builtInID: "op-read"
        ),
        // 10. op signin.
        RequestRule(
            name: "op signin",
            predicate: #"triggerName == "op" AND subcommand == "signin" AND binaryVerified == YES"#,
            template: "wants to sign in to 1Password",
            kind: .onePasswordCLI,
            builtInID: "op-signin"
        ),
        // 11. op signout.
        RequestRule(
            name: "op signout",
            predicate: #"triggerName == "op" AND subcommand == "signout" AND binaryVerified == YES"#,
            template: "wants to sign out of 1Password",
            kind: .onePasswordCLI,
            builtInID: "op-signout"
        ),
        // 12. op inject.
        RequestRule(
            name: "op inject",
            predicate: #"triggerName == "op" AND subcommand == "inject" AND binaryVerified == YES"#,
            template: "wants to inject secrets via ‘op inject’",
            kind: .onePasswordCLI,
            builtInID: "op-inject"
        ),
        // 13. op run.
        RequestRule(
            name: "op run",
            predicate: #"triggerName == "op" AND subcommand == "run" AND binaryVerified == YES"#,
            template: "wants to run a command with ‘op run’",
            kind: .onePasswordCLI,
            builtInID: "op-run"
        ),
        // 14a. Known resource group with action — "op vault list".
        RequestRule(
            name: "op resource action",
            predicate: #"triggerName == "op" AND subcommand IN {"item","vault","document","user","group","account","ssh","connect","service-account","events-api"} AND binaryVerified == YES"#,
            template: "wants to use ‘op {subcommand} {argv[2]}’",
            kind: .onePasswordCLI,
            builtInID: "op-resource-with-action"
        ),
        // 14b. Same resource group without action — "op vault".
        RequestRule(
            name: "op resource",
            predicate: #"triggerName == "op" AND subcommand IN {"item","vault","document","user","group","account","ssh","connect","service-account","events-api"} AND binaryVerified == YES"#,
            template: "wants to use ‘op {subcommand}’",
            kind: .onePasswordCLI,
            builtInID: "op-resource"
        ),
        // 15. Any other op subcommand — "wants to run 'op something'".
        RequestRule(
            name: "op other subcommand",
            predicate: #"triggerName == "op" AND binaryVerified == YES"#,
            template: "wants to run ‘op {subcommand}’",
            kind: .onePasswordCLI,
            builtInID: "op-other-subcommand"
        ),
        // 16. op with no parseable subcommand.
        RequestRule(
            name: "op (no subcommand)",
            predicate: #"triggerName == "op" AND binaryVerified == YES"#,
            template: "is using the 1Password CLI",
            kind: .onePasswordCLI,
            builtInID: "op-no-subcommand"
        ),
        // 17. Fallback: anything unrecognized.
        RequestRule(
            name: "Unknown trigger",
            predicate: "TRUEPREDICATE",
            template: "triggered 1Password (via ‘{process}’)",
            kind: .unknown,
            isWarning: true,
            builtInID: "unknown-trigger"
        ),
    ]

    /// Look up a built-in by its stable ID. Returns nil for unknown IDs
    /// (e.g. an ID from a retired built-in that's still in a user's
    /// `disabledBuiltInIDs` set).
    public static func builtIn(id: String) -> RequestRule? {
        builtIns.first { $0.builtInID == id }
    }
}

/// Process-wide rule list. The store seeds this on launch with the
/// merged user + built-in list and rewrites it on every save, so
/// `makeRequestSummary` and the watcher can read a single source of
/// truth without threading the store through every call site.
public enum OpWhoConfig {
    public static var rules: [RequestRule] = RequestRule.builtIns
}
