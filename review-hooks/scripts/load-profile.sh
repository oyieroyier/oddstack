#!/usr/bin/env bash

load_review_hooks_profile() {
  local repo_root="$1"
  local profile_path="${REVIEW_HOOKS_PROFILE:-$repo_root/.review-hooks.conf}"

  if [ ! -f "$profile_path" ]; then
    echo "[review-hooks] missing profile: $profile_path" >&2
    echo "[review-hooks] rerun review-hooks/install.sh or set REVIEW_HOOKS_PROFILE" >&2
    return 2
  fi

  # The reviewer binary is repository policy, never caller environment: an
  # environment variable alone must not be able to point "the reviewer" at
  # an arbitrary executable and mint a cached decision.
  unset AI_REVIEW_CLAUDE_BIN

  # The profile is versioned repository policy. Review it like executable code.
  # shellcheck disable=SC1090
  . "$profile_path"

  case "${REVIEW_HOOKS_PROFILE_VERSION:-}" in
    2) ;;
    1)
      echo "[review-hooks] profile version 1 is deprecated; its timeout maps" >&2
      echo "[review-hooks] to a run-wide deadline and unconditional retries are gone" >&2
      echo "[review-hooks] migrate to version 2 (see review-hooks/README.md)" >&2
      ;;
    *)
      echo "[review-hooks] unsupported profile version: ${REVIEW_HOOKS_PROFILE_VERSION:-missing}" >&2
      return 2
      ;;
  esac

  : "${PRE_COMMIT_SECRET_SCAN:=1}"
  : "${PRE_COMMIT_COMMANDS:=}"
  : "${COMMIT_MSG_COMMANDS:=}"
  : "${PRE_PUSH_COMMANDS:=}"
  : "${AI_REVIEW_ENABLED:=0}"
  : "${AI_REVIEW_PRODUCT_NAME:=this repository}"
  : "${AI_REVIEW_DEFAULT_BASE:=origin/main}"
  : "${AI_REVIEW_BACKEND_PATH_REGEX:=^(api/|backend/|server/|db/|migrations/|sql/)}"
  : "${AI_REVIEW_SENSITIVE_PATH_REGEX:=(^|/)\.env[^/]*$|\.pem$|\.key$}"
  : "${AI_REVIEW_SENSITIVE_PATH_ALLOW_REGEX:=\.example$}"
  : "${AI_REVIEW_MAX_DIFF_LINES:=3000}"
  : "${AI_REVIEW_MAX_BACKEND_DIFF_LINES:=1200}"
  : "${AI_REVIEW_MAX_PROMPT_TOKENS:=32000}"
  : "${AI_REVIEW_MAX_OUTPUT_BYTES:=30000}"
  : "${AI_REVIEW_MAX_BUDGET_USD:=2.00}"
  : "${AI_REVIEW_KILL_GRACE:=5}"
  : "${AI_REVIEW_RETRYABLE_FAILURES:=}"
  : "${AI_REVIEW_MIN_RETRY_TIME:=30}"
  : "${AI_REVIEW_MAX_PRIOR_REPORT_BYTES:=12000}"
  : "${AI_REVIEW_MODEL:=}"
  : "${AI_REVIEW_ROLLING_SPEND_LIMIT_USD:=0}"
  : "${AI_REVIEW_ROLLING_SPEND_WINDOW_HOURS:=24}"
  : "${AI_REVIEW_STARTUP_EXIT_CODES:=}"
  : "${AI_REVIEW_BACKEND:=claude}"
  : "${AI_REVIEW_CREDENTIAL_SCOPE:=personal}"
  : "${AI_REVIEW_ALLOW_PERSONAL_QUOTA:=}"
  : "${AI_REVIEW_CLAUDE_BIN:=claude}"
  : "${AI_REVIEW_MERGE_WITH_FIXES_COMMAND:=}"

  if [ "${REVIEW_HOOKS_PROFILE_VERSION}" = "1" ]; then
    # Durable intake is version 2 policy; a version 1 profile naming it
    # must fail loudly rather than silently drop a persistence promise.
    if [ -n "${AI_REVIEW_MERGE_WITH_FIXES_COMMAND}" ]; then
      echo "[review-hooks] AI_REVIEW_MERGE_WITH_FIXES_COMMAND requires a version 2 profile" >&2
      return 2
    fi
    # Version 1 names, mapped to the safer version 2 meanings by the module.
    : "${AI_REVIEW_TIMEOUT:=600}"
    : "${AI_REVIEW_MAX_ATTEMPTS:=2}"
    : "${AI_REVIEW_PUSH_MODE:=run-if-missing}"
    : "${AI_REVIEW_TOTAL_TIMEOUT:=$AI_REVIEW_TIMEOUT}"
  else
    : "${AI_REVIEW_TOTAL_TIMEOUT:=600}"
    : "${AI_REVIEW_MAX_ATTEMPTS:=1}"
    : "${AI_REVIEW_PUSH_MODE:=verify}"
    : "${AI_REVIEW_TIMEOUT:=$AI_REVIEW_TOTAL_TIMEOUT}"
  fi

  export REVIEW_HOOKS_PROFILE_VERSION
  export AI_REVIEW_ENABLED AI_REVIEW_PRODUCT_NAME AI_REVIEW_DEFAULT_BASE
  export AI_REVIEW_BACKEND_PATH_REGEX AI_REVIEW_SENSITIVE_PATH_REGEX
  export AI_REVIEW_SENSITIVE_PATH_ALLOW_REGEX
  export AI_REVIEW_MAX_DIFF_LINES AI_REVIEW_MAX_BACKEND_DIFF_LINES
  export AI_REVIEW_MAX_PROMPT_TOKENS AI_REVIEW_MAX_OUTPUT_BYTES
  export AI_REVIEW_MAX_BUDGET_USD AI_REVIEW_TIMEOUT AI_REVIEW_TOTAL_TIMEOUT
  export AI_REVIEW_KILL_GRACE AI_REVIEW_MAX_ATTEMPTS AI_REVIEW_PUSH_MODE
  export AI_REVIEW_RETRYABLE_FAILURES AI_REVIEW_MIN_RETRY_TIME
  export AI_REVIEW_MAX_PRIOR_REPORT_BYTES AI_REVIEW_MODEL
  export AI_REVIEW_ROLLING_SPEND_LIMIT_USD AI_REVIEW_ROLLING_SPEND_WINDOW_HOURS
  export AI_REVIEW_STARTUP_EXIT_CODES
  export AI_REVIEW_BACKEND AI_REVIEW_CREDENTIAL_SCOPE
  export AI_REVIEW_ALLOW_PERSONAL_QUOTA AI_REVIEW_CLAUDE_BIN
  export AI_REVIEW_MERGE_WITH_FIXES_COMMAND
}

run_review_hook_commands() {
  local phase="$1"
  local commands="$2"
  local command

  while IFS= read -r command; do
    [ -z "$command" ] && continue
    echo "[review-hooks] $phase: $command"
    bash -o pipefail -c "$command" < /dev/null || {
      local status=$?
      echo "[review-hooks] $phase failed (exit $status)" >&2
      return "$status"
    }
  done <<< "$commands"
}
