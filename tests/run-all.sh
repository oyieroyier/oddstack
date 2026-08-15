#!/usr/bin/env bash
# Single verification entry point: syntax checks, both suites, archive check.

set -uo pipefail

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
overall=0

run_step() {
  local label="$1"
  shift
  echo "==> $label"
  if "$@"; then
    echo "==> $label: ok"
  else
    echo "==> $label: FAILED" >&2
    overall=1
  fi
}

# NOTE: `bash -n` only checks the FIRST file given when passed multiple file
# arguments; additional arguments become positional parameters ($1, $2, ...)
# of that first script rather than additional files to check. So every
# source is checked individually in a loop instead of in one `bash -n` call.
check_shell_syntax() {
  local file status=0
  for file in "$@"; do
    # A glob that matched nothing arrives here with its metacharacter intact;
    # skip only those. A named path that is missing must still fail, or renaming
    # a checked script would silently drop its coverage.
    case "$file" in
      *'*'*) continue ;;
    esac
    if ! bash -n "$file"; then
      echo "==> bash syntax: FAILED on $file" >&2
      status=1
    fi
  done
  return "$status"
}

shell_sources=("$bundle_root"/*.sh "$bundle_root"/scripts/*.sh
  "$bundle_root"/.agents/skills/*/scripts/*.sh
  "$bundle_root"/.claude/skills/*/scripts/*.sh
  "$bundle_root"/review-hooks/install.sh
  "$bundle_root"/review-hooks/scripts/*.sh "$bundle_root"/review-hooks/hooks/*
  "$bundle_root"/review-hooks/bin/review-gate "$bundle_root"/tests/run.sh
  "$bundle_root"/review-hooks/tests/run.sh)
run_step "bash syntax" check_shell_syntax "${shell_sources[@]}"

# The integration-review readiness validator is the bundle's only JavaScript.
# It ships to repositories that may hold no other JS, so nothing else would
# catch a syntax error in it.
check_node_syntax() {
  local script="$bundle_root/.agents/skills/integration-review/scripts/check-integration-review-readiness.mjs"
  if ! command -v node >/dev/null 2>&1; then
    echo "==> node syntax: skipped, node is not installed" >&2
    return 0
  fi
  node --check "$script"
}
run_step "node syntax" check_node_syntax
run_step "bundle suite" bash "$bundle_root/tests/run.sh"
run_step "review-hooks suite" bash "$bundle_root/review-hooks/tests/run.sh"
run_step "release archives" "$bundle_root/package.sh" --check
run_step "whitespace" git -C "$bundle_root" diff --check

if [ "$overall" -ne 0 ]; then
  echo "verification failed" >&2
  exit 1
fi
echo "all suites passed"
