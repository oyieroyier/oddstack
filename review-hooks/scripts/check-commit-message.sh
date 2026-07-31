#!/usr/bin/env bash

set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=load-profile.sh
. "$script_root/load-profile.sh"
load_review_hooks_profile "$repo_root" || exit $?

[ -z "$COMMIT_MSG_COMMANDS" ] && exit 0

message_file="${1:-}"
case "$message_file" in
  /*) ;;
  ?*) message_file="$repo_root/$message_file" ;;
esac

if [ -z "$message_file" ] || [ ! -f "$message_file" ]; then
  echo "[review-hooks] commit-msg: message file not found: ${1:-}" >&2
  exit 2
fi

export REVIEW_HOOKS_COMMIT_MSG_FILE="$message_file"

run_review_hook_commands "commit-msg command" "$COMMIT_MSG_COMMANDS" || exit $?
