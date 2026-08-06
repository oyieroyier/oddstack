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
    if ! bash -n "$file"; then
      echo "==> bash syntax: FAILED on $file" >&2
      status=1
    fi
  done
  return "$status"
}

shell_sources=("$bundle_root"/*.sh "$bundle_root"/review-hooks/install.sh
  "$bundle_root"/review-hooks/scripts/*.sh "$bundle_root"/review-hooks/hooks/*
  "$bundle_root"/review-hooks/bin/review-gate "$bundle_root"/tests/run.sh
  "$bundle_root"/review-hooks/tests/run.sh)
run_step "bash syntax" check_shell_syntax "${shell_sources[@]}"
run_step "bundle suite" bash "$bundle_root/tests/run.sh"
run_step "review-hooks suite" bash "$bundle_root/review-hooks/tests/run.sh"
run_step "release archives" "$bundle_root/package.sh" --check
run_step "whitespace" git -C "$bundle_root" diff --check

if [ "$overall" -ne 0 ]; then
  echo "verification failed" >&2
  exit 1
fi
echo "all suites passed"
