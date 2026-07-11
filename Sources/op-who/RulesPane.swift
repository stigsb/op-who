import AppKit
import OpWhoLib

/// Unified rules section inside the Settings window. Master/detail editor
/// for every rule the engine evaluates — user-authored rules at the top
/// (they run first via `RequestRuleStore.allRules`), followed by the
/// built-ins shipped with op-who. Each row has an Enabled checkbox:
///   - User rules: flips `rule.enabled` on the stored rule.
///   - Built-ins: toggles `disabledBuiltInIDs` membership.
/// Built-in rows render with a read-only detail form; users clone them
/// (via the + menu's "Clone Selected Rule" item) to customize.
///
/// `presenter` is a weak reference to the window that should own any
/// modal sheet this pane opens. The host sets it after the window exists.
final class RulesPane: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let store: RequestRuleStore
    private let recentStore: RecentRequestsStore
    weak var presenter: NSWindow?

    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    /// Drag-handle below the rule list. Lets the user trade height
    /// between the table (more rules visible) and the detail editor
    /// (more room for long predicate / template / comment).
    private let tableResizeGrip = ResizeGripView()
    /// Height of the rule-list scroll view. Held as a stored constraint
    /// so the resize grip can mutate it.
    private var tableScrollHeight: NSLayoutConstraint!
    /// Minimum height for the rule-list scroll view in points. Floor is
    /// roughly 3 visible rows so the user can still see what they're
    /// selecting.
    private let tableMinHeight: CGFloat = 96
    private var selectedRuleID: UUID? = nil
    private var addSheet: AddRuleSheetController?
    private var testSheet: TestPredicateSheetController?

    // Detail form controls.
    private let nameField = NSTextField()
    /// NSPredicate-format text view. Multi-line because real-world rule
    /// predicates with IN-sets and AND-chains spill past one line fast.
    /// The subclass extends `rangeForUserCompletion` so dotted keypaths
    /// (e.g. `triggerArgv.@count`) complete as one word.
    private let predicateView = PredicateTextView()
    /// Drag-handle below the predicate field. Dragging it changes the
    /// scroll view's height so long predicates have room without taking
    /// permanent vertical real estate from the rest of the editor.
    private let predicateResizeGrip = ResizeGripView()
    /// Height of the predicate scroll view. Held as a stored constraint
    /// so the resize grip can mutate it.
    private var predicateScrollHeight: NSLayoutConstraint!
    /// Minimum height for the predicate scroll view in points. Keeps a
    /// one-line predicate readable; the user can drag the grip up
    /// against this floor but not past it.
    private let predicateMinHeight: CGFloat = 36
    /// Set while `loadDetailFromSelection` is writing the predicate field
    /// programmatically, so the textDidChange notification doesn't
    /// auto-trigger the completion popup on a load.
    private var isLoadingDetail = false
    /// Length of `predicateView.string` after the last edit, in UTF-16
    /// units. Used to distinguish insertions (length grew → consider
    /// triggering completion) from deletions (length shrank → leave the
    /// user alone so backspacing doesn't re-popup endlessly).
    private var previousPredicateLength = 0
    /// Defers updates to the inline predicate-error label until the user
    /// pauses typing. NSPredicate's parser is whole-or-nothing, so every
    /// intermediate keystroke (e.g. `triggerName ==`) is "invalid";
    /// publishing the label on every change would flash red constantly.
    /// 350ms matches the comfort zone used by typical LSP diagnostic
    /// debouncing.
    private let predicateErrorDebouncer = Debouncer(interval: 0.35)
    private let predicateScroll = NSScrollView()
    /// Inline error display under the predicate field. Shows the
    /// NSPredicate parser's reason text when the current input fails to
    /// parse; empty (and hidden) when the predicate is valid.
    private let predicateError = NSTextField(labelWithString: "")
    private let templateField = NSTextField()
    private let commentView = NSTextView()
    private let commentScroll = NSScrollView()
    /// Live example of what the current draft rule would render in the
    /// overlay. Re-sampled from `recentStore` on every debounced refresh
    /// so the user sees the template applied to varied real captures
    /// rather than a single canned example.
    private let templatePreview = NSTextField(labelWithString: "")
    private let replacesActorCheckbox = NSButton(checkboxWithTitle: "Replaces actor (full title)", target: nil, action: nil)
    /// `info.circle` next to the "Replaces actor" checkbox. Hover reveals
    /// the actor concept — the only place this jargon is explained in the
    /// UI.
    private let replacesActorInfo = NSImageView()
    private let isWarningCheckbox = NSButton(checkboxWithTitle: "Render as warning", target: nil, action: nil)
    private let kindPopup = NSPopUpButton()
    private let detailBox = NSBox()
    private let builtInNotice = NSTextField(
        labelWithString: "Built-in rule — read-only. Use “+ → Clone Selected Rule” to make an editable copy."
    )
    private let predicateHighlighter = PredicateHighlighter(knownKeys: PredicateContext.exposedKeys)

    /// Editable detail controls, gathered once so we can flip them all to
    /// disabled (read-only) when a built-in is selected. The predicate
    /// and comment text views aren't NSControls, so they're toggled
    /// separately in `setEditable`.
    private var editableControls: [NSControl] {
        [nameField, templateField, kindPopup, replacesActorCheckbox, isWarningCheckbox]
    }

    private(set) lazy var view: NSView = makeContentView()

    init(store: RequestRuleStore, recentStore: RecentRequestsStore) {
        self.store = store
        self.recentStore = recentStore
        super.init()
        _ = view // force-build so initial selection takes effect
        reloadTable()
        // Select first row (which will be the first user rule if any,
        // otherwise the first built-in).
        let rules = store.allRules
        if !rules.isEmpty {
            selectedRuleID = rules[0].id
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        loadDetailFromSelection()
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let container = NSView()

        let header = NSTextField(labelWithString: "Rules")
        header.font = NSFont.boldSystemFont(ofSize: 13)

        let subhead = NSTextField(labelWithString:
            "User-authored rules at the top run first; built-ins follow. " +
            "Each rule's matcher is evaluated against the trigger process, its argv, and its cwd; first enabled match wins. " +
            "Toggle the Enabled checkbox to skip a rule without removing it."
        )
        subhead.font = NSFont.systemFont(ofSize: 11)
        subhead.textColor = .secondaryLabelColor
        subhead.lineBreakMode = .byWordWrapping
        subhead.maximumNumberOfLines = 3

        configureTableScroll()
        let buttonBar = makeButtonBar()
        let detail = makeDetailForm()

        tableResizeGrip.onDragDelta = { [weak self] delta in
            guard let self = self else { return }
            let proposed = self.tableScrollHeight.constant + delta
            self.tableScrollHeight.constant = max(self.tableMinHeight, proposed)
        }

        for v in [header, subhead, tableScroll, tableResizeGrip, buttonBar, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }

        let padding: CGFloat = 16
        let spacing: CGFloat = 10
        tableScrollHeight = tableScroll.heightAnchor.constraint(equalToConstant: 260)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            subhead.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            subhead.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            tableScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            tableScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            tableResizeGrip.leadingAnchor.constraint(equalTo: tableScroll.leadingAnchor),
            tableResizeGrip.trailingAnchor.constraint(equalTo: tableScroll.trailingAnchor),
            buttonBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            buttonBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            detail.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            detail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            subhead.topAnchor.constraint(equalTo: header.bottomAnchor, constant: spacing),
            tableScroll.topAnchor.constraint(equalTo: subhead.bottomAnchor, constant: spacing),
            tableResizeGrip.topAnchor.constraint(equalTo: tableScroll.bottomAnchor),
            buttonBar.topAnchor.constraint(equalTo: tableResizeGrip.bottomAnchor, constant: spacing),
            detail.topAnchor.constraint(equalTo: buttonBar.bottomAnchor, constant: spacing),
            detail.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            tableScrollHeight,
        ])
        return container
    }

    private func configureTableScroll() {
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let enabledCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        enabledCol.title = ""
        enabledCol.width = 24
        enabledCol.minWidth = 24
        enabledCol.maxWidth = 30
        tableView.addTableColumn(enabledCol)

        let originCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("origin"))
        originCol.title = ""
        originCol.width = 70
        originCol.minWidth = 60
        originCol.maxWidth = 80
        tableView.addTableColumn(originCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 200
        tableView.addTableColumn(nameCol)

        let whenCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("when"))
        whenCol.title = "When"
        whenCol.width = 260
        tableView.addTableColumn(whenCol)

        let thenCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("then"))
        thenCol.title = "Then"
        thenCol.width = 260
        tableView.addTableColumn(thenCol)

        tableScroll.documentView = tableView
    }

    private func makeButtonBar() -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8

        // "+ with options": a plain NSButton that pops up a menu on
        // click. Tried NSPopUpButton in pull-down mode first but it
        // renders the first item's title (or "NSMenuItem" if empty)
        // alongside the chevron, which clutters a button that should
        // just read as "+". popUp(positioning:at:in:) gives the same
        // affordance with a cleaner face.
        let plusButton = ToolbarButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add rule")!,
            target: self,
            action: #selector(showAddMenu(_:))
        )
        plusButton.bezelStyle = .smallSquare
        plusButton.setContentHuggingPriority(.required, for: .horizontal)
        bar.addArrangedSubview(plusButton)

        let removeButton = ToolbarButton(
            image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove selected user rule")!,
            target: self,
            action: #selector(removeSelected(_:))
        )
        removeButton.bezelStyle = .smallSquare
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        bar.addArrangedSubview(removeButton)

        let upDown = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Move up")!,
                NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Move down")!,
            ],
            trackingMode: .momentary,
            target: self,
            action: #selector(moveAction(_:))
        )
        upDown.segmentStyle = .smallSquare
        bar.addArrangedSubview(upDown)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)

        let reset = NSButton(title: "Remove All User Rules", target: self, action: #selector(resetAction(_:)))
        bar.addArrangedSubview(reset)

        return bar
    }

    private func makeDetailForm() -> NSView {
        detailBox.title = "Selected rule"
        detailBox.titleFont = NSFont.systemFont(ofSize: 11)

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 8

        configureField(nameField, placeholder: "Display name")
        configureField(templateField, placeholder: "Template — {process}, {subcommand}, {argv}, {cwd}, {op_uri}, {op_phrase}, {plugin_remote}, {repo}, {source}, {marketplace}, {argv[N]}")

        kindPopup.addItems(withTitles: [
            RequestKind.onePasswordCLI.rawValue,
            RequestKind.unverifiedOp.rawValue,
            RequestKind.ssh.rawValue,
            RequestKind.unknown.rawValue,
        ])
        kindPopup.target = self
        kindPopup.action = #selector(detailChanged(_:))

        replacesActorCheckbox.target = self
        replacesActorCheckbox.action = #selector(detailChanged(_:))
        isWarningCheckbox.target = self
        isWarningCheckbox.action = #selector(detailChanged(_:))

        configurePredicateView()
        configureCommentView()

        predicateError.font = NSFont.systemFont(ofSize: 11)
        predicateError.textColor = .systemRed
        predicateError.lineBreakMode = .byWordWrapping
        predicateError.maximumNumberOfLines = 3
        predicateError.preferredMaxLayoutWidth = 560
        predicateError.isHidden = true

        templatePreview.font = NSFont.systemFont(ofSize: 11)
        templatePreview.textColor = .secondaryLabelColor
        templatePreview.lineBreakMode = .byWordWrapping
        templatePreview.maximumNumberOfLines = 2
        templatePreview.preferredMaxLayoutWidth = 560
        templatePreview.toolTip = "Sample rendered title using a random captured request. Re-samples while you edit."

        configureReplacesActorInfo()

        builtInNotice.font = NSFont.systemFont(ofSize: 11)
        builtInNotice.textColor = .secondaryLabelColor
        builtInNotice.isHidden = true

        grid.addRow(with: [label("Name"), nameField])
        grid.addRow(with: [label("Predicate"), makePredicateEditorRow()])
        grid.addRow(with: [NSView(), predicateError])
        grid.addRow(with: [label("Template"), templateField])
        grid.addRow(with: [label("Preview"), templatePreview])
        grid.addRow(with: [label("Comment"), commentScroll])
        grid.addRow(with: [label("Kind"), kindPopup])
        grid.addRow(with: [NSView(), makeReplacesActorRow()])
        grid.addRow(with: [NSView(), isWarningCheckbox])
        grid.addRow(with: [NSView(), builtInNotice])

        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).width = 140
        grid.column(at: 1).xPlacement = .fill

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        detailBox.contentView = content
        return detailBox
    }

    /// Stack the predicate scroll view alongside a "Test" button so the
    /// row reads as one editor unit. The button stays right of the
    /// scroll so its position doesn't shift when the text view's height
    /// changes (it doesn't today, but the layout is forgiving).
    /// Pack the "Replaces actor" checkbox alongside the info button so
    /// they read as one unit, with the info hugging the checkbox's
    /// trailing edge.
    private func makeReplacesActorRow() -> NSView {
        let row = NSStackView(views: [replacesActorCheckbox, replacesActorInfo])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func configureReplacesActorInfo() {
        let symbol = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About the actor")
        replacesActorInfo.image = symbol
        replacesActorInfo.contentTintColor = .secondaryLabelColor
        replacesActorInfo.translatesAutoresizingMaskIntoConstraints = false
        replacesActorInfo.widthAnchor.constraint(equalToConstant: 14).isActive = true
        replacesActorInfo.heightAnchor.constraint(equalToConstant: 14).isActive = true
        // Multi-line tooltip — AppKit wraps on \n. Explains the actor
        // concept once, here, since this is the only UI element that
        // uses the term.
        replacesActorInfo.toolTip = """
            An "actor" is the auto-computed prefix op-who puts in front of \
            a rule's template — e.g. "Claude Code session 'foo'", \
            "iTerm tab 'work'", or "Your zsh shell". It identifies WHO \
            triggered the request, derived from the process chain, terminal, \
            and any detected Claude Code session.

            The template is the verb phrase that follows the actor \
            (e.g. "is signing a commit").

            Check this box if your template names its own subject and the \
            actor prefix would just be noise.
            """
    }

    private func makePredicateEditorRow() -> NSView {
        // Editor column: predicate scroll on top, drag grip directly
        // below. The grip spans the same width so the user can drag from
        // anywhere along the bottom edge.
        let editorColumn = NSStackView(views: [predicateScroll, predicateResizeGrip])
        editorColumn.orientation = .vertical
        editorColumn.alignment = .leading
        editorColumn.spacing = 0
        editorColumn.translatesAutoresizingMaskIntoConstraints = false
        predicateResizeGrip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            predicateResizeGrip.leadingAnchor.constraint(equalTo: editorColumn.leadingAnchor),
            predicateResizeGrip.trailingAnchor.constraint(equalTo: predicateScroll.trailingAnchor),
        ])

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(editorColumn)

        let testButton = NSButton(title: "Test…", target: self, action: #selector(testPredicate(_:)))
        testButton.toolTip = "Evaluate this predicate against every record in the recent-requests ring buffer"
        testButton.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(testButton)
        return row
    }

    private func configurePredicateView() {
        predicateView.delegate = self
        predicateView.isRichText = false
        predicateView.allowsUndo = true
        predicateView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        predicateView.textContainerInset = NSSize(width: 4, height: 4)
        // Disable AppKit's "smart" text features — they'd helpfully turn
        // straight quotes into curly ones, which NSPredicate's parser
        // then rejects.
        predicateView.isAutomaticQuoteSubstitutionEnabled = false
        predicateView.isAutomaticDashSubstitutionEnabled = false
        predicateView.isAutomaticTextReplacementEnabled = false
        predicateView.isAutomaticSpellingCorrectionEnabled = false
        predicateScroll.borderType = .bezelBorder
        predicateScroll.hasVerticalScroller = true
        predicateScroll.documentView = predicateView
        predicateScroll.translatesAutoresizingMaskIntoConstraints = false
        predicateScrollHeight = predicateScroll.heightAnchor.constraint(equalToConstant: 72)
        predicateScrollHeight.isActive = true
        predicateScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true

        predicateResizeGrip.onDragDelta = { [weak self] delta in
            guard let self = self else { return }
            // NSEvent.deltaY for mouse-tracking events is in *screen*
            // coordinates — down is positive — regardless of the view's
            // flipped-ness. Add the delta so dragging down grows the
            // field. Clamp at `predicateMinHeight` so the editor never
            // collapses to a zero-row sliver.
            let proposed = self.predicateScrollHeight.constant + delta
            self.predicateScrollHeight.constant = max(self.predicateMinHeight, proposed)
        }

        // Install the syntax highlighter on the text storage. The
        // highlighter watches edits and re-applies foreground colours
        // (plus an orange underline for unknown keypaths) on every
        // change.
        predicateHighlighter.install(on: predicateView)
    }

    private func configureCommentView() {
        commentView.delegate = self
        commentView.isRichText = false
        commentView.allowsUndo = true
        commentView.font = NSFont.systemFont(ofSize: 12)
        commentView.textContainerInset = NSSize(width: 4, height: 4)
        commentScroll.borderType = .bezelBorder
        commentScroll.hasVerticalScroller = true
        commentScroll.documentView = commentView
        commentScroll.translatesAutoresizingMaskIntoConstraints = false
        commentScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        commentScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
    }

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(detailChanged(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.alignment = .left
        return l
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { store.allRules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        let rules = store.allRules
        guard row < rules.count else { return nil }
        let rule = rules[row]

        switch col.identifier.rawValue {
        case "enabled":
            let id = NSUserInterfaceItemIdentifier("cell_enabled")
            let cell: EnabledCheckboxCell
            if let existing = tableView.makeView(withIdentifier: id, owner: self) as? EnabledCheckboxCell {
                cell = existing
            } else {
                cell = EnabledCheckboxCell()
                cell.identifier = id
            }
            cell.configure(ruleID: rule.id, enabled: rule.enabled) { [weak self] ruleID, newValue in
                self?.store.setRuleEnabled(id: ruleID, enabled: newValue)
                self?.reloadTable()
            }
            return cell
        default:
            let id = NSUserInterfaceItemIdentifier("cell_\(col.identifier.rawValue)")
            let cell: NSTableCellView = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCellView(id: id)
            switch col.identifier.rawValue {
            case "origin":
                cell.textField?.stringValue = (rule.builtInID == nil) ? "User" : "Built-in"
                cell.textField?.font = NSFont.systemFont(ofSize: 11)
                cell.textField?.textColor = (rule.builtInID == nil) ? .labelColor : .secondaryLabelColor
            case "name":
                cell.textField?.stringValue = rule.name
                cell.textField?.textColor = rule.enabled ? .labelColor : .disabledControlTextColor
            case "when":
                cell.textField?.stringValue = rule.predicate
                cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                cell.textField?.textColor = rule.enabled ? .labelColor : .disabledControlTextColor
            case "then":
                cell.textField?.stringValue = rule.template
                cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                cell.textField?.textColor = rule.enabled ? .labelColor : .disabledControlTextColor
            default: break
            }
            return cell
        }
    }

    private func makeCellView(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        cell.addSubview(tf)
        cell.textField = tf
        cell.identifier = id
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        let rules = store.allRules
        if row >= 0 && row < rules.count {
            selectedRuleID = rules[row].id
        } else {
            selectedRuleID = nil
        }
        loadDetailFromSelection()
    }

    // MARK: - Actions

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let blank = NSMenuItem(title: "Blank Rule", action: #selector(addBlank(_:)), keyEquivalent: "")
        blank.target = self
        menu.addItem(blank)
        let fromRecent = NSMenuItem(title: "From Recent Request…", action: #selector(addFromRecent(_:)), keyEquivalent: "")
        fromRecent.target = self
        fromRecent.isEnabled = !recentStore.requests.isEmpty
        menu.addItem(fromRecent)
        let clone = NSMenuItem(title: "Clone Selected Rule", action: #selector(addClone(_:)), keyEquivalent: "")
        clone.target = self
        clone.isEnabled = (selectedRuleID != nil)
        menu.addItem(clone)
        // Show the menu just below the button, matching the way
        // pull-down toolbar pickers anchor in Finder / Mail.
        let origin = NSPoint(x: 0, y: sender.bounds.maxY + 2)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func addBlank(_ sender: Any?) {
        insertUserRule(emptyTemplateRule())
    }

    @objc private func addFromRecent(_ sender: Any?) {
        let recents = recentStore.requests.reversed()
        guard !recents.isEmpty else {
            insertUserRule(emptyTemplateRule())
            return
        }
        let sheet = AddRuleSheetController(recents: Array(recents)) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .none: break
            case .some(.empty): self.insertUserRule(self.emptyTemplateRule())
            case .some(.fromRecent(let recent)):
                self.insertUserRule(self.ruleFromRecent(recent))
            }
            self.addSheet = nil
        }
        addSheet = sheet
        if let host = presenter, let sheetWindow = sheet.window {
            host.beginSheet(sheetWindow, completionHandler: nil)
        }
    }

    @objc private func addClone(_ sender: Any?) {
        guard let id = selectedRuleID,
              let source = store.allRules.first(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        // Strip the built-in identity from the clone so it lives as a
        // standalone user rule. Fresh UUID, "Copy of …" name, enabled by
        // default regardless of the source's enabled state.
        let clone = RequestRule(
            id: UUID(),
            name: "Copy of \(source.name)",
            predicate: source.predicate,
            template: source.template,
            replacesActor: source.replacesActor,
            kind: source.kind,
            isWarning: source.isWarning,
            comment: source.comment,
            enabled: true,
            builtInID: nil
        )
        insertUserRule(clone)
    }

    @objc private func removeSelected(_ sender: Any?) {
        guard let id = selectedRuleID,
              let idx = store.userRules.firstIndex(where: { $0.id == id }) else {
            // Built-in selected — removing isn't allowed; flash with a beep.
            NSSound.beep()
            return
        }
        var rules = store.userRules
        rules.remove(at: idx)
        store.setUserRules(rules)
        reloadTable()
        let allRules = store.allRules
        if !allRules.isEmpty {
            let nextIdx = min(idx, allRules.count - 1)
            selectedRuleID = allRules[nextIdx].id
            tableView.selectRowIndexes(IndexSet(integer: nextIdx), byExtendingSelection: false)
        } else {
            selectedRuleID = nil
        }
        loadDetailFromSelection()
    }

    @objc private func moveAction(_ sender: NSSegmentedControl) {
        let delta: Int
        switch sender.selectedSegment {
        case 0: delta = -1
        case 1: delta = +1
        default: return
        }
        moveSelected(by: delta)
    }

    @objc private func resetAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Remove all user rules?"
        alert.informativeText = "Your user-authored rules will be deleted. Built-in rules remain unchanged — toggle their checkboxes in the table to enable or disable them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clearUserRules()
        selectedRuleID = nil
        reloadTable()
        loadDetailFromSelection()
    }

    @objc private func detailChanged(_ sender: Any?) {
        commitDetail()
    }

    @objc private func testPredicate(_ sender: Any?) {
        // Snapshot the current editor contents (rather than the last
        // saved value) so the user can test a draft they haven't typed
        // through to a stable state yet.
        let snapshot = predicateView.string
        // Close any previously-open test window so each click runs
        // against fresh editor contents — the controller snapshots
        // its inputs at init, so repurposing the existing instance
        // wouldn't pick up edits.
        testSheet?.close()
        let sheet = TestPredicateSheetController(
            predicate: snapshot,
            recents: Array(recentStore.requests.reversed())
        )
        self.testSheet = sheet
        // Present as a free-floating window rather than a sheet so the
        // user can drag it around to read alongside the Settings window.
        sheet.onClose = { [weak self, weak sheet] in
            guard let self = self, self.testSheet === sheet else { return }
            self.testSheet = nil
        }
        sheet.window?.center()
        sheet.window?.makeKeyAndOrderFront(nil)
    }

    /// Refresh the inline error label against the predicate field's
    /// current text. Called immediately when a rule is loaded into the
    /// editor, and from the debouncer when the user pauses typing.
    private func refreshPredicateErrorLabel() {
        if let parseError = PredicateParser.validate(predicateView.string) {
            predicateError.stringValue = parseError.localizedDescription
            predicateError.isHidden = false
        } else {
            predicateError.stringValue = ""
            predicateError.isHidden = true
        }
    }

    /// Refresh the template preview line with a freshly-picked random
    /// recent request as context. Re-sampling each fire means a user
    /// editing a rule sees the template applied to varied real captures
    /// rather than a single canned example — handy for templates whose
    /// output depends on the trigger (e.g. {process}, {subcommand}).
    private func refreshTemplatePreview() {
        guard let id = selectedRuleID,
              let rule = store.allRules.first(where: { $0.id == id }) else {
            templatePreview.stringValue = ""
            return
        }
        let recents = recentStore.requests
        if recents.isEmpty {
            templatePreview.stringValue =
                "Example will appear once op-who detects a request."
            templatePreview.textColor = .tertiaryLabelColor
            return
        }
        // Templates with placeholders like {plugin_remote} don't render
        // against every recent; try up to 8 random samples before giving
        // up so a partly-applicable rule still shows something useful.
        for recent in recents.shuffled().prefix(8) {
            if let preview = previewTitle(rule: rule, recent: recent) {
                templatePreview.stringValue = "e.g. " + preview
                templatePreview.textColor = .secondaryLabelColor
                return
            }
        }
        templatePreview.stringValue =
            "Template can’t be rendered against any recent activity yet."
        templatePreview.textColor = .tertiaryLabelColor
    }

    /// Single debouncer fire-point: both UI surfaces that refresh on the
    /// same quiet-period live here so they always update together.
    private func performDebouncedEditorRefresh() {
        refreshPredicateErrorLabel()
        refreshTemplatePreview()
    }

    private func commitDetail() {
        guard let id = selectedRuleID,
              let idx = store.userRules.firstIndex(where: { $0.id == id }) else {
            return
        }
        // Persist the predicate text eagerly — even broken in-progress
        // input survives a re-selection (the engine just skips rules that
        // don't parse). Defer the error label update via the debouncer so
        // it doesn't flash red on every keystroke.
        let predicateText = predicateView.string
        predicateErrorDebouncer.schedule { [weak self] in
            self?.performDebouncedEditorRefresh()
        }

        var rule = store.userRules[idx]
        rule.name = nameField.stringValue
        rule.predicate = predicateText
        rule.template = templateField.stringValue
        rule.comment = commentView.string.isEmpty ? nil : commentView.string
        rule.replacesActor = (replacesActorCheckbox.state == .on)
        rule.isWarning = (isWarningCheckbox.state == .on)
        if let raw = kindPopup.titleOfSelectedItem,
           let kind = RequestKind(rawValue: raw) {
            rule.kind = kind
        }
        var rules = store.userRules
        rules[idx] = rule
        store.setUserRules(rules)
        // Reload only the affected row, keeping selection.
        let allRules = store.allRules
        if let visIdx = allRules.firstIndex(where: { $0.id == id }) {
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: visIdx),
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }
    }

    // MARK: - Mutations

    private func insertUserRule(_ rule: RequestRule) {
        var rules = store.userRules
        // Insert after the selected user rule, if any; otherwise append
        // (which still places it ahead of all built-ins, since user rules
        // come first in `allRules`).
        let target: Int = {
            if let id = selectedRuleID,
               let idx = rules.firstIndex(where: { $0.id == id }) {
                return idx + 1
            }
            return rules.count
        }()
        rules.insert(rule, at: target)
        store.setUserRules(rules)
        reloadTable()
        selectedRuleID = rule.id
        if let visIdx = store.allRules.firstIndex(where: { $0.id == rule.id }) {
            tableView.selectRowIndexes(IndexSet(integer: visIdx), byExtendingSelection: false)
            tableView.scrollRowToVisible(visIdx)
        }
        loadDetailFromSelection()
    }

    private func emptyTemplateRule() -> RequestRule {
        RequestRule(
            name: "New rule",
            predicate: "TRUEPREDICATE",
            template: "triggered 1Password (via ‘{process}’)",
            kind: .unknown,
            isWarning: false
        )
    }

    private func ruleFromRecent(_ recent: RecentRequest) -> RequestRule {
        let process = recent.chainNames.first
        let sub = parseSubcommand(argv: recent.triggerArgv)
        let predicate = predicateFromRecent(recent, process: process, subcommand: sub)

        // Inherit template/kind/etc from whichever rule matched the
        // recent request. Built-in rule UUIDs regenerate every process
        // run, so a persisted `matchedRuleID` from a previous session
        // won't match any built-in here — look the built-in up by its
        // stable `builtInID` first, then fall back to UUID for matches
        // that happened within this process run (e.g. against user rules
        // recorded earlier in the same session).
        let inherited: RequestRule? = {
            if let bid = recent.matchedBuiltInID,
               let rule = RequestRule.builtIn(id: bid) {
                return rule
            }
            if let id = recent.matchedRuleID,
               let rule = store.allRules.first(where: { $0.id == id }) {
                return rule
            }
            return nil
        }()
        let template = inherited?.template ?? "triggered 1Password (via ‘{process}’)"
        let replacesActor = inherited?.replacesActor ?? false
        let kind = inherited?.kind ?? RequestKind(rawValue: recent.kindRaw) ?? .unknown
        let isWarning = inherited?.isWarning ?? recent.isWarning

        let label: String
        if let p = process, let s = sub {
            label = "Custom: \(p) \(s)"
        } else if let p = process {
            label = "Custom: \(p)"
        } else {
            label = "Custom rule"
        }
        return RequestRule(
            name: label, predicate: predicate, template: template,
            replacesActor: replacesActor, kind: kind, isWarning: isWarning
        )
    }

    /// Emit a starting NSPredicate string that matches the recent record's
    /// trigger process, parsed subcommand, non-flag argv tokens, and
    /// captured cwd. All the data the user can see in the source-request
    /// preview ends up in the predicate so the prefill faithfully
    /// represents what they picked — they can prune clauses they don't
    /// want to constrain on before saving.
    private func predicateFromRecent(_ recent: RecentRequest, process: String?, subcommand: String?) -> String {
        var clauses: [String] = []
        if let p = process, !p.isEmpty {
            clauses.append(#"triggerName == "\#(escapeForPredicateString(p))""#)
        }
        if let s = subcommand {
            clauses.append(#"subcommand == "\#(escapeForPredicateString(s))""#)
        }
        let argvTokens = nonFlagArgvTokens(argv: recent.triggerArgv, skipSubcommand: subcommand)
        for token in argvTokens {
            clauses.append(#"ANY triggerArgv == "\#(escapeForPredicateString(token))""#)
        }
        if let cwd = recent.triggerCwd ?? recent.cwd, !cwd.isEmpty {
            clauses.append(#"triggerCwd BEGINSWITH "\#(escapeForPredicateString(cwd))""#)
        }
        if process == "op" {
            clauses.append("binaryVerified == \(recent.binaryVerified ? "YES" : "NO")")
        }
        if recent.pluginRemoteURL != nil {
            clauses.append("pluginUpdateAvailable == YES")
        }
        return clauses.isEmpty ? "TRUEPREDICATE" : clauses.joined(separator: " AND ")
    }

    /// Escape backslashes and double quotes so a runtime-built predicate
    /// string survives NSPredicate's parser. `"` inside a `"…"` literal
    /// would terminate the string early; `\` is the escape character.
    private func escapeForPredicateString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Non-flag argv tokens after argv[0], with the parsed subcommand
    /// (if any) excluded. Shares `positionalArgvTokens`' flag handling: pair
    /// flags like `-C path` are skipped as a unit so the path doesn't
    /// leak in as if it were a positional argument.
    private func nonFlagArgvTokens(argv: [String], skipSubcommand: String?) -> [String] {
        var tokens = positionalArgvTokens(argv: argv)
        if let sub = skipSubcommand, let idx = tokens.firstIndex(of: sub) {
            tokens.remove(at: idx)
        }
        return tokens
    }

    private func moveSelected(by delta: Int) {
        guard let id = selectedRuleID,
              let idx = store.userRules.firstIndex(where: { $0.id == id }) else {
            // Reordering only applies to user rules (built-ins ship in a
            // fixed order). Beep so the user knows nothing happened.
            NSSound.beep()
            return
        }
        let target = idx + delta
        guard target >= 0, target < store.userRules.count, target != idx else { return }
        var rules = store.userRules
        let rule = rules.remove(at: idx)
        rules.insert(rule, at: target)
        store.setUserRules(rules)
        reloadTable()
        if let visIdx = store.allRules.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: visIdx), byExtendingSelection: false)
        }
    }

    // MARK: - Detail form ↔ rule

    private func loadDetailFromSelection() {
        isLoadingDetail = true
        defer {
            previousPredicateLength = (predicateView.string as NSString).length
            isLoadingDetail = false
        }
        guard let id = selectedRuleID,
              let rule = store.allRules.first(where: { $0.id == id }) else {
            clearDetail()
            setEditable(true)
            return
        }
        nameField.stringValue = rule.name
        predicateView.string = rule.predicate
        templateField.stringValue = rule.template
        commentView.string = rule.comment ?? ""
        replacesActorCheckbox.state = rule.replacesActor ? .on : .off
        isWarningCheckbox.state = rule.isWarning ? .on : .off
        kindPopup.selectItem(withTitle: rule.kind.rawValue)

        // Surface any parse error on the loaded predicate so the user
        // sees what's wrong without having to type into the field first.
        // Cancel any pending debounced refresh first — the new rule's
        // text is authoritative; a stale callback from the previous
        // rule's edits would just overwrite our work moments later.
        predicateErrorDebouncer.cancel()
        performDebouncedEditorRefresh()

        let isBuiltIn = (rule.builtInID != nil)
        setEditable(!isBuiltIn)
        builtInNotice.isHidden = !isBuiltIn
        detailBox.title = isBuiltIn
            ? "Selected rule (built-in — read only)"
            : "Selected rule"
    }

    private func clearDetail() {
        nameField.stringValue = ""
        predicateView.string = ""
        predicateError.stringValue = ""
        predicateError.isHidden = true
        templateField.stringValue = ""
        templatePreview.stringValue = ""
        commentView.string = ""
        replacesActorCheckbox.state = .off
        isWarningCheckbox.state = .off
        kindPopup.selectItem(withTitle: RequestKind.unknown.rawValue)
        builtInNotice.isHidden = true
        detailBox.title = "Selected rule"
    }

    private func setEditable(_ editable: Bool) {
        for control in editableControls {
            control.isEnabled = editable
        }
        predicateView.isEditable = editable
        predicateView.isSelectable = true // selectable even when read-only so users can copy
        commentView.isEditable = editable
        commentView.isSelectable = true
    }

    private func reloadTable() {
        tableView.reloadData()
        // Keep the visual selection aligned with `selectedRuleID` after
        // mutations that shift indices (e.g. adding a user rule above
        // built-ins).
        if let id = selectedRuleID,
           let idx = store.allRules.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }
}

// MARK: - NSTextViewDelegate

extension RulesPane: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        commitDetail()
        guard let textView = notification.object as? NSTextView,
              textView === predicateView else { return }
        let nsString = predicateView.string as NSString
        let newLength = nsString.length
        let grew = newLength > previousPredicateLength
        previousPredicateLength = newLength
        guard !isLoadingDetail, grew else { return }
        let caret = predicateView.selectedRange().location
        guard caret > 0, caret <= newLength else { return }
        let unit = nsString.character(at: caret - 1)
        guard let scalar = Unicode.Scalar(unit) else { return }
        let ch = Character(scalar)
        let isContinue =
            ch.isLetter || ch.isNumber
            || ch == "_" || ch == "@" || ch == "$" || ch == "."
        guard isContinue else { return }
        // Hop to the next runloop turn: `complete(_:)` reaches into the
        // text view's layout machinery, and calling it synchronously
        // inside a textDidChange callback can corner-case into a layout
        // assertion on macOS.
        DispatchQueue.main.async { [weak self] in
            self?.predicateView.complete(nil)
        }
    }

    func textView(_ textView: NSTextView,
                  completions words: [String],
                  forPartialWordRange charRange: NSRange,
                  indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        // Don't disturb the default completion path for the comment
        // editor or any other text view that ever ends up routed here.
        guard textView === predicateView else { return words }
        let partial = (textView.string as NSString).substring(with: charRange)
        return PredicateCompletions.candidates(forPartialWord: partial)
    }
}

