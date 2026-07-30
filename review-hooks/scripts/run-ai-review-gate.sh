#!/usr/bin/env bash
# Compatibility adapter for one release. It captures Git's pre-push
# standard input and forwards it to `review-gate check-push`. New callers
# should use .review-hooks/bin/review-gate directly.

set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)"
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[review-hooks] run-ai-review-gate.sh is a compatibility adapter and" >&2
echo "[review-hooks] will be removed; call bin/review-gate check-push instead" >&2

# shellcheck source=load-profile.sh
. "$script_root/load-profile.sh"
load_review_hooks_profile "$repo_root" || exit $?

if [ "$AI_REVIEW_ENABLED" != "1" ]; then
  echo "[review-hooks] AI review disabled by profile"
  exit 0
fi

updates_file="$(mktemp)"
trap 'rm -f "$updates_file"' EXIT
cat > "$updates_file"

"$script_root/../bin/review-gate" check-push --updates-file "$updates_file"
