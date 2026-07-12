import AppKit

public class OverlayPanel {

    public struct ProcessEntry {
        let pid: pid_t
        let chain: [ProcessNode]
        let triggerArgv: [String]
        let tty: String?
        let tabTitle: String?
        /// Optional keyboard-shortcut hint for jumping to the source tab
        /// (e.g. "⌘1", "⌘9", "window 2 ⌘3"). Set for iTerm, nil for other
        /// terminals where the concept doesn't apply.
        let tabShortcut: String?
        let claudeSession: String?
        let claudeContext: ClaudeContext?
        /// Closest-to-trigger interpreter + script, when one was detected
        /// (`python deploy.py`, `bash -c 'op signin'`, …). Suppressed when
        /// Claude Code is in the chain — its own session label is richer.
        let scriptInfo: ScriptInfo?
        let terminalBundleID: String?
        let terminalPID: pid_t?
        let cwd: String?
        /// Trigger process's own (untidied) CWD. Stored for the ring buffer
        /// so we can later replay rules whose `triggerCwdPrefix` matters.
        let triggerCwd: String?
        let cmuxWorkspaceID: String?
        let cmuxTabID: String?
        let cmuxSurface: CmuxSurfaceInfo?
        /// Set when the trigger is a `git` operation Claude Code initiated
        /// in the background to refresh a plugin/marketplace repo.
        let pluginUpdate: ClaudePluginUpdate?
        /// Pre-computed summary (title/subtitle/kind/isWarning) for this
        /// entry. Computed once by the watcher so the overlay and log don't
        /// re-evaluate the rule engine.
        let summary: RequestSummary
        /// Identity of the rule that produced `summary`. Used to render
        /// the matched-rule name in the recent-requests ring buffer.
        let matchedRuleID: UUID?
        let matchedRuleName: String?
        /// Stable, release-spanning identifier of the matched rule when
        /// the match was a built-in; nil for user-authored rules. Stored
        /// alongside `matchedRuleID` so `RecentRequest` can look up the
        /// matched built-in after a restart (UUIDs are regenerated each
        /// process run).
        let matchedBuiltInID: String?
        /// Git context for the trigger's working directory, gathered at
        /// capture time. nil when the trigger did not run inside a repo.
        ///
        /// Declared `var` (not `let`, unlike sibling fields): Swift's
        /// synthesized memberwise initializer omits an explicit parameter
        /// entirely for a `let` property that has a default value, so a
        /// call site could never pass one in. A `var` with a default still
        /// gets an (optional, defaulted) initializer parameter, which is
        /// what lets `OnePasswordWatcher` supply a real value while every
        /// other call site keeps compiling with the `nil` default.
        var gitContext: GitContext? = nil
    }

    public init() {}

    /// A representative entry used by the Settings "Preview" button so fonts
    /// and colors can be judged without waiting for a real 1Password prompt.
    public static func sampleEntry() -> ProcessEntry {
        ProcessEntry(
            pid: 4242,
            chain: [
                ProcessNode(pid: 4242, ppid: 4200, name: "op", tty: "/dev/ttys003",
                            executablePath: "/opt/homebrew/bin/op", isVerifiedOnePasswordCLI: true),
                ProcessNode(pid: 4200, ppid: 4100, name: "node", tty: "/dev/ttys003",
                            executablePath: nil, isVerifiedOnePasswordCLI: false),
                ProcessNode(pid: 4100, ppid: 1, name: "zsh", tty: "/dev/ttys003",
                            executablePath: nil, isVerifiedOnePasswordCLI: false),
            ],
            triggerArgv: ["op", "read", "op://vault/item/password"],
            tty: "/dev/ttys003",
            tabTitle: "op-who",
            tabShortcut: nil,
            claudeSession: "preview",
            claudeContext: nil,
            scriptInfo: nil,
            terminalBundleID: "com.googlecode.iterm2",
            terminalPID: 4000,
            cwd: "~/git/stigsb/op-who",
            triggerCwd: "~/git/stigsb/op-who",
            cmuxWorkspaceID: nil,
            cmuxTabID: nil,
            cmuxSurface: nil,
            pluginUpdate: nil,
            summary: RequestSummary(kind: .onePasswordCLI, title: "Preview", subtitle: nil, isWarning: false),
            matchedRuleID: nil,
            matchedRuleName: nil,
            matchedBuiltInID: nil,
            gitContext: GitContext(root: "~/git/stigsb/op-who", branch: "main", worktreeSubpath: nil)
        )
    }

