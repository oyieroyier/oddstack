"""Entry script for the review gate.

The launcher executes this file by absolute path instead of `-m
review_gate`. With `-m`, Python puts the current directory first on
sys.path, so a `review_gate/` package committed to the reviewed
repository would shadow the installed runtime and could fake an accept.
A script path puts this file's directory first instead, and the package
import resolves through PYTHONPATH to the installed runtime only.
"""

import sys

from review_gate.cli import main

if __name__ == "__main__":
    sys.exit(main())
