#!/usr/bin/env python3

import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: read-preference.py FILE dotted.key", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"invalid preference file {path}: {error}", file=sys.stderr)
        return 2

    for part in sys.argv[2].split("."):
        if not isinstance(value, dict) or part not in value:
            return 0
        value = value[part]

    if value is None:
        return 0
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (str, int, float)):
        print(value)
    else:
        print(f"preference {sys.argv[2]} must be a scalar", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
