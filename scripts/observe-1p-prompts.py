#!/usr/bin/env python3
"""
Observe which processes are spawned/killed across 1Password permission prompts.

Goal: verify whether 1Password's per-request helper (the "op" or
"op-ssh-sign" child of 1Password.app) has a lifetime tied to the prompt
itself — i.e. it exits when the user clicks Authorize/Deny regardless of
whether the upstream trigger (ssh, git, ...) keeps running.

If that holds, op-who can drop the "is trigger process still alive?" half
of its dismissal check (which currently breaks for long-lived ssh sessions)
and use helper-exit as the per-request signal instead.

Usage:
    scripts/observe-1p-prompts.py
    OP_REF='op://Vault/Item/field' scripts/observe-1p-prompts.py

Env knobs:
    OP_REF          op:// reference for the op-read scenario (otherwise skipped)
    INTERVAL        sampling interval in seconds (default 0.15)
    TOTAL_WINDOW    total sampling seconds per scenario (default 12)
    OUT_DIR         override output directory
"""

from __future__ import annotations

import dataclasses
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path


INTERVAL = float(os.environ.get("INTERVAL", "0.15"))
TOTAL_WINDOW = float(os.environ.get("TOTAL_WINDOW", "12"))
OP_REF = os.environ.get("OP_REF")
OUT_DIR = Path(
    os.environ.get(
        "OUT_DIR",
        f"/tmp/op-who-trace-{datetime.now():%Y%m%d-%H%M%S}",
    )
)


@dataclasses.dataclass(frozen=True)
class Proc:
    pid: int
    ppid: int
    etime: str
    command: str

    @property
    def argv0_path(self) -> str:
        """argv[0] with any trailing flag arguments stripped. macOS apps have
        spaces in their executable paths ("1Password Helper (Renderer)"),
        so a naive split on whitespace loses them. We instead cut at the
        first ' -' (where flags begin)."""
        argv0 = self.command
        idx = argv0.find(" -")
        if idx > 0:
            argv0 = argv0[:idx]
        return argv0.rstrip()

    @property
    def name(self) -> str:
        # rstrip trailing slashes first: macOS-spawned LoginItem helpers can
        # appear with their argv[0] terminating in "/" before a " -psn_..."
        # flag, which would make a naive rsplit("/", 1)[-1] return "".
        a = self.argv0_path.rstrip("/")
        base = a.rsplit("/", 1)[-1]
        return base or a or self.command[:32]


def snapshot() -> tuple[float, dict[int, Proc]]:
    ts = time.time()
    out = subprocess.check_output(
        ["ps", "-axww", "-o", "pid=,ppid=,etime=,command="],
        text=True,
    )
    procs: dict[int, Proc] = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        procs[pid] = Proc(pid=pid, ppid=ppid, etime=parts[2], command=parts[3])
    return ts, procs


def is_1p_name(name: str) -> bool:
    return "1password" in name.lower()


def walk_to_1p(
    pid: int, procs: dict[int, Proc], max_depth: int = 6
) -> tuple[bool, list[Proc]]:
    """Walk up the parent chain from `pid` looking for a 1Password ancestor.
    Returns (found, chain_visited)."""
    chain: list[Proc] = []
    start = procs.get(pid)
    if start is None:
        return False, chain
    cur = procs.get(start.ppid)
    depth = 0
    while cur is not None and cur.pid not in (0, 1) and depth < max_depth:
        chain.append(cur)
        if is_1p_name(cur.name):
            return True, chain
        cur = procs.get(cur.ppid)
        depth += 1
    return False, chain


