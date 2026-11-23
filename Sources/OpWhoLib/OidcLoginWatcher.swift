import AppKit
import Darwin
import os

/// Shows the overlay for OIDC logins announced by `oidc-browser`.
/// The notification is unauthenticated: only the PID (and an optional
/// window frame, used for placement) is taken from it, the PID must be a
/// kubelogin process, and all displayed text comes from the live process tree.
public final class OidcLoginWatcher {
    private var observer: NSObjectProtocol?
    /// The only OIDC panel. Reused for every request.
    private let overlayPanel = OverlayPanel()
    private var trackedPID: pid_t?
    private var pollTimer: Timer?

    public init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: OidcLogin.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            guard let request = OidcLogin.parse(userInfo: note.userInfo) else {
                Log.watcher.info("oidc: ignored malformed notification")
                return
            }
            self?.handle(request)
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        pollTimer?.invalidate()
    }

    private func handle(_ request: OidcLogin.Request) {
        let pid = request.requesterPID
        if trackedPID == pid { return }

        guard let path = ProcessTree.kernelExecutablePath(pid: pid),
              OidcLogin.isHelper(executablePath: path) else {
            Log.watcher.info("oidc: ignored pid=\(pid, privacy: .public), not kubelogin")
            return
        }
        let result = ProcessTree.buildChain(from: pid)
        guard let requester = result.chain.first, requester.pid == pid else {
            Log.watcher.info("oidc: ignored pid=\(pid, privacy: .public), no process chain")
            return
        }
        // Empty when an app (IDE, Lens) ran kubelogin itself.
        let chain = OidcLogin.dropHelpers(chain: result.chain) {
            ProcessTree.kernelExecutablePath(pid: $0)
        }
        let triggerArgv = chain.first.map { redactArgv(ProcessTree.processArgv(pid: $0.pid)) } ?? []
        let entry = TriggerEntryBuilder.makeEntry(
            foldedChain: chain,
            fallbackNode: requester,
            chainResult: result,
            triggerArgv: triggerArgv,
            rules: OidcLogin.rules,
            source: .oidcLogin
        )
        Log.watcher.info("oidc: showing pid=\(pid, privacy: .public) app=\(result.appBundleID ?? "<none>", privacy: .public) chain=\(chain.map(\.name).joined(separator: ","), privacy: .public)")

        let settings = AppSettings()
        overlayPanel.densePopup = settings.densePopup
        overlayPanel.style = PopupStyle(settings: settings)
        overlayPanel.show(entries: [entry], near: request.frame, placement: .insideBrowserWindow)
        PopupSound.resolve(id: PopupSound.effectiveID(
            ruleSoundID: nil, globalSoundID: settings.popupSoundID
        )).play()

        trackedPID = pid
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.dismissIfRequesterExited()
        }
    }

    /// kubelogin exits when the login completes or times out.
    private func dismissIfRequesterExited() {
        guard let pid = trackedPID, kill(pid, 0) != 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        trackedPID = nil
        overlayPanel.dismiss()
    }
}
