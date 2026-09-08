import AppKit
import OpWhoLib
import ServiceManagement

/// The General tab: non-visual global options — the "Run on startup" toggle
/// (backed by SMAppService) and the popup alert sound. Visual popup settings
/// live in `AppearancePane`.
final class GeneralPane: NSObject {

    private let settings = AppSettings()

    private let startupCheckbox = NSButton(
        checkboxWithTitle: "Run op-who on startup",
        target: nil,
        action: nil
    )
    private let soundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let soundCatalog = PopupSound.catalog()
    private let playButton: NSButton = {
        let b = NSButton(title: "Play", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }()

    private(set) lazy var view: NSView = makeContentView()

    override init() {
        super.init()
        _ = view
        startupCheckbox.target = self
        startupCheckbox.action = #selector(toggleStartup(_:))
        populateSoundPopup()
        refreshState()
    }

    /// Re-read the SMAppService status. Called from the window-controller
    /// just before the window appears, so a change made via System Settings
    /// while op-who was running shows up the next time the user opens
    /// Settings.
    func refreshState() {
        startupCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    private func populateSoundPopup() {
        soundPopup.removeAllItems()
        soundPopup.addItems(withTitles: soundCatalog.map(\.title))
        let selected = PopupSound.resolve(id: settings.popupSoundID)
        soundPopup.selectItem(at: soundCatalog.firstIndex(of: selected) ?? 1)
        soundPopup.target = self
        soundPopup.action = #selector(soundChanged(_:))

        playButton.target = self
        playButton.action = #selector(playSound(_:))
    }

    private var selectedSound: PopupSound {
        let index = soundPopup.indexOfSelectedItem
        guard soundCatalog.indices.contains(index) else { return .knockKnock }
        return soundCatalog[index]
    }

    private func makeContentView() -> NSView {
        let soundRow = NSStackView(views: [
            NSTextField(labelWithString: "Sound when the popup appears:"),
            soundPopup,
            playButton,
        ])
        soundRow.orientation = .horizontal
        soundRow.spacing = 8

        let stack = NSStackView(views: [startupCheckbox, soundRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    @objc private func soundChanged(_ sender: NSPopUpButton) {
        let sound = selectedSound
        settings.popupSoundID = sound.id
        sound.play()
    }

    @objc private func playSound(_ sender: NSButton) {
        selectedSound.play()
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
