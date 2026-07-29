#!/usr/bin/env python3

import argparse
import json
import os
import pathlib
import stat
import tempfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Configure Claude Code's user-level terminal bell notification."
    )
    parser.add_argument(
        "--settings",
        type=pathlib.Path,
        help="Settings file to update (default: ~/.claude/settings.json)",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="Report whether terminal bell notifications are enabled without writing",
    )
    return parser.parse_args()


def settings_path(argument: pathlib.Path | None) -> pathlib.Path:
    if argument is not None:
        return argument.expanduser()
    user_root = os.environ.get("HOME")
    if not user_root:
        raise SystemExit("HOME is unset; pass --settings explicitly")
    return pathlib.Path(user_root) / ".claude" / "settings.json"


def read_settings(path: pathlib.Path) -> dict:
    if path.is_symlink():
        raise SystemExit(f"refusing to update symlinked settings file: {path}")
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"invalid JSON in {path}: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"settings root must be a JSON object: {path}")
    return value


def write_atomic(path: pathlib.Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    previous_mode = None
    if path.exists():
        previous_mode = stat.S_IMODE(path.stat().st_mode)
    payload = json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as handle:
        handle.write(payload)
        temporary_path = pathlib.Path(handle.name)
    if previous_mode is not None:
        temporary_path.chmod(previous_mode)
    os.replace(temporary_path, path)


def main() -> int:
    args = parse_args()
    path = settings_path(args.settings)
    settings = read_settings(path)
    enabled = settings.get("preferredNotifChannel") == "terminal_bell"

    if args.status:
        print("enabled" if enabled else "disabled")
        return 0 if enabled else 1

    if enabled:
        print(f"[claude-alert] terminal bell already enabled in {path}")
        return 0

    settings["preferredNotifChannel"] = "terminal_bell"
    write_atomic(path, settings)
    print(f"[claude-alert] enabled terminal bell notifications in {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
