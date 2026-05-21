import AppKit
import ServiceManagement

/// Options section inside the Settings window. Currently holds just the
/// "Run on startup" toggle that used to live in the status-bar menu.
/// Renders as a bare checkbox — the window's own title bar reads
/// "op-who Settings", and a section header above a single toggle would
/// be visual noise. Wrapped in a dedicated type so future global
/// toggles can be added without reshaping the surrounding layout; the
/// section header can be reintroduced if more options arrive.
final class GeneralPane: NSObject {

    private let startupCheckbox = NSButton(
        checkboxWithTitle: "Run op-who on startup",
        target: nil,
        action: nil
    )

    private(set) lazy var view: NSView = makeContentView()

    override init() {
        super.init()
        _ = view
        startupCheckbox.target = self
        startupCheckbox.action = #selector(toggleStartup(_:))
        refreshState()
    }

    /// Re-read the SMAppService status. Called from the window-controller
    /// just before the window appears, so a change made via System Settings
    /// while op-who was running shows up the next time the user opens
    /// Settings.
    func refreshState() {
        startupCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private func makeContentView() -> NSView {
        let container = NSView()
        startupCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(startupCheckbox)

        NSLayoutConstraint.activate([
            startupCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            startupCheckbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            // Bottom anchor closes the container's intrinsic content size.
            // Without it, the surrounding NSStackView reads height 0 and
            // packs the next section right on top of this one.
            startupCheckbox.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    @objc private func toggleStartup(_ sender: NSButton) {
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
        refreshState()
    }
}
