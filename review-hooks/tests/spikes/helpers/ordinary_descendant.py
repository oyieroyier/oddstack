"""Positive containment control: a stubborn but ordinary descendant.

Stays in the reviewer's process group, ignores SIGTERM, and lingers.
The supervisor's group-wide kill sequence must reap it anyway. Usage:

  python3 ordinary_descendant.py <pid-file>
"""

import signal
import sys
import time


def main():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(sys.argv[1], "w", encoding="utf-8") as handle:
        handle.write("%d\n" % __import__("os").getpid())
    time.sleep(300)
    return 0


if __name__ == "__main__":
    sys.exit(main())
