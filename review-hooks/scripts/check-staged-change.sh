#!/usr/bin/env bash

set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=load-profile.sh
. "$script_root/load-profile.sh"
load_review_hooks_profile "$repo_root" || exit $?

mapfile -d '' staged_files < <(
  git diff --cached --name-only --diff-filter=ACMR -z
)

[ "${#staged_files[@]}" -eq 0 ] && exit 0

echo "[review-hooks] deterministic checks for ${#staged_files[@]} staged file(s)"

git diff --cached --check || exit $?

if [ "$PRE_COMMIT_SECRET_SCAN" = "1" ]; then
  patch="$(git diff --cached --no-color --unified=0)"
  findings="$(
    printf '%s\n' "$patch" |
      awk '/^\+/ && !/^\+\+\+/' |
      grep -E \
        -- '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|(^|[^A-Z0-9])AKIA[0-9A-Z]{16}([^A-Z0-9]|$)|(^|[^A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{30,}([^A-Za-z0-9]|$)|(^|[^A-Za-z0-9])sk-(proj-)?[A-Za-z0-9_-]{20,}([^A-Za-z0-9_-]|$)' |
      head -n 10 || true
  )"

  if [ -n "$findings" ]; then
    echo "[review-hooks] possible secret in staged added lines:" >&2
    printf '%s\n' "$findings" |
      sed -E 's/^(.{0,16}).*$/  \1…[redacted]/' >&2
    echo "[review-hooks] remove it or set PRE_COMMIT_SECRET_SCAN=0 after manual verification" >&2
    exit 1
  fi
fi

staged_file_list="$(mktemp)"
trap 'rm -f "$staged_file_list"' EXIT
printf '%s\n' "${staged_files[@]}" > "$staged_file_list"
export REVIEW_HOOKS_STAGED_FILES_FILE="$staged_file_list"

run_review_hook_commands "pre-commit command" "$PRE_COMMIT_COMMANDS" || exit $?

echo "[review-hooks] deterministic checks passed"
