import AppKit
import OpWhoLib
import ServiceManagement

/// Options section inside the Settings window. Holds the "Run on startup"
/// toggle that used to live in the status-bar menu, plus the dense-popup
/// and appearance overrides. Renders as a bare stack of controls — the
/// window's own title bar reads "op-who Settings", and a section header
/// above a handful of toggles would be visual noise. Wrapped in a
/// dedicated type so future global toggles can be added without reshaping
/// the surrounding layout; the section header can be reintroduced if more
/// options arrive.
final class GeneralPane: NSObject {

    private let settings = AppSettings()

    private let startupCheckbox = NSButton(
        checkboxWithTitle: "Run op-who on startup",
        target: nil,
        action: nil
    )

    private let denseCheckbox = NSButton(
        checkboxWithTitle: "Dense popup (collapse rows that don't apply)",
        target: nil, action: nil
    )
    private let appearanceLabel = NSTextField(labelWithString: "Appearance:")
    private let appearanceControl = NSSegmentedControl(
        labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil
    )

    private(set) lazy var view: NSView = makeContentView()

    override init() {
        super.init()
        _ = view
        startupCheckbox.target = self
        startupCheckbox.action = #selector(toggleStartup(_:))
        refreshState()

        denseCheckbox.target = self
        denseCheckbox.action = #selector(toggleDense(_:))
        denseCheckbox.state = settings.densePopup ? .on : .off

        appearanceControl.target = self
        appearanceControl.action = #selector(changeAppearance(_:))
        appearanceControl.selectedSegment = {
            switch settings.appearance {
            case .system: return 0
            case .light:  return 1
            case .dark:   return 2
            }
        }()
    }

    /// Re-read the SMAppService status. Called from the window-controller
    /// just before the window appears, so a change made via System Settings
    /// while op-who was running shows up the next time the user opens
    /// Settings.
    func refreshState() {
        startupCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private func makeContentView() -> NSView {
        let appearanceRow = NSStackView(views: [appearanceLabel, appearanceControl])
        appearanceRow.orientation = .horizontal
        appearanceRow.spacing = 8

        let stack = NSStackView(views: [startupCheckbox, denseCheckbox, appearanceRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
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

    @objc private func toggleDense(_ sender: NSButton) {
        settings.densePopup = (sender.state == .on)
    }

    @objc private func changeAppearance(_ sender: NSSegmentedControl) {
        let a: AppAppearance = [.system, .light, .dark][sender.selectedSegment]
        settings.appearance = a
        applyAppearance(a)
    }
}
