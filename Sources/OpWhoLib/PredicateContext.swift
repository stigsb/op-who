import Foundation

/// NSObject KVC bridge between a `MatchContext` (a Swift struct) and an
/// `NSPredicate` (which evaluates against objects via key-value coding).
///
/// Exposes the subset of MatchContext fields that are meaningful inside
/// a rule predicate as `@objc` properties, flattening nested optionals
/// like `pluginUpdate?.remoteURL` into top-level keys so users can write
///   `triggerName == "git" AND ANY triggerArgv == "push"`
/// instead of dot-walking into nested structs they can't see in the UI.
///
/// New properties added here become part of the public predicate
/// surface — they show up in autocomplete, in the editor's "known keys"
/// validator, and in built-in rule strings. Don't add anything you
/// wouldn't want a user to depend on across releases.
@objc(OPPredicateContext)
public final class PredicateContext: NSObject {

    @objc public let triggerName: String
    @objc public let triggerArgv: [String]
    @objc public let chainNames: [String]
    @objc public let cwd: String?
    @objc public let triggerCwd: String?
    @objc public let binaryVerified: Bool
    @objc public let claudeSession: String?
    @objc public let terminalBundleID: String?
    @objc public let pluginRemoteURL: String?
    @objc public let pluginRepo: String?
    @objc public let pluginSourceType: String?
    @objc public let pluginMarketplaceName: String?
    @objc public let pluginUpdateAvailable: Bool

    public init(_ ctx: MatchContext) {
        self.triggerName = ctx.triggerName
        self.triggerArgv = ctx.triggerArgv
        self.chainNames = ctx.chain.map(\.name)
        self.cwd = ctx.cwd
        self.triggerCwd = ctx.triggerCwd
        self.binaryVerified = ctx.binaryVerified
        self.claudeSession = ctx.claudeSession
        self.terminalBundleID = ctx.terminalBundleID
        self.pluginRemoteURL = ctx.pluginUpdate?.remoteURL
        self.pluginRepo = ctx.pluginUpdate?.repo
        self.pluginSourceType = ctx.pluginUpdate?.sourceType
        self.pluginMarketplaceName = ctx.pluginUpdate?.marketplaceName
        self.pluginUpdateAvailable = (ctx.pluginUpdate != nil)
    }

    /// Stable list of the predicate keys this context exposes. The
    /// editor's syntax validator uses this to flag references to
    /// unknown keys at parse time rather than letting NSPredicate
    /// silently evaluate them to `nil`/`false`.
    public static let exposedKeys: [String] = [
        "triggerName",
        "triggerArgv",
        "chainNames",
        "cwd",
        "triggerCwd",
        "binaryVerified",
        "claudeSession",
        "terminalBundleID",
        "pluginRemoteURL",
        "pluginRepo",
        "pluginSourceType",
        "pluginMarketplaceName",
        "pluginUpdateAvailable",
    ]
}

extension MatchContext {
    /// Convenience: build the KVC bridge once per evaluation. Kept on
    /// MatchContext so callers don't need to import the wrapper type
    /// just to evaluate a predicate.
    public func predicateBridge() -> PredicateContext {
        PredicateContext(self)
    }
}
