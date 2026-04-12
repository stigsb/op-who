import AppKit
import ApplicationServices

/// Watches for 1Password approval dialogs via the Accessibility API
/// and shows a process-tree overlay when one appears.
class OnePasswordWatcher {
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var overlayPanel: OverlayPanel?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var trackedDialogElement: AXUIElement?
    private var dialogPollTimer: Timer?

    private static let bundleIDs = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
    ]

    init() {
        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.bundleIDs.contains(bid) else { return }
            self?.attach(to: app)
        }
        workspaceObservers.append(launchObs)

        let termObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  Self.bundleIDs.contains(bid) else { return }
            self?.detach()
        }
        workspaceObservers.append(termObs)

        if let app = findOnePasswordApp() {
            attach(to: app)
        }
    }

    deinit {
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        detach()
    }

    // MARK: - Private

    private func findOnePasswordApp() -> NSRunningApplication? {
        for bid in Self.bundleIDs {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bid
            ).first {
                return app
            }
        }
        return nil
    }

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        appElement = AXUIElementCreateApplication(pid)

        var obs: AXObserver?
        let err = AXObserverCreate(pid, axCallbackFunction, &obs)
        guard err == .success, let obs = obs else {
            NSLog("[op-who] Failed to create AXObserver: \(err.rawValue)")
            return
        }
        observer = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(obs, appElement!, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appElement!, kAXFocusedWindowChangedNotification as CFString, refcon)

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )

        NSLog("[op-who] Attached to 1Password (pid \(pid))")
    }

    private func detach() {
        if let obs = observer, let el = appElement {
            AXObserverRemoveNotification(obs, el, kAXWindowCreatedNotification as CFString)
            AXObserverRemoveNotification(obs, el, kAXFocusedWindowChangedNotification as CFString)
        }
        observer = nil
        appElement = nil
        NSLog("[op-who] Detached from 1Password")
    }

    fileprivate func handleWindowEvent(element: AXUIElement) {
        let opProcs = ProcessTree.findOpProcesses()
        guard !opProcs.isEmpty else { return }

        let windowFrame = axWindowFrame(element) ?? axWindowFrame(appElement)

        var entries: [OverlayPanel.ProcessEntry] = []
        for proc in opProcs {
            let result = ProcessTree.buildChain(from: proc.pid)

            // Skip op processes with no meaningful context (e.g. spawned by 1Password itself)
            if result.chain.count <= 1 && result.tty == nil { continue }

            let tabTitle = result.tty.flatMap { tty in
                TerminalHelper.tabTitle(
                    forTTY: tty,
                    terminalBundleID: result.terminalBundleID,
                    terminalPID: result.terminalPID
                )
            }

            let claudeSession: String?
            if let claudePID = result.claudePID {
                claudeSession = ProcessTree.claudeSessionInfo(pid: claudePID)
            } else {
                claudeSession = nil
            }

            entries.append(OverlayPanel.ProcessEntry(
                pid: proc.pid,
                chain: result.chain,
                tty: result.tty,
                tabTitle: tabTitle,
                claudeSession: claudeSession,
                terminalBundleID: result.terminalBundleID
            ))
        }

        guard !entries.isEmpty else { return }

        // Track the dialog window so we can dismiss when it closes
        trackedDialogElement = element
        startDialogPolling()

        DispatchQueue.main.async { [weak self] in
            self?.showOverlay(entries: entries, near: windowFrame)
        }
    }

    private func showOverlay(entries: [OverlayPanel.ProcessEntry], near windowFrame: CGRect?) {
        if overlayPanel == nil {
            overlayPanel = OverlayPanel()
        }
        overlayPanel?.show(entries: entries, near: windowFrame)
    }

    /// Poll to detect when the 1Password dialog closes.
    /// We check both the AX element validity and whether op processes are still running.
    private func startDialogPolling() {
        dialogPollTimer?.invalidate()
        dialogPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkDialogStillOpen()
        }
    }

    private func stopDialogPolling() {
        dialogPollTimer?.invalidate()
        dialogPollTimer = nil
        trackedDialogElement = nil
    }

    private func checkDialogStillOpen() {
        // Check 1: is the tracked window still alive?
        var titleValue: AnyObject?
        let windowGone: Bool
        if let el = trackedDialogElement {
            let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &titleValue)
            windowGone = (err != .success)
        } else {
            windowGone = true
        }

        // Check 2: are there still op processes running?
        let opProcs = ProcessTree.findOpProcesses()
        let opsGone = opProcs.isEmpty

        if windowGone || opsGone {
            DispatchQueue.main.async { [weak self] in
                self?.overlayPanel?.dismiss()
                self?.stopDialogPolling()
            }
        }
    }

    private func axWindowFrame(_ element: AXUIElement?) -> CGRect? {
        guard let element = element else { return nil }

        var posValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: pos, size: size)
    }
}

private func axCallbackFunction(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let watcher = Unmanaged<OnePasswordWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleWindowEvent(element: element)
}
