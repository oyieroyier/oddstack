"""Negative containment control: a descendant that escapes the group.

Calls setsid() to leave the reviewer's process group and session — the
exact escape the supervisor documents it cannot contain
(review_gate/supervisor.py). Tests use it to validate that an external
survivor scan detects what group containment cannot; the caller must
reap the recorded pid explicitly after asserting. Usage:

  python3 setsid_escape.py <pid-file>
"""

import os
import signal
import sys
import time


def main():
    os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    # Drop the inherited reviewer pipes so the escapee cannot hold the
    # supervisor's drain loop open past the reviewer's own lifetime.
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    with open(sys.argv[1], "w", encoding="utf-8") as handle:
        handle.write("%d\n" % os.getpid())
    time.sleep(300)
    return 0


if __name__ == "__main__":
    sys.exit(main())
