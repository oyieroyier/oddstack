#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  review-hooks/install.sh [options]
  review-hooks/install.sh --deactivate [--repo PATH]

Options:
  --repo PATH              Target Git repository (default: current directory)
  --profile NAME|PATH      generic, lmm.example, or a profile file
  --force                  Update an existing collaboration-hooks installation
  --no-activate            Install files without changing core.hooksPath
  --replace-hooks-path     Replace another configured hooks path and remember it
  --dry-run                Validate and report without changing files or Git config
  --deactivate             Restore the hooks path that this installer replaced
  --help                   Show this help

The installer never replaces another hook path unless --replace-hooks-path is
explicitly supplied. Deactivation preserves installed files so removal remains
a normal, reviewable Git change.
EOF
}

repo_input="$PWD"
profile_input="generic"
force=0
activate=1
replace_hooks_path=0
dry_run=0
deactivate=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      repo_input="$2"
      shift 2
      ;;
    --profile)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      profile_input="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    --no-activate)
      activate=0
      shift
      ;;
    --replace-hooks-path)
      replace_hooks_path=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --deactivate)
      deactivate=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null || true)"

if [ -z "$repo_root" ]; then
  echo "[review-hooks] not a Git repository: $repo_input" >&2
  exit 2
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "[review-hooks] Bash 4 or newer is required" >&2
  exit 2
fi

runtime_dir="$repo_root/.review-hooks"
hooks_dir="$repo_root/.collaboration-hooks"
profile_dst="$repo_root/.review-hooks.conf"
previous_path_file="$runtime_dir/previous-hooks-path"
installed_hooks_path=".collaboration-hooks"
current_hooks_path="$(git -C "$repo_root" config --local --get core.hooksPath || true)"

if [ "$deactivate" = "1" ]; then
  if [ "$current_hooks_path" != "$installed_hooks_path" ]; then
    echo "[review-hooks] refusing to deactivate: core.hooksPath is '${current_hooks_path:-unset}'" >&2
    exit 2
  fi

  previous_hooks_path="__UNSET__"
  if [ -f "$previous_path_file" ]; then
    previous_hooks_path="$(sed -n '1p' "$previous_path_file")"
  fi

  if [ "$dry_run" = "1" ]; then
    echo "[review-hooks] dry run: would restore hooks path '${previous_hooks_path:-unset}'"
    exit 0
  fi

  if [ "$previous_hooks_path" = "__UNSET__" ] || [ -z "$previous_hooks_path" ]; then
    git -C "$repo_root" config --local --unset-all core.hooksPath || true
    echo "[review-hooks] deactivated; core.hooksPath is now unset"
  else
    git -C "$repo_root" config --local core.hooksPath "$previous_hooks_path"
    echo "[review-hooks] deactivated; restored core.hooksPath=$previous_hooks_path"
  fi

  echo "[review-hooks] installed files were preserved for reviewable removal"
  exit 0
fi

case "$profile_input" in
  generic | lmm.example)
    profile_src="$bundle_root/profiles/$profile_input.conf"
    ;;
  *)
    profile_src="$profile_input"
    ;;
esac

if [ ! -f "$profile_src" ]; then
  echo "[review-hooks] profile not found: $profile_src" >&2
  exit 2
fi

if ! bash -n "$profile_src"; then
  echo "[review-hooks] profile is not valid Bash: $profile_src" >&2
  exit 2
fi

profile_ai_enabled="$(
  bash -c '. "$1"; printf "%s" "${AI_REVIEW_ENABLED:-0}"' _ "$profile_src"
)"
if [ "$profile_ai_enabled" = "1" ]; then
  for required_command in timeout sha256sum; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
      echo "[review-hooks] AI review requires: $required_command" >&2
      exit 2
    fi
  done
  if ! command -v claude >/dev/null 2>&1; then
    echo "[review-hooks] warning: Claude CLI is not currently available" >&2
  fi
fi

if [ "$activate" = "1" ] &&
  [ -n "$current_hooks_path" ] &&
  [ "$current_hooks_path" != "$installed_hooks_path" ] &&
  [ "$replace_hooks_path" != "1" ]; then
  echo "[review-hooks] refusing to replace core.hooksPath=$current_hooks_path" >&2
  echo "[review-hooks] use --no-activate and compose manually, or explicitly pass --replace-hooks-path" >&2
  exit 2
fi

if {
  [ -e "$runtime_dir" ] ||
    [ -e "$hooks_dir" ] ||
    [ -e "$profile_dst" ]
} && [ "$force" != "1" ]; then
  echo "[review-hooks] installation files already exist; inspect them and rerun with --force" >&2
  exit 2
fi

echo "[review-hooks] repository: $repo_root"
echo "[review-hooks] profile: $profile_src"
echo "[review-hooks] activation: $activate"
if [ -n "$current_hooks_path" ]; then
  echo "[review-hooks] current hooks path: $current_hooks_path"
else
  echo "[review-hooks] current hooks path: unset"
fi

if [ "$dry_run" = "1" ]; then
  echo "[review-hooks] dry run passed; nothing changed"
  exit 0
fi

mkdir -p "$runtime_dir/scripts" "$hooks_dir"
cp "$bundle_root/scripts/"*.sh "$runtime_dir/scripts/"
cp "$bundle_root/hooks/pre-commit" "$bundle_root/hooks/pre-push" "$hooks_dir/"
cp "$bundle_root/README.md" "$runtime_dir/README.md"
cp "$profile_src" "$profile_dst"
chmod +x \
  "$runtime_dir/scripts/"*.sh \
  "$hooks_dir/pre-commit" \
  "$hooks_dir/pre-push"

if [ "$activate" = "1" ]; then
  if [ "$current_hooks_path" != "$installed_hooks_path" ]; then
    if [ -n "$current_hooks_path" ]; then
      printf '%s\n' "$current_hooks_path" > "$previous_path_file"
    else
      printf '%s\n' "__UNSET__" > "$previous_path_file"
    fi
  fi
  git -C "$repo_root" config --local core.hooksPath "$installed_hooks_path"
  echo "[review-hooks] activated core.hooksPath=$installed_hooks_path"
else
  echo "[review-hooks] files installed without activation"
fi

echo "[review-hooks] review $profile_dst before enabling AI review"
echo "[review-hooks] add ai-reviews/ to the target repository's ignore rules"
echo "[review-hooks] deactivate with: $repo_root/review-hooks/install.sh --repo \"$repo_root\" --deactivate"
