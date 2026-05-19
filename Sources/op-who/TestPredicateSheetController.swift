import AppKit
import OpWhoLib

/// Sheet shown when the user clicks "Test" next to the predicate field.
/// Evaluates the snapshot predicate against every record in the recent-
/// requests ring buffer and shows match/no-match per record so the user
/// can verify their predicate against captures they've actually seen
/// rather than imagined ones.
///
/// Snapshots the predicate at construction. Re-testing after an edit is
/// "close the sheet, edit the predicate, click Test again" — there's
/// only one canonical predicate field, the one in the rules pane.
final class TestPredicateSheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let recents: [RecentRequest]
    private let predicate: String

    private let predicateLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()

    /// Match outcomes aligned with `recents`. Empty when the predicate
    /// failed to parse — the table still shows the recents themselves
    /// so the user has context for what would have been tested.
    private var matches: [Bool] = []

    init(predicate: String, recents: [RecentRequest]) {
        self.predicate = predicate
        self.recents = recents
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Test predicate"
        window.minSize = NSSize(width: 720, height: 320)
        super.init(window: window)
        window.contentView = makeContentView()
        runAndPopulate()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString:
            "The snapshot predicate below is evaluated against every record in the recent-requests ring buffer:"
        )
        header.font = NSFont.systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byWordWrapping
        header.maximumNumberOfLines = 2
        header.preferredMaxLayoutWidth = 880
        stack.addArrangedSubview(header)

        predicateLabel.stringValue = predicate.isEmpty ? "(empty)" : predicate
        predicateLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        predicateLabel.isSelectable = true
        predicateLabel.lineBreakMode = .byWordWrapping
        predicateLabel.maximumNumberOfLines = 4
        predicateLabel.preferredMaxLayoutWidth = 880
        stack.addArrangedSubview(predicateLabel)

        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        errorLabel.preferredMaxLayoutWidth = 880
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)

        let scroll = makeTableScroll()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 880).isActive = true
        stack.addArrangedSubview(scroll)

        summaryLabel.font = NSFont.systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(summaryLabel)

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeAction(_:)))
        closeButton.keyEquivalent = "\r"
        bar.addArrangedSubview(closeButton)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 880).isActive = true
        stack.addArrangedSubview(bar)

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func makeTableScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let cols: [(String, String, CGFloat, CGFloat?, CGFloat?)] = [
            ("match",   "Match",             50,  50, 70),
            ("time",    "Time",             100,  nil, nil),
            ("trigger", "Trigger",          140,  nil, nil),
            ("argv",    "Argv",             220,  nil, nil),
            ("cwd",     "Cwd",              200,  nil, nil),
            ("title",   "Title at detection", 220, nil, nil),
        ]
        for (id, title, width, minW, maxW) in cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            if let minW = minW { col.minWidth = minW }
            if let maxW = maxW { col.maxWidth = maxW }
            tableView.addTableColumn(col)
        }

        scroll.documentView = tableView
        return scroll
    }

    // MARK: - Evaluation

    private func runAndPopulate() {
        if recents.isEmpty {
            summaryLabel.stringValue = "No recent requests captured yet — trigger a 1Password approval and try again."
            errorLabel.isHidden = true
            tableView.reloadData()
            return
        }
        do {
            let p = try PredicateParser.parse(predicate)
            matches = recents.map { p.evaluate(with: $0.makeMatchContext().predicateBridge()) }
            let matchCount = matches.filter { $0 }.count
            let suffix = recents.count == 1 ? "" : "s"
            summaryLabel.stringValue = "Predicate matched \(matchCount) of \(recents.count) recent request\(suffix)."
            errorLabel.isHidden = true
        } catch {
            errorLabel.stringValue = "Parse error: \(error.localizedDescription)"
            errorLabel.isHidden = false
            summaryLabel.stringValue = "No matches — predicate did not parse."
            matches = []
        }
        tableView.reloadData()
    }

    // MARK: - NSTableView data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { recents.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn else { return nil }
        guard row < recents.count else { return nil }
        let r = recents[row]
        let id = NSUserInterfaceItemIdentifier("cell_\(col.identifier.rawValue)")
        let cell: NSTableCellView = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? makeCellView(id: id)

        switch col.identifier.rawValue {
        case "match":
            if row < matches.count {
                let m = matches[row]
                cell.textField?.stringValue = m ? "✓" : "—"
                cell.textField?.textColor = m ? .systemGreen : .secondaryLabelColor
            } else {
                cell.textField?.stringValue = "—"
                cell.textField?.textColor = .secondaryLabelColor
            }
            cell.textField?.alignment = .center
            cell.textField?.font = NSFont.systemFont(ofSize: 12)
        case "time":
            cell.textField?.stringValue = Self.timeFormatter.string(from: r.timestamp)
            cell.textField?.font = NSFont.systemFont(ofSize: 11)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .natural
        case "trigger":
            let process = r.chainNames.first ?? "?"
            let sub = parseSubcommand(argv: r.triggerArgv) ?? ""
            cell.textField?.stringValue = sub.isEmpty ? process : "\(process) \(sub)"
            cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = .labelColor
            cell.textField?.alignment = .natural
        case "argv":
            cell.textField?.stringValue = r.triggerArgv.isEmpty ? "—" : r.triggerArgv.joined(separator: " ")
            cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = .labelColor
            cell.textField?.alignment = .natural
        case "cwd":
            cell.textField?.stringValue = r.triggerCwd ?? r.cwd ?? "—"
            cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = .labelColor
            cell.textField?.alignment = .natural
        case "title":
            cell.textField?.stringValue = r.title
            cell.textField?.font = NSFont.systemFont(ofSize: 11)
            cell.textField?.textColor = .labelColor
            cell.textField?.alignment = .natural
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    private func makeCellView(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.isSelectable = true
        cell.textField = tf
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    @objc private func closeAction(_ sender: Any?) {
        guard let sheet = window else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
    }
}
