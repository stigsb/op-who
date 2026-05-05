import AppKit
import OpWhoLib
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var watcher: OnePasswordWatcher!
    var startupMenuItem: NSMenuItem!
    var trustPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "op?"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(
            title: trusted ? "Accessibility: Granted" : "Accessibility: Not Granted",
            action: nil,
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        startupMenuItem = NSMenuItem(
            title: "Run on startup",
            action: #selector(toggleRunOnStartup(_:)),
            keyEquivalent: ""
        )
        startupMenuItem.target = self
        updateStartupMenuItemState()
        menu.addItem(startupMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu

        watcher = OnePasswordWatcher()

        if !trusted {
            startTrustPolling()
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = """
                op-who needs Accessibility access to detect 1Password approval dialogs.

                Go to System Settings > Privacy & Security > Accessibility and enable op-who. It will detect the change and restart itself automatically — no need to reopen.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Poll for Accessibility trust while we're running unprivileged.
    /// AXObserver registration is gated by trust at the moment of registration;
    /// once we've launched without trust, the watcher's observer is permanently
    /// inert until the process restarts. So when trust flips on, relaunch.
    private func startTrustPolling() {
        trustPollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, AXIsProcessTrusted() else { return }
            self.trustPollTimer?.invalidate()
            self.trustPollTimer = nil
            self.relaunchAfterTrustGranted()
        }
        // .common so the timer fires even while alerts/modal sessions are up.
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    private func relaunchAfterTrustGranted() {
        let bundlePath = Bundle.main.bundlePath
        NSLog("[op-who] Accessibility granted; relaunching from \(bundlePath)")

        // Spawn a detached shell that waits for us to exit, then reopens the bundle.
        let escaped = bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; /usr/bin/open '\(escaped)'"]
        do {
            try task.run()
        } catch {
            NSLog("[op-who] Failed to spawn relaunch helper: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStartupMenuItemState()
    }

    private func updateStartupMenuItemState() {
        startupMenuItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc func toggleRunOnStartup(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change startup setting"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        updateStartupMenuItemState()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
