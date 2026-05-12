import Testing
@testable import OpWhoLib

@Suite("TerminalHelper.isValidTTYPath")
struct TTYPathValidationTests {

    @Test func validPaths() {
        #expect(TerminalHelper.isValidTTYPath("/dev/ttys000"))
        #expect(TerminalHelper.isValidTTYPath("/dev/ttys001"))
        #expect(TerminalHelper.isValidTTYPath("/dev/ttys123"))
        #expect(TerminalHelper.isValidTTYPath("/dev/ttys9999"))
    }

    @Test func emptyString() {
        #expect(!TerminalHelper.isValidTTYPath(""))
    }

    @Test func wrongDeviceType() {
        #expect(!TerminalHelper.isValidTTYPath("/dev/tty"))
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttyp0"))
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttys"))
    }

    @Test func pathTraversal() {
        #expect(!TerminalHelper.isValidTTYPath("../../../etc/passwd"))
        #expect(!TerminalHelper.isValidTTYPath("/tmp/evil"))
    }

    @Test func injectionAttempts() {
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttys001; rm -rf /"))
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttys001\n/etc/passwd"))
        #expect(!TerminalHelper.isValidTTYPath("/dev/ttys001 "))
    }
}

@Suite("TerminalHelper iTerm probe parsing & title choice")
struct ITermProbeTests {

    @Test func parsesKeyValuePairs() {
        let m = TerminalHelper.parseITermProbe("session=op|tab=mattermost")
        #expect(m["session"] == "op")
        #expect(m["tab"] == "mattermost")
    }

    @Test func mapsMissingValueToEmpty() {
        // AppleScript stringifies `missing value` literally; we collapse to "".
        let m = TerminalHelper.parseITermProbe("session=missing value|tab=mattermost")
        #expect(m["session"] == "")
        #expect(m["tab"] == "mattermost")
    }

    @Test func handlesEmptyValues() {
        let m = TerminalHelper.parseITermProbe("session=|tab=")
        #expect(m["session"] == "")
        #expect(m["tab"] == "")
    }

    @Test func nilProbeReturnsEmpty() {
        let m = TerminalHelper.parseITermProbe(nil)
        #expect(m.isEmpty)
    }

    // MARK: - chooseiTermTitle (returns name + shortcut)

    @Test func tabOverrideWinsAsName() {
        let r = TerminalHelper.chooseiTermTitle(session: "op", tab: "mattermost")
        #expect(r.name == "mattermost")
        #expect(r.shortcut == nil)
    }

    @Test func tabEqualsSessionMeansNoNameOverride() {
        // Unrenamed iTerm tab: title of t is recomposed by Title Components
        // and matches session.name. Not a real user rename.
        let r = TerminalHelper.chooseiTermTitle(session: "op", tab: "op")
        #expect(r.name == nil)
    }

    @Test func bothEmptyReturnsNoName() {
        let r = TerminalHelper.chooseiTermTitle(session: "", tab: "")
        #expect(r.name == nil)
        #expect(r.shortcut == nil)
    }

    @Test func sessionUsedWhenTabMissing() {
        let r = TerminalHelper.chooseiTermTitle(session: "build server", tab: nil)
        #expect(r.name == "build server")
    }

    @Test func genericSessionRejected() {
        let r = TerminalHelper.chooseiTermTitle(session: "zsh", tab: nil)
        #expect(r.name == nil)
    }

    @Test func whitespaceIsTrimmedInName() {
        let r = TerminalHelper.chooseiTermTitle(session: "  op  ", tab: "  mattermost  ")
        #expect(r.name == "mattermost")
    }

    // MARK: - Keyboard-shortcut formatting

    @Test func shortcutForTabsOneThroughEight() {
        for i in 1...8 {
            #expect(TerminalHelper.formatITermShortcut(winIdx: 1, winCount: 1, tabIdx: i, tabCount: 12) == "⌘\(i)")
        }
    }

    @Test func shortcutForLastTabUsesCmdNine() {
        #expect(TerminalHelper.formatITermShortcut(winIdx: 1, winCount: 1, tabIdx: 9, tabCount: 9) == "⌘9")
        #expect(TerminalHelper.formatITermShortcut(winIdx: 1, winCount: 1, tabIdx: 12, tabCount: 12) == "⌘9")
        #expect(TerminalHelper.formatITermShortcut(winIdx: 1, winCount: 1, tabIdx: 20, tabCount: 20) == "⌘9")
    }

    @Test func middleTabsBeyondEightHaveNoShortcut() {
        #expect(TerminalHelper.formatITermShortcut(winIdx: 1, winCount: 1, tabIdx: 9, tabCount: 12) == "tab 9")
        #expect(TerminalHelper.formatITermShortcut(winIdx: 1, winCount: 1, tabIdx: 10, tabCount: 12) == "tab 10")
    }

    @Test func multipleWindowsPrefixWindowIndex() {
        #expect(TerminalHelper.formatITermShortcut(winIdx: 2, winCount: 3, tabIdx: 1, tabCount: 4) == "window 2 ⌘1")
        #expect(TerminalHelper.formatITermShortcut(winIdx: 3, winCount: 3, tabIdx: 9, tabCount: 9) == "window 3 ⌘9")
        #expect(TerminalHelper.formatITermShortcut(winIdx: 2, winCount: 2, tabIdx: 10, tabCount: 12) == "window 2 tab 10")
    }

    @Test func chooseTitleEmitsShortcutEvenWithName() {
        // Even when the tab is renamed, the shortcut is emitted so the
        // overlay can show both ("tab 'mattermost' ⌘3").
        let r = TerminalHelper.chooseiTermTitle(
            session: "op", tab: "mattermost",
            winIdx: 1, winCount: 1, tabIdx: 3, tabCount: 5
        )
        #expect(r.name == "mattermost")
        #expect(r.shortcut == "⌘3")
    }

    @Test func chooseTitleShortcutWithoutName() {
        let r = TerminalHelper.chooseiTermTitle(
            session: "op", tab: "op",
            winIdx: 1, winCount: 1, tabIdx: 3, tabCount: 5
        )
        #expect(r.name == nil)
        #expect(r.shortcut == "⌘3")
    }

    @Test func chooseTitleNilWithoutShortcutInfo() {
        let r = TerminalHelper.chooseiTermTitle(session: "op", tab: "op")
        #expect(r.name == nil)
        #expect(r.shortcut == nil)
    }

    // MARK: - Stable window index via sorted IDs

    @Test func windowIndexSortsByIdNumericallyOldestFirst() {
        // iTerm assigns monotonically-increasing window IDs at creation.
        // Sorting numerically gives "creation order" = stable 1-based index.
        // Iteration order in `windows` is frontmost-first (here: 500 frontmost),
        // but the target id 100 is the oldest window → index 1.
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: "100", allWinIds: "500,100,300") == 1)
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: "300", allWinIds: "500,100,300") == 2)
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: "500", allWinIds: "500,100,300") == 3)
    }

    @Test func windowIndexSingleWindowIsOne() {
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: "42", allWinIds: "42") == 1)
    }

    @Test func windowIndexMissingInputsReturnNil() {
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: nil, allWinIds: "1,2") == nil)
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: "1", allWinIds: nil) == nil)
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: "0", allWinIds: "1,2") == nil)
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: "1", allWinIds: "") == nil)
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: "abc", allWinIds: "1,2") == nil)
    }

    @Test func windowIndexTargetNotInListIsNil() {
        #expect(TerminalHelper.computeITermWindowIndex(targetWinId: "999", allWinIds: "1,2,3") == nil)
    }
}