def codesign_info(path: str) -> str:
    if not path or not Path(path).exists():
        return ""
    try:
        out = subprocess.run(
            ["codesign", "-dv", "--verbose=2", path],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except subprocess.TimeoutExpired:
        return ""
    # codesign writes the interesting bits to stderr.
    text = (out.stderr or "") + (out.stdout or "")
    keep = ("Authority", "TeamIdentifier", "Identifier=")
    return "\n".join(l for l in text.splitlines() if any(k in l for k in keep))


def lock_1password() -> bool:
    """Force-lock the 1Password GUI app by clicking its menu bar Lock item
    via System Events. We click the menu item rather than sending a global
    keystroke so we don't have to bring 1Password to the foreground.

    Requires Accessibility permission for the parent terminal (Terminal,
    iTerm, etc.) — same permission op-who itself uses.

    Without this, consecutive prompts can be silently auto-approved by 1P
    based on its recently-authorized cache, defeating the whole point of
    re-triggering scenarios back-to-back.
    """
    script = """
tell application "System Events"
    tell process "1Password"
        try
            click menu item "Lock 1Password" of menu 1 of menu bar item "1Password" of menu bar 1
            return "locked"
        on error
            try
                click menu item "Lock" of menu 1 of menu bar item "1Password" of menu bar 1
                return "locked-fallback"
            on error errMsg
                return "failed: " & errMsg
            end try
        end try
    end tell
end tell
"""
    try:
        result = subprocess.run(
            ["osascript", "-"],
            input=script,
            capture_output=True,
            text=True,
            timeout=5,
        )
        out = (result.stdout or "").strip()
        if out.startswith("locked"):
            return True
        print(f"  WARNING: lock_1password did not succeed: {out or result.stderr.strip()}")
        return False
    except subprocess.TimeoutExpired:
        print("  WARNING: lock_1password timed out")
        return False


@dataclasses.dataclass
class Scenario:
    name: str
    desc: str
    cmd: list[str]
    prep: list[str] | None = None


def run_scenario(s: Scenario) -> None:
    print()
    print("=" * 60)
    print(f" Scenario: {s.name}")
    print(f" Desc:     {s.desc}")
    print(f" Command:  {shlex.join(s.cmd)}")
    print("=" * 60)

    if s.prep:
        print(f"  Prep: {shlex.join(s.prep)}")
        subprocess.run(
            s.prep,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )

    # Lock 1P so this scenario is guaranteed to hit a fresh biometric prompt
    # rather than being silently auto-approved from a recent unlock.
    print("  Locking 1Password...")
    if lock_1password():
        time.sleep(0.7)  # give the lock UI a beat to settle

    try:
        input("  Press Enter when ready... ")
    except EOFError:
        print("  (stdin closed, skipping)")
        return

    print("  Trigger fires in 2s. APPROVE the prompt when shown.")
    print("  Wait AT LEAST 2 seconds after the prompt appears before touching Touch ID.")
    time.sleep(2)

    ts0, baseline = snapshot()
    baseline_pids = set(baseline)

    stdout_path = OUT_DIR / f"{s.name}.stdout"
    stderr_path = OUT_DIR / f"{s.name}.stderr"
    with open(stdout_path, "w") as so, open(stderr_path, "w") as se:
        trigger = subprocess.Popen(
            s.cmd,
            stdin=subprocess.DEVNULL,
            stdout=so,
            stderr=se,
            start_new_session=True,
        )
    print(f"  trigger pid={trigger.pid} — sampling for {TOTAL_WINDOW:.0f}s:")
    print("  ", end="", flush=True)

    samples: list[tuple[float, dict[int, Proc]]] = [(ts0, baseline)]
    deadline = time.time() + TOTAL_WINDOW
    while time.time() < deadline:
        s_ts, s_procs = snapshot()
        samples.append((s_ts, s_procs))
        print(".", end="", flush=True)
        slack = INTERVAL - (time.time() - s_ts)
        if slack > 0:
            time.sleep(slack)
    print(" sampler done")

    # Reap the trigger's whole process group (ssh can spawn ControlMaster
    # helpers and similar). start_new_session=True puts the trigger in its
    # own group keyed by its own pid.
    try:
        os.killpg(trigger.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        trigger.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(trigger.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass

    print("  analyzing trace...")
    write_report(s, samples, baseline_pids)


def write_report(
    s: Scenario,
    samples: list[tuple[float, dict[int, Proc]]],
    baseline_pids: set[int],
) -> None:
    report_path = OUT_DIR / f"{s.name}.md"
    if not samples:
        report_path.write_text(f"# {s.name}\n\n(no samples)\n")
        return

    t0 = samples[0][0]
    tN = samples[-1][0]

    first_seen: dict[int, float] = {}
    last_seen: dict[int, float] = {}
    first_proc: dict[int, Proc] = {}
    latest_proc: dict[int, Proc] = {}

    for ts, procs in samples:
        for pid, p in procs.items():
            if pid not in first_seen:
                first_seen[pid] = ts
                first_proc[pid] = p
            last_seen[pid] = ts
            latest_proc[pid] = p

    all_pids = set(first_seen)
    new_pids = sorted(all_pids - baseline_pids, key=lambda pid: first_seen[pid])

    L: list[str] = []
    L.append(f"# Trace: {s.name}")
    L.append("")
    L.append(f"- Trigger: `{shlex.join(s.cmd)}`")
    L.append(
        f"- Window: {tN - t0:.2f}s @ {INTERVAL:.2f}s interval ({len(samples)} samples)"
    )
    L.append(f"- Baseline PIDs: {len(baseline_pids)}")
    L.append(f"- Total observed PIDs: {len(all_pids)}")
    L.append(f"- New during window: {len(new_pids)}")
    L.append("")

    L.append("## NEW processes with a 1Password ancestor (per-request helpers)")
    L.append("")
    L.append(
        "These are the candidates op-who could watch as a per-request dismissal signal."
    )
    L.append("")
    helpers_found = 0
    for pid in new_pids:
        is_1p, chain = walk_to_1p(pid, latest_proc)
        if not is_1p:
            continue
        helpers_found += 1
        p = first_proc[pid]
        gone_for = tN - last_seen[pid]
        if gone_for > 1.0:
            verdict = (
                f"**EXITED** (gone-for {gone_for:.2f}s) — good per-request signal"
            )
        else:
            verdict = "still alive at end of window — NOT per-request"
        chain_str = " -> ".join(f"{a.pid}:{a.name}" for a in chain)
        L.append(f"- PID {pid} `{p.name}` — {verdict}")
        L.append(f"  - parent chain: {chain_str}")
        L.append(f"  - cmd: `{p.command[:140]}`")
    if helpers_found == 0:
        L.append("- (none — either no prompt fired, or the helper has an unexpected lineage)")
    L.append("")

    L.append("## All NEW processes during the window")
    L.append("")
    L.append(
        "| PID | PPID | parent name | name | first +s | last +s | gone for | exited? | command |"
    )
    L.append("|---|---|---|---|---|---|---|---|---|")
    for pid in new_pids:
        p = first_proc[pid]
        parent = latest_proc.get(p.ppid)
        pname = parent.name if parent else "?"
        fs = first_seen[pid] - t0
        ls = last_seen[pid] - t0
        gone_for = tN - last_seen[pid]
        exited = "yes" if gone_for > 1.0 else "no"
        cmd_short = p.command[:90].replace("|", r"\|")
        L.append(
            f"| {pid} | {p.ppid} | {pname} | {p.name} | "
            f"{fs:.2f} | {ls:.2f} | {gone_for:.2f}s | {exited} | {cmd_short} |"
        )
    L.append("")

    L.append("## Pre-existing 1Password/op/ssh processes that disappeared")
    L.append("")
    disappeared = 0
    interesting = {"op", "op-ssh-sign", "ssh", "ssh-keygen"}
    for pid in sorted(baseline_pids):
        baseline_p = baseline_proc(samples, pid)
        if baseline_p is None:
            continue
        if not (is_1p_name(baseline_p.name) or baseline_p.name in interesting):
            continue
        gone_for = tN - last_seen.get(pid, t0)
        if gone_for > 1.0:
            disappeared += 1
            L.append(
                f"- PID {pid} `{baseline_p.name}` — exited during trace, "
                f"gone-for {gone_for:.2f}s (cmd: `{baseline_p.command[:110]}`)"
            )
    if disappeared == 0:
        L.append("- (none)")
    L.append("")

    L.append("## Codesign info for new op/ssh/1Password processes")
    L.append("")
    cs_seen = 0
    for pid in new_pids:
        p = first_proc[pid]
        if not (
            p.name in interesting
            or is_1p_name(p.name)
        ):
            continue
        info = codesign_info(p.argv0_path)
        if not info:
            continue
        cs_seen += 1
        L.append(f"### PID {pid} (`{p.name}`)")
        L.append("")
        L.append(f"- exe: `{p.argv0_path}`")
        L.append("")
        L.append("```")
        L.append(info)
        L.append("```")
        L.append("")
    if cs_seen == 0:
        L.append("- (no signable new processes found)")
    L.append("")

    report_path.write_text("\n".join(L))
    print(f"  Report: {report_path}")
    print(
        f"  Found {helpers_found} 1P-spawned helper(s); "
        f"{disappeared} pre-existing 1P/op proc(s) exited."
    )


def baseline_proc(
    samples: list[tuple[float, dict[int, Proc]]], pid: int
) -> Proc | None:
    return samples[0][1].get(pid) if samples else None


def git_global(key: str) -> str | None:
    try:
        return subprocess.check_output(
            ["git", "config", "--global", "--get", key], text=True
        ).strip()
    except subprocess.CalledProcessError:
        return None


def build_scenarios() -> list[Scenario]:
    scenarios: list[Scenario] = [
        Scenario(
            "01-ssh-github",
            "Plain ssh to GitHub via 1P SSH agent",
            ["ssh", "-o", "BatchMode=no", "-o", "ConnectTimeout=10", "-T", "git@github.com"],
        ),
        Scenario(
            "02-git-ls-remote",
            "git ls-remote SSH (git -> ssh -> 1P agent)",
            ["git", "ls-remote", "git@github.com:stigsb/op-who.git", "HEAD"],
        ),
        Scenario(
            "03-ssh-github-second",
            "Repeat of scenario 01 — does the 2nd prompt spawn a fresh helper?",
            ["ssh", "-o", "BatchMode=no", "-o", "ConnectTimeout=10", "-T", "git@github.com"],
        ),
    ]

    if shutil.which("op"):
        if OP_REF:
            scenarios.append(
                Scenario(
                    "04-op-read",
                    "1P CLI 'op read' forcing biometric re-prompt",
                    ["op", "read", OP_REF],
                    prep=["op", "signout", "--all"],
                )
            )
        else:
            print("Skipping op-read scenario: set OP_REF='op://Vault/Item/field' and rerun.")

    ssh_prog = git_global("gpg.ssh.program")
    sign_key = git_global("user.signingkey")
    gpg_sign = git_global("commit.gpgsign")
    if (
        ssh_prog
        and sign_key
        and gpg_sign == "true"
        and Path(ssh_prog).is_file()
        and os.access(ssh_prog, os.X_OK)
    ):
        tmp = tempfile.mkdtemp(prefix="op-who-sign-")
        for cmd in (
            ["git", "-C", tmp, "init", "-q"],
            ["git", "-C", tmp, "config", "user.email", "t@t"],
            ["git", "-C", tmp, "config", "user.name", "t"],
            ["git", "-C", tmp, "config", "commit.gpgsign", "true"],
            ["git", "-C", tmp, "config", "gpg.format", "ssh"],
            ["git", "-C", tmp, "config", "gpg.ssh.program", ssh_prog],
            ["git", "-C", tmp, "config", "user.signingkey", sign_key],
        ):
            subprocess.run(
                cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
        scenarios.append(
            Scenario(
                "05-op-ssh-sign-commit",
                "Empty signed commit via op-ssh-sign",
                ["git", "-C", tmp, "commit", "--allow-empty", "-m", "op-who observation test"],
            )
        )

    return scenarios


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        out = subprocess.check_output(["pgrep", "-i", "1password"], text=True)
    except subprocess.CalledProcessError:
        print("ERROR: 1Password is not running. Open the app and retry.", file=sys.stderr)
        return 1
    one_p_pids = out.split()

    print(f"output dir:     {OUT_DIR}")
    print(f"1Password PIDs: {' '.join(one_p_pids)}")
    print(f"interval:       {INTERVAL}s")
    print(f"window:         {TOTAL_WINDOW}s per scenario")
    print()
    print("For each scenario:")
    print("  1. Press Enter when ready")
    print("  2. Trigger runs after a 2s countdown")
    print("  3. APPROVE the biometric prompt — but wait at least 2 seconds")
    print("     after it appears before touching the sensor")
    print()

    scenarios = build_scenarios()

    for s in scenarios:
        try:
            run_scenario(s)
        except KeyboardInterrupt:
            print("\nInterrupted.")
            return 130

    print()
    print("=" * 60)
    print(f"DONE. Reports in: {OUT_DIR}")
    print(f"View: less {OUT_DIR}/*.md")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
