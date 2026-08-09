#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run-codex-peer.sh --prompt-file PATH --deliberation-file PATH [options]

Options:
  --repo PATH          Target Git repository (default: current directory)
  --resume ID          Resume this exact Codex session
  --model MODEL        Override configured Codex model
  --effort LEVEL       Override configured Codex reasoning effort
  --preferences PATH   Read user preferences from this JSON file
  --dry-run            Validate and print the resolved invocation
  --help               Show this help
EOF
}

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_input="$PWD"
prompt_file=""
deliberation_file=""
resume_id=""
model=""
effort=""
preferences_path=""
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo | --prompt-file | --deliberation-file | --resume | --model | --effort | --preferences)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      case "$1" in
        --repo) repo_input="$2" ;;
        --prompt-file) prompt_file="$2" ;;
        --deliberation-file) deliberation_file="$2" ;;
        --resume) resume_id="$2" ;;
        --model) model="$2" ;;
        --effort) effort="$2" ;;
        --preferences) preferences_path="$2" ;;
      esac
      shift 2
      ;;
    --dry-run)
      dry_run=1
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

[ -n "$prompt_file" ] && [ -s "$prompt_file" ] || {
  echo "[peer-codex] --prompt-file must name a non-empty file" >&2
  exit 2
}
[ -n "$deliberation_file" ] || {
  echo "[peer-codex] --deliberation-file is required" >&2
  exit 2
}
command -v git >/dev/null 2>&1 || {
  echo "[peer-codex] git is unavailable" >&2
  exit 127
}
command -v python3 >/dev/null 2>&1 || {
  echo "[peer-codex] python3 is unavailable" >&2
  exit 127
}

