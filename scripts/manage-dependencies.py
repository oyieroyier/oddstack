#!/usr/bin/env python3
"""Report and explicitly install system dependencies used by the bundle."""

from __future__ import annotations

import argparse
import os
import pathlib
import platform
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Capability:
    command: str
    purpose: str
    level: str
    active: bool = True
    installable: bool = True


PACKAGE_NAMES = {
    "apt": {
        "git": "git",
        "python3": "python3",
        "rg": "ripgrep",
        "sed": "sed",
        "awk": "gawk",
        "grep": "grep",
        "find": "findutils",
        "timeout": "coreutils",
        "sha256sum": "coreutils",
        "tar": "tar",
    },
    "dnf": {
        "git": "git",
        "python3": "python3",
        "rg": "ripgrep",
        "sed": "sed",
        "awk": "gawk",
        "grep": "grep",
        "find": "findutils",
        "timeout": "coreutils",
        "sha256sum": "coreutils",
        "tar": "tar",
    },
    "yum": {
        "git": "git",
        "python3": "python3",
        "rg": "ripgrep",
        "sed": "sed",
        "awk": "gawk",
        "grep": "grep",
        "find": "findutils",
        "timeout": "coreutils",
        "sha256sum": "coreutils",
        "tar": "tar",
    },
    "apk": {
        "git": "git",
        "python3": "python3",
        "rg": "ripgrep",
        "sed": "sed",
        "awk": "gawk",
        "grep": "grep",
        "find": "findutils",
        "timeout": "coreutils",
        "sha256sum": "coreutils",
        "tar": "tar",
    },
    "pacman": {
        "git": "git",
        "python3": "python",
        "rg": "ripgrep",
        "sed": "sed",
        "awk": "gawk",
        "grep": "grep",
        "find": "findutils",
        "timeout": "coreutils",
        "sha256sum": "coreutils",
        "tar": "tar",
    },
    "brew": {
        "git": "git",
        "python3": "python",
        "rg": "ripgrep",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Check bundle capabilities or explicitly install missing system packages. "
            "Model CLIs, credentials, and optional GitHub tooling are never installed."
        )
    )
    parser.add_argument("action", choices=("check", "install"), nargs="?", default="check")
    parser.add_argument("--repo", default=os.getcwd(), help="target repository")
    parser.add_argument(
        "--package-manager",
        choices=tuple(PACKAGE_NAMES),
        help="override package-manager detection",
    )
    parser.add_argument(
        "--search-path",
        default=os.environ.get("PATH", ""),
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the install command without running it",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="make optional and operator-managed capability warnings fail",
    )
    return parser.parse_args()


def read_text(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError, UnicodeError):
        return ""


def active_capabilities(repo: pathlib.Path) -> list[Capability]:
    profile = read_text(repo / ".review-hooks.conf")
    package_json = read_text(repo / "package.json")
    ai_review = bool(
        re.search(r"(?m)^[ \t]*AI_REVIEW_ENABLED=1(?:[ \t]|$)", profile)
    )
    profile_uses_node = bool(re.search(r"(?<![\w-])(?:node|pnpm)(?![\w-])", profile))
    profile_uses_pnpm = bool(re.search(r"(?<![\w-])pnpm(?![\w-])", profile))
    node_project = (
        bool(package_json)
        or (repo / "pnpm-lock.yaml").is_file()
        or profile_uses_node
    )
    pnpm_project = (
        (repo / "pnpm-lock.yaml").is_file()
        or bool(re.search(r'"packageManager"\s*:\s*"pnpm@', package_json))
        or profile_uses_pnpm
    )

    return [
        Capability("git", "repository inspection and installation", "required"),
        Capability("python3", "configuration, packaging, and dependency checks", "required"),
        Capability("rg", "fast repository-aware skill searches", "required"),
        Capability("sed", "bounded source and diff inspection", "required"),
        Capability("awk", "review-gate parsing", "required"),
        Capability("grep", "hook and policy checks", "required"),
        Capability("find", "skill and policy discovery", "required"),
        Capability(
            "claude",
            "Claude delegation, review, and peer deliberation",
            "manual",
            installable=False,
        ),
        Capability(
            "codex",
            "Codex implementation, review, and peer deliberation",
            "manual",
            installable=False,
        ),
        Capability(
            "timeout",
            "bounded AI pre-push review",
            "conditional",
            active=ai_review,
        ),
        Capability(
            "sha256sum",
            "AI-review result caching",
            "conditional",
            active=ai_review,
        ),
        Capability(
            "node",
            "target repository JavaScript checks",
            "conditional",
            active=node_project,
            installable=False,
        ),
        Capability(
            "pnpm",
            "target repository pnpm checks",
            "conditional",
            active=pnpm_project,
            installable=False,
        ),
        Capability("tar", "release archive maintenance", "maintenance", active=False),
        Capability(
            "gh",
            "GitHub-aware review and pull-request flows",
            "optional",
            installable=False,
        ),
    ]


