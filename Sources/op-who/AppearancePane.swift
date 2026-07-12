import AppKit
import OpWhoLib

/// The Appearance tab: all popup visual settings. Each control writes to
/// AppSettings immediately, so the Preview button (and the next real popup)
/// reflect changes without an explicit save.
final class AppearancePane: NSObject {

    private let settings = AppSettings()

    // Behavior + appearance (moved from GeneralPane).
    private let denseCheckbox = NSButton(
        checkboxWithTitle: "Dense popup (collapse rows that don't apply)",
        target: nil, action: nil
    )
    private let appearanceControl = NSSegmentedControl(
        labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil
    )

    // Fonts.
    private let uiFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let monoFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeStepper = NSStepper()
    private let sizeLabel = NSTextField(labelWithString: "")

    // Colors: one well per role, in declaration order.
    private var colorWells: [PopupColorRole: NSColorWell] = [:]

    // Preview.
    private var previewPanel: OverlayPanel?

    private static let systemDefaultTitle = "System default"

    private(set) lazy var view: NSView = makeContentView()

    override init() {
        super.init()
        _ = view
        wireControls()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        denseCheckbox.state = settings.densePopup ? .on : .off

        appearanceControl.selectedSegment = {
            switch settings.appearance {
            case .system: return 0
            case .light:  return 1
            case .dark:   return 2
            }
        }()

        populateFontPopup(uiFontPopup, selected: settings.popupUIFontName)
        populateFontPopup(monoFontPopup, selected: settings.popupMonoFontName)

        sizeStepper.minValue = 9
        sizeStepper.maxValue = 24
        sizeStepper.increment = 1
        sizeStepper.integerValue = Int(settings.popupFontBaseSize.rounded())
        updateSizeLabel()

        let stack = NSStackView(views: [
            sectionLabel("Popup"),
            denseCheckbox,
            labeledRow("Appearance:", appearanceControl),
            spacer(),
            sectionLabel("Fonts"),
            labeledRow("UI font:", uiFontPopup),
            labeledRow("Mono font:", monoFontPopup),
            labeledRow("Base size:", sizeRow()),
            spacer(),
            sectionLabel("Colors"),
            colorGrid(),
            restoreRow(),
            spacer(),
            previewRow(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.boldSystemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return v
    }

    private func labeledRow(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let row = NSStackView(views: [l, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func sizeRow() -> NSStackView {
        let row = NSStackView(views: [sizeLabel, sizeStepper])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        sizeLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return row
    }

    /// Per-role color wells laid out as fixed columns of `name → pill` pairs,
    /// four pairs per row. Built from plain stacks (not an NSGridView, which
    /// stretched to the pane width and flung its columns apart): each name
    /// label has a fixed width so the pills line up vertically, and every row
    /// ends in a low-hugging spacer that absorbs slack so the pills stay put
    /// at the left instead of drifting as the pane resizes.
    private func colorGrid() -> NSView {
        let pairsPerRow = 4
        var rows: [NSView] = []
        var cells: [NSView] = []
        for role in PopupColorRole.allCases {
            cells.append(colorCell(for: role))
            if cells.count == pairsPerRow {
                rows.append(colorRow(cells))
                cells = []
            }
        }
        if !cells.isEmpty { rows.append(colorRow(cells)) }

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        return column
    }

    /// One `name → pill` cell with a fixed-width label so pills column-align.
    private func colorCell(for role: PopupColorRole) -> NSView {
        let name = NSTextField(labelWithString: role.rawValue)
        name.font = NSFont.systemFont(ofSize: 11)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let cell = NSStackView(views: [name, makeColorWell(for: role)])
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 6
        return cell
    }

    /// A row of color cells followed by a spacer that soaks up extra width,
    /// keeping the cells left-aligned regardless of the row's actual width.
    private func colorRow(_ cells: [NSView]) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: cells + [spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        return row
    }

    /// Build and register the color well for a role.
    private func makeColorWell(for role: PopupColorRole) -> NSColorWell {
        let well = NSColorWell()
        well.color = PopupStyle(settings: settings).color(role)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 38).isActive = true
        well.heightAnchor.constraint(equalToConstant: 20).isActive = true
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.tag = colorTag(for: role)
        colorWells[role] = well
        return well
    }

    private func restoreRow() -> NSView {
        let btn = NSButton(title: "Restore default colors", target: self,
                           action: #selector(restoreDefaults(_:)))
        btn.bezelStyle = .rounded
        return btn
    }

    private func previewRow() -> NSStackView {
        let show = NSButton(title: "Show Preview", target: self, action: #selector(showPreview(_:)))
        show.bezelStyle = .rounded
        let hide = NSButton(title: "Hide Preview", target: self, action: #selector(hidePreview(_:)))
        hide.bezelStyle = .rounded
        let row = NSStackView(views: [show, hide])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - Wiring

    private func wireControls() {
        denseCheckbox.target = self
        denseCheckbox.action = #selector(toggleDense(_:))
        appearanceControl.target = self
        appearanceControl.action = #selector(changeAppearance(_:))
        uiFontPopup.target = self
        uiFontPopup.action = #selector(uiFontChanged(_:))
        monoFontPopup.target = self
        monoFontPopup.action = #selector(monoFontChanged(_:))
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeChanged(_:))
    }

    private func populateFontPopup(_ popup: NSPopUpButton, selected: String?) {
        popup.removeAllItems()
        popup.addItem(withTitle: Self.systemDefaultTitle)
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        popup.addItems(withTitles: families)
        if let selected, families.contains(selected) {
            popup.selectItem(withTitle: selected)
        } else {
            popup.selectItem(withTitle: Self.systemDefaultTitle)
        }
    }

    /// Encode a role as an NSControl tag via its position in `allCases`.
    private func colorTag(for role: PopupColorRole) -> Int {
        PopupColorRole.allCases.firstIndex(of: role) ?? 0
    }
    private func role(forTag tag: Int) -> PopupColorRole? {
        let all = PopupColorRole.allCases
        return all.indices.contains(tag) ? all[tag] : nil
    }

    private func updateSizeLabel() {
        sizeLabel.stringValue = "\(sizeStepper.integerValue)"
    }

    private func selectedFontName(_ popup: NSPopUpButton) -> String? {
        let title = popup.titleOfSelectedItem ?? Self.systemDefaultTitle
        return title == Self.systemDefaultTitle ? nil : title
    }

    // MARK: - Actions

    @objc private func toggleDense(_ sender: NSButton) {
        settings.densePopup = (sender.state == .on)
    }

    @objc private func changeAppearance(_ sender: NSSegmentedControl) {
        let a: AppAppearance = [.system, .light, .dark][sender.selectedSegment]
        settings.appearance = a
        applyAppearance(a)
    }

    @objc private func uiFontChanged(_ sender: NSPopUpButton) {
        settings.popupUIFontName = selectedFontName(sender)
    }

    @objc private func monoFontChanged(_ sender: NSPopUpButton) {
        settings.popupMonoFontName = selectedFontName(sender)
    }

    @objc private func sizeChanged(_ sender: NSStepper) {
        settings.popupFontBaseSize = Double(sender.integerValue)
        updateSizeLabel()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let role = role(forTag: sender.tag) else { return }
        var overrides = settings.popupColorOverrides
        overrides[role.rawValue] = sender.color.popupHexString
        settings.popupColorOverrides = overrides
    }

    @objc private func restoreDefaults(_ sender: NSButton) {
        settings.popupColorOverrides = [:]
        for (role, well) in colorWells {
            well.color = role.defaultColor
        }
    }

    @objc private func showPreview(_ sender: NSButton) {
        previewPanel?.dismiss()
        let panel = OverlayPanel()
        panel.densePopup = settings.densePopup
        panel.style = PopupStyle(settings: settings)
        panel.show(entries: [OverlayPanel.sampleEntry()], near: nil)
        previewPanel = panel
    }

    @objc private func hidePreview(_ sender: NSButton) {
        previewPanel?.dismiss()
        previewPanel = nil
    }

    /// Called by the window controller when Settings closes, so neither a
    /// stray preview panel nor an active color well's floating color panel
    /// lingers after the window is gone.
    func dismissPreview() {
        previewPanel?.dismiss()
        previewPanel = nil
        colorWells.values.forEach { $0.deactivate() }
    }
}