    private var panel: NSPanel?

    /// Trailing time labels updated every second by `elapsedTimer`.
    private var elapsedLabels: [ElapsedLabel] = []
    private var elapsedTimer: Timer?

    /// When true, droppable rows collapse (see AppSettings.densePopup).
    public var densePopup: Bool = false

    /// Resolves popup fonts and colors from user settings. Defaults to the
    /// historical appearance; set before `show` (see OnePasswordWatcher).
    public var style: PopupStyle = .default

    /// When the overlay was shown. The elapsed-time column counts up from
    /// here — it measures how long the *approval* has been pending, not how
    /// long the trigger process has been alive (a long-lived ssh session
    /// would otherwise start the timer at its full age instead of 0).
    private var shownAt: Date = .distantPast

    public func show(entries: [ProcessEntry], near windowFrame: CGRect?) {

        let panel = makePanel()
        self.panel = panel

        // Build content (and as a side effect, register elapsed labels).
        // Anchor the elapsed timer to now, before building, so every label
        // counts up from the moment the popup appeared.
        shownAt = Date()
        elapsedLabels.removeAll()
        let contentView = buildContentView(entries: entries)
        panel.contentView = contentView
        refreshElapsed()
        startElapsedTimer()

        let fittingSize = contentView.fittingSize
        let panelSize = NSSize(
            width: max(fittingSize.width + 32, 320),
            height: fittingSize.height + 24
        )

        let origin: NSPoint
        if let frame = windowFrame {
            // AX uses CG global coordinates (origin = top-left of primary display, y grows down).
            // AppKit uses bottom-left of primary display, y grows up. The flip MUST use the
            // primary display's height — not NSScreen.main, which tracks keyboard focus and
            // can be a non-primary screen on multi-monitor setups.
            let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                ?? NSScreen.screens.first
                ?? NSScreen.main)?.frame.height ?? 0
            let axBottom = frame.origin.y + frame.size.height
            let appKitY = primaryHeight - axBottom
            origin = NSPoint(
                x: frame.origin.x + (frame.width - panelSize.width) / 2,
                y: appKitY + frame.height + 8
            )
        } else if let screen = NSScreen.main {
            origin = NSPoint(
                x: screen.frame.midX - panelSize.width / 2,
                y: screen.frame.midY + 100
            )
        } else {
            origin = NSPoint(x: 200, y: 400)
        }

        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.orderFrontRegardless()
    }

    public func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsedLabels.removeAll()
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshElapsed()
        }
        // Common run-loop mode so the tick fires even while menu tracking, modal
        // sessions, or other panels are foregrounded.
        RunLoop.main.add(t, forMode: .common)
        elapsedTimer = t
    }

    private func refreshElapsed() {
        let now = Date()
        for entry in elapsedLabels {
            let secs = now.timeIntervalSince(entry.startTime)
            entry.label.stringValue = formatElapsed(secs)
            entry.label.textColor = elapsedColor(secs)
        }
    }

    // MARK: - UI Construction

    private func makePanel() -> NSPanel {
        if let existing = panel { return existing }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        // A programmatically created NSPanel defaults to releasing itself when
        // its close button is clicked. The Settings "Preview" reuses/re-shows
        // the panel, so a released-then-reordered panel would be a
        // use-after-free — keep it alive and let `dismiss()` own its lifetime.
        p.isReleasedWhenClosed = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.backgroundColor = NSColor.windowBackgroundColor
        p.hasShadow = true

        return p
    }

    /// Internal (not private) so a regression test can exercise the AppKit
    /// content assembly — the header row pins itself to the stack's full width
    /// and hosts the elapsed timer.
    func buildContentView(entries: [ProcessEntry]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        // Header row: "op-who" on the left, the live elapsed timer pinned to
        // the top-right corner. The timer counts up from `shownAt` and belongs
        // to the whole popup, so it lives here once rather than on each entry's
        // terminal row (which reclaims that row's trailing space).
        let header = makeHeaderRow()
        stack.addArrangedSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        header.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        for entry in entries {
            stack.addArrangedSubview(buildEntryView(entry))
        }

        return stack
    }

    /// The top header row: "op-who" label leading, elapsed timer trailing
    /// (top-right corner). Registers the timer with `elapsedLabels`.
    private func makeHeaderRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        let title = makeLabel("op-who", role: .ui, weight: .medium, tier: .small, color: .secondaryLabelColor)
        // Low hugging = absorbs the slack, pushing the timer to the right edge.
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(title)

        row.addArrangedSubview(makeElapsedLabel())
        return row
    }

    /// Build the elapsed-time label, register it for per-second updates, and
    /// return it. Counts up from `shownAt` (how long the approval has been
    /// pending), right-aligned in a fixed-width slot so growing values fill
    /// from the right instead of shoving the row around.
    private func makeElapsedLabel() -> NSTextField {
        let timeLabel = makeLabel(
            formatElapsed(0),
            role: .mono, weight: .medium, tier: .base,
            color: elapsedColor(0)
        )
        timeLabel.alignment = .right
        // 56pt comfortably fits "59m59s" in 12pt mono.
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        elapsedLabels.append(ElapsedLabel(label: timeLabel, startTime: shownAt))
        return timeLabel
    }

    private func buildEntryView(_ entry: ProcessEntry) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        // Three structured lead lines.
        let terminalRow = makeTerminalRow(entry)
        stack.addArrangedSubview(terminalRow)
        // Pin the terminal row to the stack's full width so its trailing
        // shortcuts/timer cluster can right-align. Other rows keep their
        // natural intrinsic width (default .leading alignment).
        terminalRow.translatesAutoresizingMaskIntoConstraints = false
        terminalRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        terminalRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        let bodyTable = makeBodyTable(entry)
        stack.addArrangedSubview(bodyTable)
        // Sit the table directly under the terminal row — no blank gap.
        stack.setCustomSpacing(0, after: terminalRow)

        // Technical detail block: hidden by default. Toggled by a small
        // disclosure button so a curious user can drop down chain/pid/argv.
        let detailsContainer = NSStackView()
        detailsContainer.orientation = .vertical
        detailsContainer.alignment = .leading
        detailsContainer.spacing = 2
        detailsContainer.isHidden = true
        detailsContainer.addArrangedSubview(makeProcessTreeLabel(entry))
        // Blank spacer line between the tree and the YAML block.
        detailsContainer.addArrangedSubview(makeDimDetailLabel(" "))
        for line in detailsYAMLLines(entry: entry) {
            detailsContainer.addArrangedSubview(makeDimDetailLabel(line))
        }

        let toggle = DetailsToggleButton(detailContainer: detailsContainer)
        toggle.title = "▸ details"
        toggle.isBordered = false
        toggle.font = NSFont.systemFont(ofSize: 11)
        toggle.contentTintColor = .tertiaryLabelColor
        toggle.target = self
        toggle.action = #selector(toggleDetails(_:))
        stack.addArrangedSubview(toggle)
        stack.addArrangedSubview(detailsContainer)

        // Action buttons
        if let tty = entry.tty {
            let buttonStack = NSStackView()
            buttonStack.orientation = .horizontal
            buttonStack.spacing = 8

            let showBtn = NSButton(title: "Show Tab", target: nil, action: nil)
            showBtn.bezelStyle = .recessed
            showBtn.font = NSFont.systemFont(ofSize: 11)
            showBtn.target = self
            showBtn.action = #selector(showTerminalTab(_:))
            showBtn.cell?.representedObject = [tty, entry.terminalBundleID as Any]
            buttonStack.addArrangedSubview(showBtn)

            let msgBtn = NSButton(title: "Send Message", target: nil, action: nil)
            msgBtn.bezelStyle = .recessed
            msgBtn.font = NSFont.systemFont(ofSize: 11)
            msgBtn.target = self
            msgBtn.action = #selector(sendTTYMessage(_:))
            msgBtn.cell?.representedObject = tty
            buttonStack.addArrangedSubview(msgBtn)

            stack.addArrangedSubview(buttonStack)
        }

        return stack
    }

    // MARK: - Body table

    /// Render the ordered `bodyRows` as an aligned two-column grid: dim labels
    /// in a fixed first column, values in the second. The action row spans with
    /// no label; the "asked" row wraps.
    ///
    /// Internal (not private) so a regression test can exercise the AppKit
    /// grid construction directly — an earlier version indexed `column(at: 0)`
    /// on an empty `NSGridView`, which throws NSRangeException at runtime.
    func makeBodyTable(_ entry: ProcessEntry) -> NSView {
        let rows = bodyRows(entry: entry, dense: densePopup)
        // Build the whole cell matrix up front and hand it to
        // NSGridView(views:), which creates the rows AND columns in one shot.
        // A bare `NSGridView()` has zero columns until a row is added, so
        // touching `column(at: 0)` before that throws NSRangeException.
        let cells: [[NSView]] = rows.map { row in
            [
                makeLabel(
                    row.label ?? "", role: .mono, weight: .regular, tier: .small,
                    color: style.color(.dimLabel)
                ),
                makeBodyValueLabel(row),
            ]
        }
        let grid = NSGridView(views: cells)
        grid.rowSpacing = 3
        grid.columnSpacing = 10
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .leading
        }
        return grid
    }

    private func makeBodyValueLabel(_ row: BodyRow) -> NSTextField {
        let color: NSColor
        let weight: NSFont.Weight
        switch row.style {
        case .action(let kind): color = bodyActionColor(kind); weight = .semibold
        case .who(let kind):    color = bodyWhoColor(kind);    weight = .semibold
        case .field(let field): color = bodyFieldColor(field);   weight = .regular
        case .asked:            color = style.color(.dimLabel);    weight = .regular
        }
        let label = makeLabel(row.value, role: .ui, weight: weight, tier: .base, color: color)
        if case .asked = row.style {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            label.cell?.wraps = true
            label.preferredMaxLayoutWidth = promptMaxLayoutWidth()
        } else {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func bodyActionColor(_ kind: RequestKind) -> NSColor {
        switch kind {
        case .onePasswordCLI: return style.color(.verifiedOp)
        case .unverifiedOp:   return style.color(.unverifiedOp)
        case .ssh:            return style.color(.ssh)
        case .unknown:        return style.color(.brightValue)
        }
    }

    private func bodyFieldColor(_ field: FieldColor) -> NSColor {
        switch field {
        case .gitRoot:  return style.color(.gitRoot)
        case .branch:   return style.color(.branch)
        case .worktree: return style.color(.worktree)
        case .plain:    return style.color(.brightValue)
        }
    }

    private func bodyWhoColor(_ kind: DriverKind) -> NSColor {
        switch kind {
        case .claude: return style.color(.claude)
        case .editor: return style.color(.editor)
        case .shell, .other: return style.color(.brightValue)
        }
    }

    // MARK: - Lead rows (icon + text)

    /// Row 1: terminal app icon + workspace/tab name + trailing elapsed time.
    ///
    /// Prefer cmux's live tree (workspace title + surface title) when we have
    /// it — those names are user-renameable and the env vars don't update.
    /// Fall back to NSAccessibility-derived tabTitle for non-cmux terminals.
    private func makeTerminalRow(_ entry: ProcessEntry) -> NSView {
        let bundleID = entry.terminalBundleID
        let termName = humanTerminalName(bundleID: bundleID) ?? "Unknown terminal"
        let parts = Self.terminalRowParts(entry: entry, termName: termName)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        // Leading icon (or 16pt spacer for alignment).
        let leadingDim: CGFloat = 16
        if let icon = appIcon(bundleID: bundleID) {
            let iv = NSImageView()
            iv.image = icon
            iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: leadingDim).isActive = true
            iv.heightAnchor.constraint(equalToConstant: leadingDim).isActive = true
            row.addArrangedSubview(iv)
        } else {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: leadingDim).isActive = true
            spacer.heightAnchor.constraint(equalToConstant: leadingDim).isActive = true
            row.addArrangedSubview(spacer)
        }

        // Main title label: user-visible title (bright) + terminal qualifier (dim).
        // Workspace/tab name leads because it's what the user actually recognizes;
        // the terminal name trails as a subdued qualifier. Stretches to fill
        // remaining horizontal space so trailing shortcuts and timer can right-align.
        let label = makeLabel("", role: .ui, weight: .semibold, tier: .large, color: .labelColor)
        let mainFont = style.font(.ui, weight: .semibold, tier: .large)
        let dim = NSColor.secondaryLabelColor
        let bright = NSColor.labelColor
        let attr = NSMutableAttributedString()
        if !parts.title.isEmpty {
            attr.append(NSAttributedString(
                string: parts.title,
                attributes: [.font: mainFont, .foregroundColor: bright]
            ))
        }
        attr.append(NSAttributedString(
            string: parts.qualifier,
            attributes: [.font: mainFont, .foregroundColor: dim]
        ))
        label.attributedStringValue = attr
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // Low hugging = absorbs extra width (pushes trailing items right).
        // Low compression resistance = truncates first when space is tight.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)

        // Trailing shortcuts label: cmux's ⌘N/⌃M (from suffix) and/or iTerm's
        // tab navigation hint (from shortcut). Right-aligned at content size.
        // The elapsed timer now lives in the top-right header corner, not here.
        let shortcutsText = composeShortcuts(suffix: parts.suffix, shortcut: parts.shortcut)
        if !shortcutsText.isEmpty {
            let sl = makeLabel(
                shortcutsText,
                role: .mono, weight: .medium, tier: .base, color: dim
            )
            sl.alignment = .right
            sl.setContentHuggingPriority(.required, for: .horizontal)
            sl.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(sl)
        }

        return row
    }

    /// Decomposition of row 1 for styled rendering. `title` is rendered first
    /// in a brighter color so the user-visible workspace/tab name leads;
    /// `qualifier` trails in a dim color as a terminal-app annotation.
    struct TerminalRowParts: Equatable {
        /// User-visible title (e.g. "trusthere", "1. zsh — work"), rendered
        /// first in the bright color. Empty when no title is available, in
        /// which case `qualifier` is the bare terminal name.
        let title: String
        /// Dim qualifier rendered after the title. When `title` is non-empty
        /// this is something like " · cmux" or " · iTerm" (separator + term
        /// name). When `title` is empty this is just the bare terminal name
        /// with no leading separator.
        let qualifier: String
        /// Trailing keyboard-shortcut text (cmux's " ⌘N ⌃M"). Goes into the
        /// separate trailing shortcuts label, not the main title attributed
        /// string. May be empty.
        let suffix: String
        /// Legacy iTerm shortcut hint (e.g. "⌘3", "window 2 ⌘1"). nil when
        /// not applicable. Also goes into the trailing shortcuts label.
        let shortcut: String?

        /// Backward-compatible flat-string composition used by tests/logging.
        var main: String { title + qualifier + suffix }
    }

    /// Build the parts of row 1.
    static func terminalRowParts(entry: ProcessEntry, termName: String) -> TerminalRowParts {
        if let s = entry.cmuxSurface {
            // For cmux we deliberately skip the surface (tab) title: it's
            // typically a duplicate of the workspace title (the CWD), and
            // the user can navigate to the right tab with the ⌃N shortcut.
            let wsTitle = s.displayWorkspaceTitle
            let wsKey = s.workspaceIndex > 0 ? " ⌘\(s.workspaceIndex)" : ""
            // ⌃N is only useful when the user has more than one tab to switch
            // between — otherwise ⌃1 is trivial. Keep showing it when the
            // tab count is unknown (0) so stale state doesn't drop info.
            let showTabKey = s.tabIndex > 0 && s.workspaceTabCount != 1
            let tabKey = showTabKey ? " ⌃\(s.tabIndex)" : ""

            if !wsTitle.isEmpty {
                return TerminalRowParts(
                    title: wsTitle,
                    qualifier: " · \(termName)",
                    suffix: "\(wsKey)\(tabKey)",
                    shortcut: nil
                )
            }
            if !wsKey.isEmpty || !tabKey.isEmpty {
                return TerminalRowParts(
                    title: "", qualifier: termName, suffix: "\(wsKey)\(tabKey)", shortcut: nil
                )
            }
            return TerminalRowParts(title: "", qualifier: termName, suffix: "", shortcut: nil)
        }
        // For cmux without surface info, AX window title is unreliable
        // (returns "Item-0" placeholders rather than the visible workspace
        // name). Show only the terminal name.
        if isCmuxBundleID(entry.terminalBundleID) {
            return TerminalRowParts(title: "", qualifier: termName, suffix: "", shortcut: nil)
        }
        let title = entry.tabTitle?.trimmingCharacters(in: .whitespaces) ?? ""
        let shortcut = entry.tabShortcut?.trimmingCharacters(in: .whitespaces)
        let shortcutOrNil = (shortcut?.isEmpty ?? true) ? nil : shortcut
        if !title.isEmpty {
            return TerminalRowParts(
                title: title, qualifier: " · \(termName)", suffix: "", shortcut: shortcutOrNil
            )
        }
        return TerminalRowParts(title: "", qualifier: termName, suffix: "", shortcut: shortcutOrNil)
    }

    /// Flat-string composition of row 1. Kept for callers (tests, logging)
    /// that don't need the styled rendering — the UI uses `terminalRowParts`.
    static func terminalRowText(entry: ProcessEntry, termName: String) -> String {
        let p = terminalRowParts(entry: entry, termName: termName)
        if let s = p.shortcut { return "\(p.main) \(s)" }
        return p.main
    }

    private func makeLabel(
        _ text: String,
        role: FontRole,
        weight: NSFont.Weight,
        tier: FontTier,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = style.font(role, weight: weight, tier: tier)
        label.textColor = color
        label.isSelectable = true
        return label
    }

    /// Small grey monospaced label for an auxiliary detail row.
    private func makeDimDetailLabel(_ text: String) -> NSTextField {
        let label = makeLabel(text, role: .mono, weight: .regular, tier: .small, color: .secondaryLabelColor)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// Render the parent-first process tree as a single monospaced label with
    /// `└─` connectors and PIDs in parens. The `op` node is colored.
    private func makeProcessTreeLabel(_ entry: ProcessEntry) -> NSTextField {
        let appName = humanTerminalName(bundleID: entry.terminalBundleID)
        let nodes = processTreeNodes(
            appName: appName, appPID: entry.terminalPID, chain: entry.chain
        )
        let font = style.font(.mono, weight: .regular, tier: .small)
        let out = NSMutableAttributedString()
        for (i, node) in nodes.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let indent = node.depth == 0
                ? ""
                : String(repeating: "   ", count: node.depth - 1) + "\u{2514}\u{2500} "
            let color: NSColor
            switch node.opColor {
            case .verified:   color = style.color(.verifiedOp)
            case .unverified: color = style.color(.unverifiedOp)
            case .none:       color = style.color(.dimLabel)
            }
            out.append(NSAttributedString(
                string: "\(indent)\(node.name) (\(node.pid))",
                attributes: [.font: font, .foregroundColor: color]
            ))
        }
        let label = NSTextField(labelWithAttributedString: out)
        label.isSelectable = true
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 0
        return label
    }

    // MARK: - Actions

    @objc private func showTerminalTab(_ sender: NSButton) {
        guard let info = sender.cell?.representedObject as? [Any],
              let tty = info[0] as? String else { return }
        let bid = info[1] as? String
        TerminalHelper.activateTab(forTTY: tty, terminalBundleID: bid)
    }

    @objc private func sendTTYMessage(_ sender: NSButton) {
        guard let tty = sender.cell?.representedObject as? String else { return }
        TerminalHelper.writeMessage(to: tty, message: "\n[op-who] 1Password approval requested from this session\n")
    }

    // MARK: - Color & icon

    /// Compose the shortcuts label content from `parts.suffix` (cmux's
    /// " ⌘N ⌃M") and `parts.shortcut` (iTerm's "⌘3" or "window 2 ⌘1").
    /// Both forms are joined with a space and stripped of leading whitespace.
    private func composeShortcuts(suffix: String, shortcut: String?) -> String {
        var s = suffix.trimmingCharacters(in: .whitespaces)
        if let extra = shortcut, !extra.isEmpty {
            if !s.isEmpty { s += " " }
            s += extra
        }
        return s
    }

    /// Target max width for the wrapping prompt label: 40% of the main
    /// screen, minus the panel's outer padding (~32) and the stack's edge
    /// insets (~32). Floored to a usable minimum so tiny screens don't make
    /// the popup unreadable.
    private func promptMaxLayoutWidth() -> CGFloat {
        let screenW = NSScreen.main?.frame.width ?? 1440
        return max(300, screenW * 0.4 - 64)
    }

    /// Fetch the terminal app's icon via NSWorkspace, cached per bundle ID.
    private func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID = bundleID else { return nil }
        if let cached = Self.iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        Self.iconCache[bundleID] = image
        return image
    }

    private static var iconCache: [String: NSImage] = [:]

    // MARK: - Disclosure toggle

    @objc private func toggleDetails(_ sender: DetailsToggleButton) {
        guard let container = sender.detailContainer else { return }
        let willShow = container.isHidden
        container.isHidden = !willShow
        sender.title = willShow ? "▾ details" : "▸ details"
        resizePanelToFit()
    }

    /// Re-fit the panel after expanding/collapsing a details block. We anchor
    /// the panel's top edge so the lead rows stay put visually and the panel
    /// grows downward as new rows appear.
    private func resizePanelToFit() {
        guard let panel = panel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let newWidth = max(fitting.width + 32, 320)
        let newHeight = fitting.height + 24
        let currentFrame = panel.frame
        // Anchor top: top-Y stays constant, height changes, origin.y adjusts.
        let topY = currentFrame.origin.y + currentFrame.height
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: topY - newHeight,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true, animate: false)
    }
}

/// NSButton subclass with an associated detail container — used by the
/// "▸ details" disclosure toggle so the action handler can find what to
/// show/hide without maintaining a side table.
private class DetailsToggleButton: NSButton {
    weak var detailContainer: NSStackView?
    init(detailContainer: NSStackView) {
        self.detailContainer = detailContainer
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}

/// One trailing time label for a single entry. The OverlayPanel ticks them
/// all together once per second.
private struct ElapsedLabel {
    let label: NSTextField
    let startTime: Date
}

/// "49s" for under a minute, "1m12s" otherwise. Floors to whole seconds.
func formatElapsed(_ secs: TimeInterval) -> String {
    let total = max(0, Int(secs))
    if total < 60 { return "\(total)s" }
    let m = total / 60
    let s = total % 60
    return "\(m)m\(s)s"
}

/// 0-9s: secondary label. 10-29s: warning orange. 30s+: error red.
func elapsedColor(_ secs: TimeInterval) -> NSColor {
    if secs < 10 { return .secondaryLabelColor }
    if secs < 30 { return .systemOrange }
    return .systemRed
}