repo_root="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || {
  echo "[peer-codex] not a Git repository: $repo_input" >&2
  exit 2
}
case "$deliberation_file" in
  /*) deliberation_path="$deliberation_file" ;;
  *) deliberation_path="$repo_root/$deliberation_file" ;;
esac
case "$deliberation_path" in
  "$repo_root"/plans/model-deliberations/*.md) ;;
  *)
    echo "[peer-codex] deliberation must be under plans/model-deliberations/" >&2
    exit 2
    ;;
esac
[ -s "$deliberation_path" ] || {
  echo "[peer-codex] deliberation record is missing or empty: $deliberation_path" >&2
  exit 2
}
for marker in "Status:" "Next owner:" "## Task" "## Disagreement ledger" "## Resume"; do
  grep -Fq "$marker" "$deliberation_path" || {
    echo "[peer-codex] deliberation record is missing marker: $marker" >&2
    exit 2
  }
done

if [ -z "$preferences_path" ]; then
  user_root="${HOME:-}"
  if [ -n "$user_root" ]; then
    preferences_path="${XDG_CONFIG_HOME:-$user_root/.config}/codex-claude-skills/preferences.json"
  fi
fi
session_policy="resume-within-task"
max_rounds="2"
if [ -n "$preferences_path" ] && [ -f "$preferences_path" ]; then
  [ -n "$model" ] || model="$("$script_root/read-preference.py" "$preferences_path" codex.model)"
  [ -n "$effort" ] || effort="$("$script_root/read-preference.py" "$preferences_path" codex.effort)"
  configured_policy="$("$script_root/read-preference.py" "$preferences_path" deliberation.sessionPolicy)"
  configured_rounds="$("$script_root/read-preference.py" "$preferences_path" deliberation.maxRounds)"
  [ -z "$configured_policy" ] || session_policy="$configured_policy"
  [ -z "$configured_rounds" ] || max_rounds="$configured_rounds"
fi

case "$session_policy" in
  resume-within-task | fresh-each-round | ephemeral) ;;
  *)
    echo "[peer-codex] unsupported session policy: $session_policy" >&2
    exit 2
    ;;
esac
if ! [[ "$max_rounds" =~ ^[1-9][0-9]*$ ]]; then
  echo "[peer-codex] maxRounds must be a positive integer" >&2
  exit 2
fi
calls_completed="$(sed -n 's/^- Calls completed: \([0-9][0-9]*\)$/\1/p' "$deliberation_path" | head -1)"
if [ -n "$calls_completed" ] && [ "$calls_completed" -ge "$max_rounds" ]; then
  echo "[peer-codex] configured round limit reached ($calls_completed/$max_rounds)" >&2
  exit 3
fi
if [ "$session_policy" = "resume-within-task" ] &&
  [ -n "$calls_completed" ] &&
  [ "$calls_completed" -gt 0 ] &&
  [ -z "$resume_id" ]; then
  echo "[peer-codex] resume-within-task requires --resume after the first peer call" >&2
  exit 2
fi
if [ "$session_policy" = "ephemeral" ] && [ -n "$resume_id" ]; then
  echo "[peer-codex] ephemeral sessions cannot be resumed" >&2
  exit 2
fi
if [ "$session_policy" = "fresh-each-round" ] && [ -n "$resume_id" ]; then
  echo "[peer-codex] fresh-each-round forbids --resume" >&2
  exit 2
fi
if [ -n "$resume_id" ] && ! [[ "$resume_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
  echo "[peer-codex] --resume must be an alphanumeric session id" >&2
  exit 2
fi

echo "[peer-codex] repository: $repo_root"
echo "[peer-codex] deliberation: ${deliberation_path#"$repo_root"/}"
echo "[peer-codex] session: ${resume_id:-new}"
echo "[peer-codex] model: ${model:-environment default}"
echo "[peer-codex] effort: ${effort:-environment default}"
echo "[peer-codex] session policy: $session_policy"
if [ "$dry_run" = "1" ]; then
  echo "[peer-codex] dry run passed; Codex was not launched"
  exit 0
fi
command -v codex >/dev/null 2>&1 || {
  echo "[peer-codex] Codex CLI is unavailable" >&2
  exit 127
}

event_file="$(mktemp)"
output_file="$(mktemp)"
trap 'rm -f "$event_file" "$output_file"' EXIT
if [ -n "$resume_id" ]; then
  # `codex exec resume` does not accept the top-level `-s` flag. Pin the
  # equivalent config values so a resumed peer cannot inherit write access.
  codex_args=(
    exec resume --json -o "$output_file"
    -c 'sandbox_mode="read-only"'
    -c 'approval_policy="never"'
  )
  [ -z "$model" ] || codex_args+=(-m "$model")
  [ -z "$effort" ] || codex_args+=(-c "model_reasoning_effort=\"$effort\"")
  codex_args+=("$resume_id" -)
else
  codex_args=(
    exec --json -o "$output_file" -s read-only -C "$repo_root"
    -c 'approval_policy="never"'
  )
  [ -z "$model" ] || codex_args+=(-m "$model")
  [ -z "$effort" ] || codex_args+=(-c "model_reasoning_effort=\"$effort\"")
  [ "$session_policy" != "ephemeral" ] || codex_args+=(--ephemeral)
  codex_args+=(-)
fi

set +e
{
  cat "$prompt_file"
  printf '\n\nRead `%s` as the durable deliberation record. Ground every claim against repository evidence. Return only your peer position; do not modify files. The initiating model will record and adjudicate it.\n' \
    "${deliberation_path#"$repo_root"/}"
} | (
  cd "$repo_root"
  codex "${codex_args[@]}"
) >"$event_file"
codex_status=$?
set -e
if [ "$codex_status" -ne 0 ]; then
  echo "[peer-codex] Codex exited with status $codex_status" >&2
  echo "[peer-codex] record BLOCKED_CODEX_CAPACITY or BLOCKED_EXECUTION and preserve the open disagreement" >&2
  exit "$codex_status"
fi
[ -s "$output_file" ] || {
  echo "[peer-codex] Codex returned no final response" >&2
  exit 4
}
cat "$output_file"
session_id="$(
  python3 - "$event_file" <<'PY'
import json
import pathlib
import sys

for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("type") == "thread.started":
        value = event.get("thread_id") or event.get("thread", {}).get("id")
        if value:
            print(value)
            break
PY
)"
if [ -n "$resume_id" ]; then
  session_id="$resume_id"
fi
if [ -n "$session_id" ]; then
  echo "[peer-codex] resume session: $session_id" >&2
else
  echo "[peer-codex] warning: CLI did not expose a resumable session id" >&2
fi
