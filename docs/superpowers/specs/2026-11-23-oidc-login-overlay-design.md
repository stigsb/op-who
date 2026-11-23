# OIDC login overlay

## Goal

When kubelogin opens a browser for an OIDC (step-up) login, show op-who's overlay next to the browser
window naming the command that needed the login, e.g. "Claude Code in cmux workspace ‘infra’ needs a
Kubernetes login for ‘kubectl get pods -n demo’". No extra page or click in the login flow.

## Trigger

`oidc-browser` (sunstoneinstitute/cli-tools) is kubelogin's `--browser-command`. After opening the
browser window it posts a distributed notification:

| Field | Value |
|---|---|
| name | `ai.sunstoneinstitute.oidc-browser.login-opened` |
| `userInfo["requesterPID"]` | decimal string, `getppid()` of oidc-browser, i.e. the kubelogin process |
| `userInfo["frame"]` | optional, `"x,y,w,h"` of the browser window in CG global coordinates (top-left origin) |

If op-who is not running, nothing happens. oidc-browser behaves as before.

## Process chain

Observed on macOS with kubelogin v1.34:

```
oidc-browser http://localhost:8000/
/opt/homebrew/bin/kubectl-oidc_login get-token ...   <- requesterPID
kubectl get pods -n demo                              <- trigger shown in the overlay
bash -c ... / claude / login shell ...
cmux (app boundary, chain stops)
```

kubelogin runs as a client-go exec credential plugin (`users[].user.exec` in the kubeconfig).
client-go starts the configured command as a child process of the program that needs the token.
With `command: kubectl` and `args: [oidc-login, get-token, …]`, that child is a second `kubectl`,
which finds `kubectl-oidc_login` on `PATH` and calls `execve` on it, so the child's PID now runs
kubelogin. With `command: kubelogin`, client-go starts kubelogin directly. Either way, kubelogin's
parent is the program that needed the token: here `kubectl get pods`, but any client-go program
(k9s, helm, an IDE plugin) works the same way.

op-who builds the chain from `requesterPID` with `ProcessTree.buildChain`, then drops leading nodes
that are kubelogin helpers. A node is a helper when the basename of its executable path is
`kubectl-oidc_login` or `kubelogin`. The path comes from `proc_pidpath`, which reads the kernel's
record of the executed file. argv[0] and the `KERN_PROCARGS2` exec path live in process memory and
can be rewritten by the process. The `kinfo_proc` name is truncated to 16 characters
(`kubectl-oidc_log`).

### Requesting app

For 1Password requests the chain stops at the first macOS app without recording it, because the
1Password dialog already names the app. The browser does not, so op-who must.

- `buildChain` records the app it stopped at for every app, not only terminals: a new
  `ChainResult.appBundleID` and `appPID`. A terminal helper (e.g. `iTermServer`) counts as its
  terminal app, as today. When the app's bundle sits inside another `.app` bundle (Electron and
  Chromium helpers), op-who reports the outermost one.
- The overlay shows the app's icon and name. For a terminal this is the existing terminal row, with
  tab title, or cmux workspace and tab resolved from `CMUX_SURFACE_ID` exactly as for 1Password
  requests. So a terminal request shows both the app and the tab.
- The 1Password short-chain filter (one node and no TTY) does not apply: the PID was already checked
  to be kubelogin.
- The chain can be empty after the helpers are dropped, when an app such as an IDE or Lens runs
  kubelogin itself. The app is then the actor, e.g. "Visual Studio Code needs an OIDC login". With
  no app either (parent is `launchd`), the actor is "An unknown process".
- cmux and terminal-tab lookups read environment and TTY from the kubelogin process when the chain
  is empty, since it inherits both from its parent.

## Trust

Distributed notifications do not identify the sender. op-who therefore:

1. Takes only a PID (and an optional frame) from the message and derives all displayed text from the
   live process tree.
2. Ignores the message unless that PID is a kubelogin helper (see Process chain).

This stops a bare message from naming an arbitrary process. It does not stop a local process running
as the user: it can install a binary named `kubelogin`, start it under a parent chain and argv of its
choosing, and post the message. The overlay then shows text that process controls, next to a window
it may control. The overlay is therefore context for a login the user started, not proof that a
login page is legitimate. The frame is unverified and affects only placement.

Sender verification would need an XPC/socket channel with a code-signature check. Out of scope.

## Display and dismissal

- The entry is built by the same code path as 1Password triggers (`TriggerEntryBuilder`), so terminal
  tab, cmux, Claude session, git context and secret redaction behave identically.
- The one-line description comes from a fixed internal ruleset (`OidcLogin.rules`), not the
  user-editable 1Password rules: `kubectl` → "needs a Kubernetes login for ‘{argv}’", empty chain →
  "needs an OIDC login", anything else → "needs an OIDC login (via ‘{process}’)".
- All three rules use a new `RequestKind.oidcLogin`. Its action-row color is a new `oidcLogin` color role:
  the default pair lives in `OverlayColors` and must pass the WCAG contrast test, and it is
  user-overridable like the other roles. The Rules pane kind picker does not offer `oidcLogin`,
  since OIDC rules are not user-editable. First logins and step-up logins are not distinguished.
- OIDC requests are not recorded in the recent-requests ring buffer, which exists to test
  1Password rules.
- Placement, when a frame is given: horizontally centered on the browser window, with the overlay's
  bottom edge 16 pt above the window's bottom edge. It never covers the top 120 pt of the window,
  where the tab and address bars are, because the URL is what the user must check on a login page.
  If the window is too short for that, the overlay goes directly below the window. The result is
  clamped to the visible frame of the screen containing the window. Without a frame, the overlay is
  centered on the main screen.
- 1Password overlay placement does not change.
- Show delay: the overlay appears only if kubelogin is still running 1 s (`OidcLogin.showDelay`)
  after the notification. A login that SSO completes without user input ends sooner and gets no
  overlay, so a browser window that opens and closes by itself is not explained by a popup. Step-up
  logins and any login waiting for the user get one.
- Dismissal: poll `kill(requesterPID, 0)` every 500 ms. kubelogin exits when the login completes or
  times out.
- Panels: at most one 1Password panel and at most one OIDC panel exist at a time. Each watcher owns a
  single `OverlayPanel` and reuses it, so the two can be visible together but neither source ever
  shows two. A second notification for the tracked PID is ignored. A notification for a different
  PID dismisses the OIDC panel and restarts the show delay for the new PID.
- "Send Message" writes an OIDC-specific line to the TTY (`RequestSource.ttyMessage`).

## Out of scope

Sender verification, user-editable OIDC rules, non-kubelogin OIDC helpers.
