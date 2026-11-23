import Foundation

/// Protocol and pure logic for OIDC login requests posted by `oidc-browser`
/// (sunstoneinstitute/cli-tools). See
/// docs/superpowers/specs/2026-11-23-oidc-login-overlay-design.md.
public enum OidcLogin {
    public static let notificationName = Notification.Name("ai.sunstoneinstitute.oidc-browser.login-opened")

    /// Seconds kubelogin must still be running after the notification before
    /// the overlay shows. A login that SSO completes without user input ends
    /// sooner, so only step-up or other logins that wait for the user get one.
    public static let showDelay: TimeInterval = 1

    /// Executable basenames of kubelogin.
    static let helperNames: Set<String> = ["kubectl-oidc_login", "kubelogin"]

    /// `executablePath` must come from `ProcessTree.kernelExecutablePath`
    /// (`proc_pidpath`). argv[0] and the KERN_PROCARGS2 exec path can be
    /// rewritten by the process; the kinfo name is truncated to 16 chars.
    public static func isHelper(executablePath: String) -> Bool {
        helperNames.contains((executablePath as NSString).lastPathComponent)
    }

    /// Drops leading kubelogin nodes so the first node is the command that
    /// needed the login. Returns an empty chain when an app ran kubelogin
    /// itself. `pathFor` is the kernel executable path lookup (injected).
    static func dropHelpers(chain: [ProcessNode], pathFor: (pid_t) -> String?) -> [ProcessNode] {
        var rest = chain[...]
        while let first = rest.first,
              let path = pathFor(first.pid), isHelper(executablePath: path) {
            rest = rest.dropFirst()
        }
        return Array(rest)
    }

    public struct Request: Equatable {
        public let requesterPID: pid_t
        /// Browser window frame in CG global coordinates (top-left origin).
        public let frame: CGRect?
    }

    static func parse(userInfo: [AnyHashable: Any]?) -> Request? {
        guard let pidString = userInfo?["requesterPID"] as? String,
              let pid = pid_t(pidString), pid > 1 else { return nil }
        var frame: CGRect? = nil
        if let f = userInfo?["frame"] as? String {
            let n = f.split(separator: ",", omittingEmptySubsequences: false).map {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            if n.count == 4, case let v = n.compactMap({ $0 }), v.count == 4,
               v.allSatisfy({ $0.isFinite }), v[2] > 0, v[3] > 0 {
                frame = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
            }
        }
        return Request(requesterPID: pid, frame: frame)
    }

    /// Fixed ruleset for OIDC entries. Not user-editable. Order matters:
    /// `{process}` renders "?" on an empty chain, so the empty-chain rule
    /// must precede the catch-all.
    public static let rules: [RequestRule] = [
        RequestRule(
            name: "kubectl login",
            predicate: #"triggerName == "kubectl""#,
            template: "needs a Kubernetes login for ‘{argv}’",
            kind: .oidcLogin
        ),
        RequestRule(
            name: "OIDC login (app)",
            predicate: #"triggerName == """#,
            template: "needs an OIDC login",
            kind: .oidcLogin
        ),
        RequestRule(
            name: "OIDC login",
            predicate: "TRUEPREDICATE",
            template: "needs an OIDC login (via ‘{process}’)",
            kind: .oidcLogin
        ),
    ]
}
