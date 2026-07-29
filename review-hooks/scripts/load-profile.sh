#!/usr/bin/env bash

load_review_hooks_profile() {
  local repo_root="$1"
  local profile_path="${REVIEW_HOOKS_PROFILE:-$repo_root/.review-hooks.conf}"

  if [ ! -f "$profile_path" ]; then
    echo "[review-hooks] missing profile: $profile_path" >&2
    echo "[review-hooks] rerun review-hooks/install.sh or set REVIEW_HOOKS_PROFILE" >&2
    return 2
  fi

  # The profile is versioned repository policy. Review it like executable code.
  # shellcheck disable=SC1090
  . "$profile_path"

  if [ "${REVIEW_HOOKS_PROFILE_VERSION:-}" != "1" ]; then
    echo "[review-hooks] unsupported profile version: ${REVIEW_HOOKS_PROFILE_VERSION:-missing}" >&2
    return 2
  fi

  : "${PRE_COMMIT_SECRET_SCAN:=1}"
  : "${PRE_COMMIT_COMMANDS:=}"
  : "${PRE_PUSH_COMMANDS:=}"
  : "${AI_REVIEW_ENABLED:=0}"
  : "${AI_REVIEW_PRODUCT_NAME:=this repository}"
  : "${AI_REVIEW_DEFAULT_BASE:=origin/main}"
  : "${AI_REVIEW_BACKEND_PATH_REGEX:=^(api/|backend/|server/|db/|migrations/|sql/)}"
  : "${AI_REVIEW_SENSITIVE_PATH_REGEX:=(^|/)\.env[^/]*$|\.pem$|\.key$}"
  : "${AI_REVIEW_SENSITIVE_PATH_ALLOW_REGEX:=\.example$}"
  : "${AI_REVIEW_TIMEOUT:=600}"
  : "${AI_REVIEW_MAX_ATTEMPTS:=2}"
  : "${AI_REVIEW_MAX_DIFF_LINES:=3000}"
  : "${AI_REVIEW_MAX_BACKEND_DIFF_LINES:=1200}"
  : "${AI_REVIEW_MAX_PROMPT_TOKENS:=32000}"
  : "${AI_REVIEW_MAX_OUTPUT_BYTES:=30000}"
  : "${AI_REVIEW_MAX_BUDGET_USD:=2.00}"
}

run_review_hook_commands() {
  local phase="$1"
  local commands="$2"
  local command

  while IFS= read -r command; do
    [ -z "$command" ] && continue
    echo "[review-hooks] $phase: $command"
    bash -o pipefail -c "$command" || {
      local status=$?
      echo "[review-hooks] $phase failed (exit $status)" >&2
      return "$status"
    }
  done <<< "$commands"
}
