import Testing
import Foundation
import Darwin
@testable import OpWhoLib

private func node(_ name: String, pid: pid_t) -> ProcessNode {
    ProcessNode(pid: pid, ppid: 1, name: name, tty: nil,
                executablePath: nil, isVerifiedOnePasswordCLI: false)
}

@Suite("OidcLogin")
struct OidcLoginTests {
    @Test func helperMatchesExecutableBasename() {
        #expect(OidcLogin.isHelper(executablePath: "/opt/homebrew/bin/kubectl-oidc_login"))
        #expect(OidcLogin.isHelper(executablePath: "/usr/local/bin/kubelogin"))
        #expect(!OidcLogin.isHelper(executablePath: "/usr/local/bin/kubectl"))
        #expect(!OidcLogin.isHelper(executablePath: "/tmp/kubectl-oidc_log"))
        #expect(!OidcLogin.isHelper(executablePath: "/tmp/kubelogin/evil"))
    }

    @Test func dropRemovesLeadingHelpers() {
        let chain = [node("kubectl-oidc_log", pid: 10), node("kubectl", pid: 9), node("bash", pid: 8)]
        let paths: [pid_t: String] = [
            10: "/opt/homebrew/bin/kubectl-oidc_login", 9: "/opt/homebrew/bin/kubectl", 8: "/bin/bash",
        ]
        let rest = OidcLogin.dropHelpers(chain: chain) { paths[$0] }
        #expect(rest.map(\.pid) == [9, 8])
    }

    @Test func dropStopsAtFirstNonHelper() {
        let chain = [node("kubelogin", pid: 10), node("zsh", pid: 9), node("kubelogin", pid: 8)]
        let paths: [pid_t: String] = [10: "/x/kubelogin", 9: "/bin/zsh", 8: "/x/kubelogin"]
        let rest = OidcLogin.dropHelpers(chain: chain) { paths[$0] }
        #expect(rest.map(\.pid) == [9, 8])
    }

    @Test func dropCanEmptyTheChain() {
        let chain = [node("kubelogin", pid: 10)]
        #expect(OidcLogin.dropHelpers(chain: chain) { _ in "/x/kubelogin" }.isEmpty)
    }

    @Test func dropKeepsNodesWithUnknownPath() {
        let chain = [node("kubelogin", pid: 10)]
        #expect(OidcLogin.dropHelpers(chain: chain) { _ in nil }.map(\.pid) == [10])
    }

    @Test func parseReadsPIDAndFrame() {
        let req = OidcLogin.parse(userInfo: ["requesterPID": "4242", "frame": "10,20,800,600"])
        #expect(req == OidcLogin.Request(requesterPID: 4242, frame: CGRect(x: 10, y: 20, width: 800, height: 600)))
    }

    @Test func parseWithoutFrame() {
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "4242"])?.frame == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "4242", "frame": "garbage"])?.frame == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "4242", "frame": "0,0,0,600"])?.frame == nil)
    }

    @Test func parseRejectsBadPID() {
        #expect(OidcLogin.parse(userInfo: nil) == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "abc"]) == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": "1"]) == nil)
        #expect(OidcLogin.parse(userInfo: ["requesterPID": 4242]) == nil)
    }

    private func summary(chain: [ProcessNode], argv: [String], appName: String? = nil) -> RequestSummary {
        makeRequestSummary(
            chain: chain, triggerArgv: argv,
            tabTitle: nil, claudeSession: nil, terminalBundleID: nil, cwd: nil,
            rules: OidcLogin.rules, appName: appName
        )
    }

    @Test func kubectlRuleRendersCommand() {
        let s = summary(chain: [node("kubectl", pid: 9)],
                        argv: ["/opt/homebrew/bin/kubectl", "get", "pods", "-n", "demo"])
        #expect(s.title.hasSuffix("needs a Kubernetes login for ‘kubectl get pods -n demo’"))
        #expect(s.kind == .oidcLogin)
        #expect(!s.isWarning)
    }

    @Test func emptyChainNamesTheApp() {
        let s = summary(chain: [], argv: [], appName: "Visual Studio Code")
        #expect(s.title == "Visual Studio Code needs an OIDC login")
        #expect(s.kind == .oidcLogin)
    }

    @Test func emptyChainWithoutApp() {
        #expect(summary(chain: [], argv: []).title == "An unknown process needs an OIDC login")
    }

    @Test func otherTriggerUsesFallback() {
        let s = summary(chain: [node("helm", pid: 9)], argv: ["helm", "list"])
        #expect(s.title.hasSuffix("needs an OIDC login (via ‘helm’)"))
        #expect(s.kind == .oidcLogin)
    }

    @Test func kubectlWithoutArgvUsesFallback() {
        let s = summary(chain: [node("kubectl", pid: 9)], argv: [])
        #expect(s.title.hasSuffix("needs an OIDC login (via ‘kubectl’)"))
    }

    @Test func rulesAreThreeAndParse() throws {
        #expect(OidcLogin.rules.count == 3)
        for rule in OidcLogin.rules {
            _ = try PredicateParser.parse(rule.predicate)
            #expect(rule.kind == .oidcLogin)
        }
    }
}
