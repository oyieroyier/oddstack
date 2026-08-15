#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./install.sh [--repo PATH] [--force]
  ./install.sh --check [--repo PATH]
  ./install.sh PATH

Options:
  --repo PATH  Target Git repository (default: current directory)
  --force      Explicitly overwrite files in drifted bundled copies
  --check      Report install status and exit without writing anything
  --help       Show this help

Existing bundled skills and review-hooks/ are compared before any files are
written. Drift is preserved and shown by default; --force is required to update
it. Installing this bundle never activates Git hooks.

--check writes nothing and reports what the target repository has.

Exit codes:
  0  --check only: the target matches this bundle release
  1  --check only: missing content, drift, or a different bundle release
  2  usage error, unusable target, a missing requirement, or unreviewed drift
     during an install (rerun with --force after reviewing the diff)
EOF
}

repo_input="$PWD"
force=0
check=0
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
    --check)
      check=1
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

if [ "$check" = "1" ] && [ "$force" = "1" ]; then
  echo "[skills] --check never writes; drop --force" >&2
  exit 2
fi

# -P resolves symlinks, so this is comparable with the physical path
# `git rev-parse --show-toplevel` reports. Without it, invoking the bundle
# through a symlink defeats the bundle-root guard below.
bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ ! -f "$bundle_root/scripts/bundle-version.sh" ]; then
  echo "[skills] incomplete bundle, missing: scripts/bundle-version.sh" >&2
  exit 2
fi
# shellcheck source=scripts/bundle-version.sh
. "$bundle_root/scripts/bundle-version.sh"

# Completeness is checked against the shared manifest, not a hand-kept list, so
# it stays aligned with what the digests consume.
bundle_missing="$(bundle_missing_paths "$bundle_root")"
if [ -n "$bundle_missing" ]; then
  echo "[skills] incomplete bundle, missing:" >&2
  printf '  %s\n' $bundle_missing >&2
  exit 2
fi
repo_root="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null || true)"

if [ -z "$repo_root" ]; then
  echo "[skills] not a Git repository: $repo_input" >&2
  exit 2
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[skills] Bash 4 or newer is required" >&2
  exit 2
fi

# The bundle is the source of an install, never a target of one. Without this,
# a sweep over a directory of repositories reports the bundle as permanently
# out of date, and --force would write a stray stamp into the bundle root.
if [ "$repo_root" = "$bundle_root" ]; then
  if [ "$check" = "1" ]; then
    echo "[skills] $repo_root is the bundle source, not an install target"
    exit 0
  fi
  echo "[skills] refusing to install the bundle into itself: $repo_root" >&2
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

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "[skills] sha256sum is required to stamp and verify an install" >&2
  exit 2
fi

stamp_path="$repo_root/$BUNDLE_STAMP_FILE"
bundle_release="$(bundle_version "$bundle_root")"
# A digest failure means the bundle is unusable, not that the target drifted.
# Exit 2 ("a missing requirement") rather than letting set -e surface 1.
if ! bundle_digest="$(bundle_source_digest "$bundle_root")"; then
  echo "[skills] cannot digest this bundle; it is incomplete" >&2
  exit 2
fi

if [ "$check" = "1" ]; then
  stale=0

  for index in "${!sources[@]}"; do
    src="${sources[$index]}"
    dst="${destinations[$index]}"
    label="${labels[$index]}"

    if [ -L "$dst" ]; then
      stale=1
      echo "[skills] symlink   $label"
    elif [ ! -e "$dst" ]; then
      stale=1
      echo "[skills] missing   $label"
    elif diff -qr "${BUNDLE_DIFF_EXCLUDES[@]}" "$src" "$dst" >/dev/null; then
      echo "[skills] current   $label"
    else
      stale=1
      echo "[skills] drifted   $label"
    fi
  done

  installed_release="$(bundle_stamp_field "$stamp_path" version)"
  installed_digest="$(bundle_stamp_field "$stamp_path" source-digest)"

  # Separate the two ways a stamp can disagree: a different release number is a
  # plain upgrade, while a matching number with a different digest means the
  # same release was built from different content.
  if [ -z "$installed_release" ]; then
    stale=1
    echo "[skills] unstamped bundle version; the install predates $bundle_release"
  elif [ "$installed_release" != "$bundle_release" ]; then
    stale=1
    echo "[skills] stamped $installed_release, a different bundle release than $bundle_release"
  elif [ "$installed_digest" = "$bundle_digest" ]; then
    echo "[skills] stamped $installed_release matching this bundle release"
  else
    stale=1
    echo "[skills] stamped $installed_release from another build of the bundle"
  fi

  if [ "$stale" = "1" ]; then
    echo "[skills] $repo_root is out of date; rerun install.sh --force to update"
    exit 1
  fi

  echo "[skills] $repo_root matches bundle $bundle_release"
  exit 0
fi

drift_found=0
for index in "${!sources[@]}"; do
  src="${sources[$index]}"
  dst="${destinations[$index]}"
  label="${labels[$index]}"

  if [ -L "$dst" ]; then
    drift_found=1
    echo "[skills] refusing to write through symlinked destination: $label" >&2
  elif [ -e "$dst" ] && ! diff -qr "${BUNDLE_DIFF_EXCLUDES[@]}" "$src" "$dst" >/dev/null; then
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

  if [ -e "$dst" ] && diff -qr "${BUNDLE_DIFF_EXCLUDES[@]}" "$src" "$dst" >/dev/null; then
    echo "[skills] unchanged: $label"
    continue
  fi

  mkdir -p "$dst"
  cp -R "$src"/. "$dst"/
  find "$dst" \( -name __pycache__ -o -name '*.pyc' -o -name .pytest_cache \) \
    -exec rm -rf {} + 2>/dev/null || true
  if [ -e "$dst" ]; then
    echo "[skills] installed: $label"
  fi
done

# Stamp the repository with the bundle release its skills came from, so
# install.sh --check and doctor.sh can tell an older release apart from a
# local edit. Rewritten only when it would change, to keep reinstalls of
# identical content free of spurious diffs.
stamp_contents="$(
  printf 'version: %s\n' "$bundle_release"
  printf 'source-digest: %s\n' "$bundle_digest"
)"
if [ ! -f "$stamp_path" ] || [ "$(cat "$stamp_path")" != "$stamp_contents" ]; then
  printf '%s\n' "$stamp_contents" > "$stamp_path"
  echo "[skills] stamped: $BUNDLE_STAMP_FILE ($bundle_release)"
fi

echo "[skills] Git hooks remain inactive; use bootstrap.sh --activate or review-hooks/install.sh explicitly"
