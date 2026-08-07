"""E2 spike: probe the installed Codex CLI against the gate's invariants.

Runs `codex exec` through the production supervisor and reports
containment evidence. Read-only against the repository; talks to the
real Codex CLI and therefore spends real quota — run deliberately.

Probes:
  containment-normal   tiny prompt, generous deadline; expects clean
                       completion with verified group cleanup
  containment-timeout  tiny deadline forces the gate to kill mid-run;
                       expects verified group cleanup, no survivors

Usage:
  python3 probe_codex_backend.py --probe containment-normal
"""

import argparse
import json
import os
import sys
import time

SPIKE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(SPIKE_DIR)))

from review_gate import supervisor  # noqa: E402

BASE_ARGV = [
    "codex", "exec",
    "--strict-config",
    "--skip-git-repo-check",
    "--sandbox", "read-only",
    "--ephemeral",
    "--ignore-user-config",
    "--ignore-rules",
    "--color", "never",
    "--json",
]


def process_snapshot():
    """Every live process: pid -> (starttime, ppid, pgid, sid, cmdline).

    Name-independent by design: a detached shell, node worker, or
    code-mode host must not escape the evidence just because it is not
    called `codex`. (pid, starttime) identifies a process across the
    snapshot window; pid reuse alone cannot alias."""
    snapshot = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            with open("/proc/%d/stat" % pid, "rb") as handle:
                stat = handle.read().decode("ascii", errors="replace")
            with open("/proc/%d/cmdline" % pid, "rb") as handle:
                cmdline = handle.read().decode(
                    "utf-8", errors="replace"
                ).replace("\x00", " ").strip()
        except OSError:
            continue
        # Fields after the parenthesized comm (which may contain spaces).
        tail = stat.rsplit(")", 1)[-1].split()
        # tail[0]=state tail[1]=ppid tail[2]=pgid tail[3]=sid ... tail[19]=starttime
        try:
            ppid, pgid, sid = int(tail[1]), int(tail[2]), int(tail[3])
            starttime = int(tail[19])
        except (IndexError, ValueError):
            continue
        snapshot[pid] = (starttime, ppid, pgid, sid, cmdline)
    return snapshot


def survivor_evidence(before, after, group_pid):
    """Containment evidence from two snapshots.

    `in_group_or_session`: anything still sharing the supervised
    child's process group or session — authoritative in-group survivors.
    `new_and_surviving`: processes that appeared during the window and
    outlived it — candidate reparented escapees regardless of name;
    may contain unrelated system noise, so cmdlines are recorded for
    the operator to judge."""
    in_group = [
        {"pid": pid, "cmdline": info[4]}
        for pid, info in after.items()
        if info[2] == group_pid or info[3] == group_pid
    ]
    new_surviving = [
        {"pid": pid, "ppid": info[1], "pgid": info[2], "sid": info[3],
         "cmdline": info[4]}
        for pid, info in after.items()
        if pid not in before or before[pid][0] != info[0]
    ]
    return in_group, new_surviving


def report(probe, outcome, in_group, new_surviving):
    print(json.dumps({
        "probe": probe,
        "argv": outcome.argv,
        "started": outcome.started,
        "exit_code": outcome.exit_code,
        "term_signal": outcome.term_signal,
        "timed_out": outcome.timed_out,
        "duration": round(outcome.duration, 2),
        "cleanup_verified": outcome.cleanup_verified,
        "cleanup_detail": outcome.cleanup_detail,
        "stdout_bytes": outcome.stdout_total,
        "supervised_group_pid": outcome.pid,
        "survivors_in_group_or_session": in_group,
        "new_processes_surviving_window": new_surviving,
        "stdout_tail": outcome.stdout_data[-600:].decode(
            "utf-8", errors="replace"
        ),
    }, indent=2))


def run_probe(probe):
    before = process_snapshot()
    if probe == "containment-normal":
        argv = BASE_ARGV + ["Reply with just the word OK"]
        deadline = time.monotonic() + 120
    elif probe == "containment-timeout":
        argv = BASE_ARGV + [
            "Count slowly from 1 to 500, one number per line, "
            "thinking carefully about each"
        ]
        deadline = time.monotonic() + 8
    else:
        raise SystemExit("unknown probe %r" % probe)
    outcome = supervisor.run_attempt(
        argv, "", deadline, stdout_cap=30000, kill_grace=5,
        environ=dict(os.environ),
    )
    time.sleep(1.0)
    in_group, new_surviving = survivor_evidence(
        before, process_snapshot(), outcome.pid
    )
    report(probe, outcome, in_group, new_surviving)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, choices=[
        "containment-normal", "containment-timeout",
    ])
    args = parser.parse_args()
    return run_probe(args.probe)


if __name__ == "__main__":
    sys.exit(main())
