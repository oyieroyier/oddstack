#!/usr/bin/env bash

set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=load-profile.sh
. "$script_root/load-profile.sh"
load_review_hooks_profile "$repo_root" || exit $?

push_updates="$(mktemp)"
trap 'rm -f "$push_updates"' EXIT
cat > "$push_updates"
export REVIEW_HOOKS_PUSH_UPDATES_FILE="$push_updates"

run_review_hook_commands "pre-push command" "$PRE_PUSH_COMMANDS" || exit $?

if [ "$AI_REVIEW_ENABLED" != "1" ]; then
  echo "[review-hooks] AI review disabled by profile"
  exit 0
fi

"$script_root/../bin/review-gate" check-push --updates-file "$push_updates"