def is_available(command: str, search_path: str) -> bool:
    return shutil.which(command, path=search_path) is not None


def gh_authenticated(search_path: str) -> bool:
    gh_path = shutil.which("gh", path=search_path)
    if not gh_path:
        return False
    return (
        subprocess.run(
            [gh_path, "auth", "status"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
        == 0
    )


def report(
    capabilities: list[Capability], search_path: str
) -> tuple[list[Capability], int, int]:
    missing_installable: list[Capability] = []
    blocking = 0
    warnings = 0

    print("Dependency capabilities")
    for capability in capabilities:
        available = is_available(capability.command, search_path)
        if available:
            if capability.command == "gh":
                if gh_authenticated(search_path):
                    print(f"PASS  {capability.command:<10} {capability.purpose} (authenticated)")
                else:
                    warnings += 1
                    print(
                        f"WARN  {capability.command:<10} {capability.purpose} "
                        "(installed; authentication is operator-managed)"
                    )
            else:
                print(f"PASS  {capability.command:<10} {capability.purpose}")
            continue

        if not capability.active:
            print(
                f"INFO  {capability.command:<10} {capability.purpose} "
                f"({capability.level}; inactive)"
            )
            continue

        if capability.level == "optional":
            warnings += 1
            print(f"WARN  {capability.command:<10} {capability.purpose} (optional)")
            continue

        if capability.level == "manual":
            warnings += 1
            print(
                f"WARN  {capability.command:<10} {capability.purpose}; "
                "install and authenticate it explicitly"
            )
            continue

        blocking += 1
        marker = "FAIL"
        remediation = (
            "eligible for --install-deps"
            if capability.installable
            else "manual installation required"
        )
        print(f"{marker}  {capability.command:<10} {capability.purpose}; {remediation}")
        if capability.installable:
            missing_installable.append(capability)

    print(
        "\nPolicy: system packages install only on explicit request; "
        "Claude, Codex, gh, and credentials remain operator-managed."
    )
    return missing_installable, blocking, warnings


def detect_package_manager(search_path: str) -> str | None:
    for name in ("apt-get", "dnf", "yum", "apk", "pacman", "brew"):
        if shutil.which(name, path=search_path):
            return "apt" if name == "apt-get" else name
    if platform.system() == "Darwin" and shutil.which("brew"):
        return "brew"
    return None


def install_command(manager: str, packages: list[str], search_path: str) -> list[str]:
    if manager == "apt":
        command = ["apt-get", "install", "-y", *packages]
    elif manager in ("dnf", "yum"):
        command = [manager, "install", "-y", *packages]
    elif manager == "apk":
        command = ["apk", "add", *packages]
    elif manager == "pacman":
        command = ["pacman", "-S", "--needed", "--noconfirm", *packages]
    else:
        command = ["brew", "install", *packages]

    if (
        manager != "brew"
        and hasattr(os, "geteuid")
        and os.geteuid() != 0
        and shutil.which("sudo", path=search_path)
    ):
        command.insert(0, "sudo")
    return command


def main() -> int:
    args = parse_args()
    repo = pathlib.Path(args.repo).expanduser().resolve()
    if not (repo / ".git").exists():
        completed = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            print(f"dependency check target is not a Git repository: {repo}", file=sys.stderr)
            return 2
        repo = pathlib.Path(completed.stdout.strip())

    capabilities = active_capabilities(repo)
    missing, blocking, warnings = report(capabilities, args.search_path)
    if args.action == "check":
        return 1 if blocking or (args.strict and warnings) else 0

    if not missing:
        print("\nNo missing system packages are eligible for automatic installation.")
        return 1 if blocking else 0

    manager = args.package_manager or detect_package_manager(args.search_path)
    if not manager:
        print(
            "\nNo supported package manager was detected; install the FAIL items manually.",
            file=sys.stderr,
        )
        return 1

    package_map = PACKAGE_NAMES[manager]
    packages = sorted(
        {
            package_map[capability.command]
            for capability in missing
            if capability.command in package_map
        }
    )
    if not packages:
        print("\nNo missing dependencies have a safe package mapping.", file=sys.stderr)
        return 1

    command = install_command(manager, packages, args.search_path)
    print(f"\nInstall command: {shlex.join(command)}")
    if args.dry_run:
        print("Dry run only; no packages were installed.")
        return 0

    completed = subprocess.run(command, check=False)
    if completed.returncode != 0:
        return completed.returncode

    _, remaining, _ = report(capabilities, os.environ.get("PATH", ""))
    return 1 if remaining else 0


if __name__ == "__main__":
    raise SystemExit(main())
