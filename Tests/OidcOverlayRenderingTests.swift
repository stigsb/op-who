import Foundation
import Testing
@testable import OpWhoLib

@Suite("OIDC overlay rendering")
struct OidcOverlayRenderingTests {
    private func node(_ name: String, pid: pid_t = 100) -> ProcessNode {
        ProcessNode(pid: pid, ppid: 1, name: name, tty: nil,
                    executablePath: nil, isVerifiedOnePasswordCLI: false)
    }

    private func entry(
        source: RequestSource,
        chain: [ProcessNode],
        argv: [String] = [],
        title: String = "",
        kind: RequestKind = .oidcLogin,
        terminalBundleID: String? = nil,
        terminalPID: pid_t? = nil,
        appBundleID: String? = nil,
        appPID: pid_t? = nil,
        appName: String? = nil
    ) -> OverlayPanel.ProcessEntry {
        OverlayPanel.ProcessEntry(
            pid: 1, chain: chain, triggerArgv: argv, tty: nil,
            tabTitle: nil, tabShortcut: nil, claudeSession: nil, claudeContext: nil,
            scriptInfo: nil, terminalBundleID: terminalBundleID, terminalPID: terminalPID,
            cwd: nil, triggerCwd: nil, cmuxWorkspaceID: nil, cmuxTabID: nil,
            cmuxSurface: nil, pluginUpdate: nil,
            summary: RequestSummary(kind: kind, title: title, subtitle: nil, isWarning: false),
            matchedRuleID: nil, matchedRuleName: nil, matchedBuiltInID: nil,
            source: source, appBundleID: appBundleID, appPID: appPID, appName: appName
        )
    }

    @Test func oidcActionRowShowsSummaryTitle() {
        let e = entry(source: .oidcLogin, chain: [node("kubectl"), node("zsh")],
                      argv: ["kubectl", "get", "pods"],
                      title: "Your zsh shell needs a Kubernetes login for ‘kubectl get pods’")
        let rows = bodyRows(entry: e, dense: false)
        #expect(rows[0].label == nil)
        #expect(rows[0].value == "Your zsh shell needs a Kubernetes login for ‘kubectl get pods’")
        #expect(rows[0].style == .action(.oidcLogin))
        #expect(rows[1].label == "who")
        #expect(rows[1].value == "zsh")
    }

    @Test func onePasswordActionRowStillShowsCommand() {
        let e = entry(source: .onePassword, chain: [node("op"), node("zsh")],
                      argv: ["op", "read", "op://v/x"], title: "ignored", kind: .onePasswordCLI)
        #expect(bodyRows(entry: e, dense: false)[0].value == "op read op://v/x")
    }

    @Test func oidcEmptyChainWhoIsTheApp() {
        let e = entry(source: .oidcLogin, chain: [], title: "Visual Studio Code needs an OIDC login",
                      appBundleID: "com.microsoft.VSCode", appPID: 50, appName: "Visual Studio Code")
        let rows = bodyRows(entry: e, dense: false)
        #expect(rows.map(\.label) == [nil, "who"])
        #expect(rows[1].value == "Visual Studio Code")
    }

    @Test func oidcEmptyChainWithoutApp() {
        let e = entry(source: .oidcLogin, chain: [], title: "An unknown process needs an OIDC login")
        #expect(bodyRows(entry: e, dense: false)[1].value == "unknown")
    }

    @Test func leadRowPrefersTerminal() {
        let e = entry(source: .oidcLogin, chain: [node("kubectl")],
                      terminalBundleID: "com.googlecode.iterm2",
                      appBundleID: "com.googlecode.iterm2", appName: "iTerm")
        let app = OverlayPanel.leadRowApp(entry: e)
        #expect(app.bundleID == "com.googlecode.iterm2")
        #expect(app.name == "iTerm")
    }

    @Test func leadRowNamesNonTerminalAppForOidc() {
        let e = entry(source: .oidcLogin, chain: [],
                      appBundleID: "com.microsoft.VSCode", appName: "Visual Studio Code")
        let app = OverlayPanel.leadRowApp(entry: e)
        #expect(app.bundleID == "com.microsoft.VSCode")
        #expect(app.name == "Visual Studio Code")
        #expect(OverlayPanel.terminalRowText(entry: e, termName: app.name) == "Visual Studio Code")
    }

    @Test func leadRowWithoutAppForOidc() {
        let app = OverlayPanel.leadRowApp(entry: entry(source: .oidcLogin, chain: []))
        #expect(app.bundleID == nil)
        #expect(app.name == "Unknown app")
    }

    @Test func leadRowUnchangedForOnePassword() {
        let e = entry(source: .onePassword, chain: [node("op")], kind: .onePasswordCLI,
                      appBundleID: "com.microsoft.VSCode", appName: "Visual Studio Code")
        let app = OverlayPanel.leadRowApp(entry: e)
        #expect(app.bundleID == nil)
        #expect(app.name == "Unknown terminal")
    }

    @Test func treeRootIsTheAppForOidc() {
        let e = entry(source: .oidcLogin, chain: [],
                      appBundleID: "com.microsoft.VSCode", appPID: 50, appName: "Visual Studio Code")
        let root = OverlayPanel.treeRoot(entry: e)
        #expect(root.name == "Visual Studio Code")
        #expect(root.pid == 50)
    }

    @Test func treeRootUnchangedForOnePassword() {
        let e = entry(source: .onePassword, chain: [node("op")], kind: .onePasswordCLI,
                      terminalBundleID: "com.googlecode.iterm2", terminalPID: 40,
                      appBundleID: "com.googlecode.iterm2", appPID: 40)
        let root = OverlayPanel.treeRoot(entry: e)
        #expect(root.name == "iTerm")
        #expect(root.pid == 40)
    }
}
