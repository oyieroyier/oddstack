#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./bootstrap.sh [--repo PATH] [--activate] [--profile NAME|PATH]
                 [--force-skills] [--force-hooks] [--replace-hooks-path]
                 [--claude-alert ask|enable|skip]

The bootstrap always diagnoses first, installs from this directory, and
diagnoses again. --activate is the explicit authorization to configure
core.hooksPath and enable the deterministic hardening gates. It does not enable
AI review, add CI secrets, configure branch protection, or approve pages.
In an interactive terminal it asks whether to enable Claude Code's user-level
completion bell. Automation can choose with --claude-alert.
EOF
}

repo_input="$PWD"
activate=0
profile="generic"
force_skills=0
force_hooks=0
replace_hooks_path=0
claude_alert="ask"

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
    --activate)
      activate=1
      shift
      ;;
    --profile)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      profile="$2"
      shift 2
      ;;
    --force-skills)
      force_skills=1
      shift
      ;;
    --force-hooks)
      force_hooks=1
      shift
      ;;
    --replace-hooks-path)
      replace_hooks_path=1
      shift
      ;;
    --claude-alert)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      claude_alert="$2"
      shift 2
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

case "$claude_alert" in
  ask | enable | skip) ;;
  *)
    echo "[bootstrap] --claude-alert must be ask, enable, or skip" >&2
    exit 2
    ;;
esac

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null || true)"

if [ -z "$repo_root" ]; then
  echo "[bootstrap] not a Git repository: $repo_input" >&2
  exit 2
fi

echo "[bootstrap] preflight diagnosis"
"$bundle_root/doctor.sh" --repo "$repo_root" --skip-archives

install_args=(--repo "$repo_root")
if [ "$force_skills" = "1" ]; then
  install_args+=(--force)
fi
"$bundle_root/install.sh" "${install_args[@]}"

if [ "$activate" = "1" ]; then
  hook_args=(--repo "$repo_root" --profile "$profile")
  if [ "$force_hooks" = "1" ]; then
    hook_args+=(--force)
  fi
  if [ "$replace_hooks_path" = "1" ]; then
    hook_args+=(--replace-hooks-path)
  fi
  "$repo_root/review-hooks/install.sh" "${hook_args[@]}"
else
  echo "[bootstrap] hardening gates remain inactive; rerun with --activate after review"
fi

if [ "$claude_alert" = "ask" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    read -r -p "Enable Claude Code terminal-bell alerts when it needs attention? [y/N] " alert_reply
    case "$alert_reply" in
      y | Y | yes | YES) claude_alert="enable" ;;
      *) claude_alert="skip" ;;
    esac
  else
    echo "[bootstrap] non-interactive run: Claude completion alert left unchanged"
    claude_alert="skip"
  fi
fi
if [ "$claude_alert" = "enable" ]; then
  python3 "$bundle_root/scripts/configure-claude-alert.py"
else
  echo "[bootstrap] Claude completion alert left unchanged"
fi

echo "[bootstrap] final diagnosis"
"$bundle_root/doctor.sh" --repo "$repo_root" --skip-archives