// MARK: - Predicate text view

/// NSTextView subclass that widens the completion partial-word range to
/// include dotted keypaths. AppKit's default `rangeForUserCompletion`
/// stops at `.`, so a user typing `triggerArgv.@cou` would only see
/// `@cou` as the partial word and never get `@count` offered. We walk
/// leftward across identifier-continue characters (letters, digits, `_`,
/// `@`, `$`, `.`) so the whole keypath is treated as one word.
private final class PredicateTextView: NSTextView {
    override var rangeForUserCompletion: NSRange {
        let base = super.rangeForUserCompletion
        let nsString = self.string as NSString
        var loc = base.location
        while loc > 0 {
            let unit = nsString.character(at: loc - 1)
            guard let scalar = Unicode.Scalar(unit) else { break }
            let ch = Character(scalar)
            let isContinue =
                ch.isLetter || ch.isNumber
                || ch == "_" || ch == "@" || ch == "$" || ch == "."
            if !isContinue { break }
            loc -= 1
        }
        let extra = base.location - loc
        return NSRange(location: loc, length: base.length + extra)
    }
}

// MARK: - Resize grip

/// Thin drag handle that captures mouse drags and forwards the per-tick
/// vertical delta to its host. Drawn as three small dots so users
/// recognise it as a grip — same idiom HTML's resizable textarea uses.
/// Switches the cursor to the up/down resize cursor while hovered so
/// affordance is obvious before the click.
private final class ResizeGripView: NSView {

