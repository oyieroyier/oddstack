#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./install.sh [--repo PATH] [--force]
  ./install.sh PATH

Options:
  --repo PATH  Target Git repository (default: current directory)
  --force      Explicitly overwrite files in drifted bundled copies
  --help       Show this help

Existing bundled skills and review-hooks/ are compared before any files are
written. Drift is preserved and shown by default; --force is required to update
it. Installing this bundle never activates Git hooks.
EOF
}

repo_input="$PWD"
force=0
positional_repo_seen=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      repo_input="$2"
      positional_repo_seen=1
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ "$positional_repo_seen" = "1" ]; then
        echo "Only one target repository may be supplied" >&2
        exit 2
      fi
      repo_input="$1"
      positional_repo_seen=1
      shift
      ;;
  esac
done

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null || true)"

if [ -z "$repo_root" ]; then
  echo "[skills] not a Git repository: $repo_input" >&2
  exit 2
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[skills] Bash 4 or newer is required" >&2
  exit 2
fi

declare -a sources=()
declare -a destinations=()
declare -a labels=()

for skill_src in "$bundle_root"/.claude/skills/*; do
  [ -d "$skill_src" ] || continue
  sources+=("$skill_src")
  destinations+=("$repo_root/.claude/skills/$(basename "$skill_src")")
  labels+=(".claude/skills/$(basename "$skill_src")")
done

for skill_src in "$bundle_root"/.agents/skills/*; do
  [ -d "$skill_src" ] || continue
  sources+=("$skill_src")
  destinations+=("$repo_root/.agents/skills/$(basename "$skill_src")")
  labels+=(".agents/skills/$(basename "$skill_src")")
done

sources+=("$bundle_root/review-hooks")
destinations+=("$repo_root/review-hooks")
labels+=("review-hooks")

drift_found=0
for index in "${!sources[@]}"; do
  src="${sources[$index]}"
  dst="${destinations[$index]}"
  label="${labels[$index]}"

  if [ -L "$dst" ]; then
    drift_found=1
    echo "[skills] refusing to write through symlinked destination: $label" >&2
  elif [ -e "$dst" ] && ! diff -qr "$src" "$dst" >/dev/null; then
    drift_found=1
    echo "[skills] drift detected in $label" >&2
    diff -ru "$dst" "$src" >&2 || true
  fi
done

if [ "$drift_found" = "1" ] && [ "$force" != "1" ]; then
  echo "[skills] no files changed; review the diff and rerun with --force to update" >&2
  exit 2
fi

for index in "${!destinations[@]}"; do
  if [ -L "${destinations[$index]}" ]; then
    echo "[skills] symlinked destinations are never overwritten, including with --force" >&2
    exit 2
  fi
done

for index in "${!sources[@]}"; do
  src="${sources[$index]}"
  dst="${destinations[$index]}"
  label="${labels[$index]}"

  if [ -e "$dst" ] && diff -qr "$src" "$dst" >/dev/null; then
    echo "[skills] unchanged: $label"
    continue
  fi

  mkdir -p "$dst"
  cp -R "$src"/. "$dst"/
  if [ -e "$dst" ]; then
    echo "[skills] installed: $label"
  fi
done

echo "[skills] Git hooks remain inactive; use bootstrap.sh --activate or review-hooks/install.sh explicitly"
