import AppKit
import OpWhoLib

/// Tabbed Settings window: General / Appearance / Rules. Each tab hosts one
/// pane's `view`; the Appearance tab is wrapped in an NSScrollView since its
/// content (fonts + a color grid) can exceed the window height on smaller
/// displays.
final class ConfigWindowController: NSWindowController, NSWindowDelegate {

    private let generalPane: GeneralPane
    private let appearancePane: AppearancePane
    private let rulesPane: RulesPane
    private var appearanceScroll: NSScrollView?
    private var tabView: NSTabView?

    init(
        ruleStore: RequestRuleStore,
        recentStore: RecentRequestsStore
    ) {
        self.generalPane = GeneralPane()
        self.appearancePane = AppearancePane()
        self.rulesPane = RulesPane(store: ruleStore, recentStore: recentStore)

        let window = ConfigWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "op-who Settings"
        window.minSize = NSSize(width: 720, height: 540)
        super.init(window: window)

        rulesPane.presenter = window
        window.delegate = self
        window.contentView = makeTabView()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func showWindow(_ sender: Any?) {
        generalPane.refreshState()
        // The controller is retained and reused, so the tab view would keep
        // the last active pane. Always open on General.
        tabView?.selectTabViewItem(at: 0)
        super.showWindow(sender)
        resetAppearanceScroll()
    }

    /// Dismiss any lingering popup preview when Settings closes.
    func windowWillClose(_ notification: Notification) {
        appearancePane.dismissPreview()
    }

    private func makeTabView() -> NSView {
        let tabView = NSTabView()
        self.tabView = tabView
        tabView.translatesAutoresizingMaskIntoConstraints = false

        tabView.addTabViewItem(tab("General", fill(generalPane.view)))

        let appearanceScroll = wrapInScroll(appearancePane.view)
        self.appearanceScroll = appearanceScroll
        tabView.addTabViewItem(tab("Appearance", appearanceScroll))

        tabView.addTabViewItem(tab("Rules", fill(rulesPane.view)))

        return tabView
    }

    private func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    /// A plain container that lets its single child fill it.
    private func fill(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func wrapInScroll(_ content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // A flipped clip view anchors the document at the TOP-left, so content
        // shorter than the viewport stays at the top instead of sinking to the
        // bottom (NSClipView's default, non-flipped origin is bottom-left).
        let clip = TopAnchoredClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        return scroll
    }

    /// The controller is retained and reused, so the Appearance scroll view
    /// keeps its prior offset. Snap it back to the top on reopen. With the
    /// flipped clip view, the top of the document is y = 0.
    private func resetAppearanceScroll() {
        guard let scroll = appearanceScroll else { return }
        scroll.documentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// A clip view that reports `isFlipped == true` so its document view is
    /// laid out from the top-left corner.
    private final class TopAnchoredClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    /// The Configure window lives outside the app's main menu (op-who is an
    /// LSUIElement menu-bar app with no File menu), so Cmd-W isn't routed to
    /// `performClose:` automatically. Intercept it here so it closes the
    /// window the way users expect.
    ///
    /// Also vends a field editor with `allowsUndo = true`. NSTextField
    /// doesn't manage its own editing — it borrows the window's shared
    /// field editor (an NSTextView). The default field editor has
    /// `allowsUndo = false`, which means Cmd-Z does nothing inside a text
    /// field even after the Edit menu is wired up. Returning a
    /// purpose-built field editor with undo enabled is the standard way
    /// to flip that behavior on for every text field in the window.
    private final class ConfigWindow: NSWindow {
        private lazy var undoEnabledFieldEditor: NSTextView = {
            let tv = NSTextView()
            tv.isFieldEditor = true
            tv.allowsUndo = true
            return tv
        }()

        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
            // NSTextView clients (e.g. the comment editor in RulesPane)
            // bring their own editor — defer to AppKit for those so we
            // don't accidentally hijack their text storage.
            if object is NSTextView {
                return super.fieldEditor(createFlag, for: object)
            }
            return undoEnabledFieldEditor
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "w" {
                performClose(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

}