    /// Called per mouseDragged event with `event.deltaY` (non-flipped
    /// coords: drag DOWN is negative). The host decides how to apply it
    /// to whatever constraint it owns.
    var onDragDelta: ((CGFloat) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 8)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDragged(with event: NSEvent) {
        onDragDelta?(event.deltaY)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        let dotSize: CGFloat = 2
        let spacing: CGFloat = 4
        let totalWidth = dotSize * 3 + spacing * 2
        let startX = bounds.midX - totalWidth / 2
        let y = bounds.midY - dotSize / 2
        for i in 0..<3 {
            let x = startX + CGFloat(i) * (dotSize + spacing)
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dotSize, height: dotSize)).fill()
        }
    }
}

// MARK: - Enabled checkbox cell

/// Custom table cell that hosts a checkbox bound to a rule's `enabled`
/// flag. The cell stashes the rule's UUID so the action can route the
/// new state back to the store without depending on row indices, which
/// may shift between the time the cell is configured and the time the
/// checkbox fires (the store mutates and the table reloads).
private final class EnabledCheckboxCell: NSTableCellView {

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var ruleID: UUID?
    private var onToggle: ((UUID, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(ruleID: UUID, enabled: Bool, onToggle: @escaping (UUID, Bool) -> Void) {
        self.ruleID = ruleID
        self.onToggle = onToggle
        checkbox.state = enabled ? .on : .off
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let id = ruleID else { return }
        onToggle?(id, sender.state == .on)
    }
}

// MARK: - Toolbar-style button

/// Plain NSButton that pins its cursor to `.arrow`. The +/-/move buttons in
/// the rules pane are NSButtons with `.smallSquare` bezels hosting SF
/// Symbol images — under some macOS versions AppKit lets a horizontal
/// resize cursor bleed in from a neighbouring control (likely the
/// adjacent NSSegmentedControl's separator hit zone) when hovering the
/// short "minus" glyph. Reinstalling an explicit arrow cursor rect for
/// the button's full bounds keeps the pointer behaviour consistent with
/// every other button in the window.
private final class ToolbarButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}
