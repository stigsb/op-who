import Testing

@testable import OpWhoLib

/// Tests for the pure approval-window classification in `OnePasswordWatcher`.
///
/// Regression context: `isApprovalDialog` originally accepted any 1Password
/// standard window whose title wasn't on a small denylist. The Quick Access
/// search window (opened with ⌘⇧Space, title "Quick Access — 1Password") and
/// account-named main windows ("<Account> — 1Password") weren't on the list,
/// so a coincidental long-lived `ssh`/`op` trigger process made the overlay
/// fire on them. 1Password names every persistent surface "<surface> —
/// 1Password"; only CLI/SSH approval prompts carry the bare title "1Password",
/// so we positively match that instead of denylisting named surfaces.
struct ApprovalWindowDetectionTests {

    @Test("Bare \"1Password\" standard window is an approval prompt")
    func bareTitleStandardWindowIsApproval() {
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXWindow", subrole: "AXStandardWindow", title: "1Password") == true)
    }

    @Test("Title is matched after trimming whitespace")
    func trimsWhitespace() {
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXWindow", subrole: "AXStandardWindow", title: "  1Password\n") == true)
    }

    @Test("Title match is case-insensitive")
    func caseInsensitive() {
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXWindow", subrole: "AXStandardWindow", title: "1password") == true)
    }

    @Test("Quick Access search window is NOT an approval prompt")
    func quickAccessIsNotApproval() {
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXWindow", subrole: "AXStandardWindow", title: "Quick Access — 1Password") == false)
    }

    @Test("Account-named main window is NOT an approval prompt")
    func accountWindowIsNotApproval() {
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXWindow", subrole: "AXStandardWindow",
            title: "Sunstone Institute AS — Admin — 1Password") == false)
    }

    @Test("Former denylist surfaces stay excluded under positive matching")
    func formerDenylistSurfacesExcluded() {
        for title in ["Settings", "All Items", "All Accounts", "Lock Screen", "Watchtower", "Developer"] {
            #expect(OnePasswordWatcher.isApprovalWindow(
                role: "AXWindow", subrole: "AXStandardWindow", title: title) == false)
        }
    }

    @Test("Empty or missing title is NOT an approval prompt")
    func emptyTitleIsNotApproval() {
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXWindow", subrole: "AXStandardWindow", title: "") == false)
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXWindow", subrole: "AXStandardWindow", title: nil) == false)
    }

    @Test("AXDialog subrole is always an approval prompt, regardless of title")
    func axDialogSubroleAlwaysApproval() {
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXWindow", subrole: "AXDialog", title: "anything") == true)
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXWindow", subrole: "AXDialog", title: nil) == true)
    }

    @Test("Non-window roles are never approval prompts")
    func nonWindowRoleRejected() {
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: "AXButton", subrole: "AXDialog", title: "1Password") == false)
        #expect(OnePasswordWatcher.isApprovalWindow(
            role: nil, subrole: nil, title: "1Password") == false)
    }
}
