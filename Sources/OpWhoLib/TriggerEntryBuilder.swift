import Foundation

/// Gathers terminal, Claude, cmux, git and rule context for one trigger
/// process. Shared by the 1Password and OIDC watchers so both overlays
/// carry the same context and the same secret redaction.
enum TriggerEntryBuilder {
    /// `foldedChain` is trigger-first and may be empty (an app ran kubelogin
    /// itself). `fallbackNode` then supplies the PID, environment and CWD;
    /// 1Password callers pass the trigger node. `triggerArgv` must already
    /// be redacted.
    static func makeEntry(
        foldedChain: [ProcessNode],
        fallbackNode: ProcessNode,
        chainResult result: ChainResult,
        triggerArgv: [String],
        rules: [RequestRule],
        source: RequestSource
    ) -> OverlayPanel.ProcessEntry {
        let contextChain = foldedChain.isEmpty ? [fallbackNode] : foldedChain
        let triggerPID = contextChain[0].pid

        let tabInfo: TerminalHelper.TabInfo = result.tty.map { tty in
            measure("tabInfo[\(tty)]") {
                TerminalHelper.tabInfo(
                    forTTY: tty,
                    terminalBundleID: result.terminalBundleID,
                    terminalPID: result.terminalPID
                )
            }
        } ?? .empty
        let tabTitle = tabInfo.name

        let claudeSession: String?
        let claudeCtx: ClaudeContext?
        if let claudePID = result.claudePID {
            claudeSession = measure("claudeSessionInfo") { ProcessTree.claudeSessionInfo(pid: claudePID) }
            if let claudeCWD = measure("claudeCWD", { ProcessTree.processCWD(pid: claudePID) }) {
                claudeCtx = measure("claudeContext") { claudeContext(forCWD: claudeCWD) }
            } else {
                claudeCtx = nil
            }
        } else {
            claudeSession = nil
            claudeCtx = nil
        }

        // The trigger process often has CWD "/", so bestCWD walks to the
        // first ancestor with a real directory.
        let cwd = measure("bestCWD") { ProcessTree.bestCWD(chain: contextChain) }
            .map(ProcessTree.tidyPath)

        // The trigger's own (untidied) CWD feeds plugin-update detection and
        // the `triggerCwd` predicate key.
        let triggerCWD = measure("processCWD[\(triggerPID)]") { ProcessTree.processCWD(pid: triggerPID) }

        // Claude Code background plugin/marketplace update: a `git` trigger
        // whose own CWD lives under ~/.claude/plugins/.
        let pluginUpdate: ClaudePluginUpdate? = {
            guard foldedChain.first?.name == "git" else { return nil }
            return measure("claudePluginUpdate") {
                claudePluginUpdate(forCWD: triggerCWD)
            }
        }()

        // cmux: workspace / tab IDs from the env block, and CMUX_SURFACE_ID
        // resolved against the session file for the user-facing names.
        var cmuxWorkspaceID: String? = nil
        var cmuxTabID: String? = nil
        var cmuxSurface: CmuxSurfaceInfo? = nil
        if isCmuxBundleID(result.terminalBundleID) {
            let env = measure("processEnvironment[\(triggerPID)]") {
                ProcessTree.processEnvironment(
                    pid: triggerPID,
                    names: ["CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID"]
                )
            }
            cmuxWorkspaceID = env["CMUX_WORKSPACE_ID"]
            cmuxTabID = env["CMUX_TAB_ID"]

            // Env vars are inherited, so a node lacking the ID is covered by
            // an ancestor. Env reads plus one cached file read, nothing spawns.
            let uuid = measure("cmuxSurfaceUUID[\(triggerPID)]") {
                CmuxHelper.surfaceUUID(forChain: contextChain) { pid in
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

        // The app name is the actor for OIDC entries with an empty chain.
        // 1Password entries never use it (the 1Password dialog names the app).
        let appName: String? = source == .oidcLogin
            ? result.appBundleID.map { ProcessTree.appDisplayName(bundleID: $0) }
            : nil

        // Rules are evaluated here, once. The matched rule's id/name and the
        // rendered text are stored on the entry for every downstream consumer.
        let matchContext = MatchContext(
            chain: foldedChain,
            triggerArgv: triggerArgv,
            cwd: cwd,
            triggerCwd: triggerCWD,
            claudeSession: claudeSession,
            pluginUpdate: pluginUpdate,
            terminalBundleID: result.terminalBundleID
        )
        let summary = makeRequestSummary(
            chain: foldedChain,
            triggerArgv: triggerArgv,
            tabTitle: tabTitle,
            claudeSession: claudeSession,
            scriptInfo: result.scriptInfo,
            terminalBundleID: result.terminalBundleID,
            cwd: cwd,
            triggerCwd: triggerCWD,
            pluginUpdate: pluginUpdate,
            rules: rules,
            appName: appName
        )
        let matchResult = RequestRuleEngine.evaluate(rules: rules, context: matchContext)

        let gitCtx: GitContext? = cwd.flatMap { gitContext(forCwd: $0) }

        return OverlayPanel.ProcessEntry(
            pid: triggerPID,
            chain: foldedChain,
            triggerArgv: triggerArgv,
            tty: result.tty,
            tabTitle: tabTitle,
            tabShortcut: tabInfo.shortcut,
            claudeSession: claudeSession,
            claudeContext: claudeCtx,
            scriptInfo: result.scriptInfo,
            terminalBundleID: result.terminalBundleID,
            terminalPID: result.terminalPID,
            cwd: cwd,
            triggerCwd: triggerCWD,
            cmuxWorkspaceID: cmuxWorkspaceID,
            cmuxTabID: cmuxTabID,
            cmuxSurface: cmuxSurface,
            pluginUpdate: pluginUpdate,
            summary: summary,
            matchedRuleID: matchResult?.rule.id,
            matchedRuleName: matchResult?.rule.name,
            matchedBuiltInID: matchResult?.rule.builtInID,
            gitContext: gitCtx,
            soundID: matchResult?.rule.soundID,
            source: source,
            appBundleID: result.appBundleID,
            appPID: result.appPID,
            appName: appName
        )
    }
}
