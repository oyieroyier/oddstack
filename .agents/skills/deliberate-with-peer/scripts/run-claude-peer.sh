#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run-claude-peer.sh --prompt-file PATH --deliberation-file PATH [options]

Options:
  --repo PATH          Target Git repository (default: current directory)
  --resume ID          Resume this exact Claude session
  --model MODEL        Override configured Claude model
  --effort LEVEL       Override configured Claude effort
  --max-budget-usd N   Set Claude print-mode budget
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
max_budget=""
preferences_path=""
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo | --prompt-file | --deliberation-file | --resume | --model | --effort | --max-budget-usd | --preferences)
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
        --max-budget-usd) max_budget="$2" ;;
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
  echo "[peer-claude] --prompt-file must name a non-empty file" >&2
  exit 2
}
[ -n "$deliberation_file" ] || {
  echo "[peer-claude] --deliberation-file is required" >&2
  exit 2
}
command -v git >/dev/null 2>&1 || {
  echo "[peer-claude] git is unavailable" >&2
  exit 127
}
command -v python3 >/dev/null 2>&1 || {
  echo "[peer-claude] python3 is unavailable" >&2
  exit 127
}

repo_root="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || {
  echo "[peer-claude] not a Git repository: $repo_input" >&2
  exit 2
}
case "$deliberation_file" in
  /*) deliberation_path="$deliberation_file" ;;
  *) deliberation_path="$repo_root/$deliberation_file" ;;
esac
case "$deliberation_path" in
  "$repo_root"/plans/model-deliberations/*.md) ;;
  *)
    echo "[peer-claude] deliberation must be under plans/model-deliberations/" >&2
    exit 2
    ;;
esac
[ -s "$deliberation_path" ] || {
  echo "[peer-claude] deliberation record is missing or empty: $deliberation_path" >&2
  exit 2
}
for marker in "Status:" "Next owner:" "## Task" "## Disagreement ledger" "## Resume"; do
  grep -Fq "$marker" "$deliberation_path" || {
    echo "[peer-claude] deliberation record is missing marker: $marker" >&2
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
  [ -n "$model" ] || model="$("$script_root/read-preference.py" "$preferences_path" claude.model)"
  [ -n "$effort" ] || effort="$("$script_root/read-preference.py" "$preferences_path" claude.effort)"
  [ -n "$max_budget" ] ||
    max_budget="$("$script_root/read-preference.py" "$preferences_path" claude.maxBudgetUsd)"
  configured_policy="$("$script_root/read-preference.py" "$preferences_path" deliberation.sessionPolicy)"
  configured_rounds="$("$script_root/read-preference.py" "$preferences_path" deliberation.maxRounds)"
  [ -z "$configured_policy" ] || session_policy="$configured_policy"
  [ -z "$configured_rounds" ] || max_rounds="$configured_rounds"
fi

case "$session_policy" in
  resume-within-task | fresh-each-round | ephemeral) ;;
  *)
    echo "[peer-claude] unsupported session policy: $session_policy" >&2
    exit 2
    ;;
esac
if ! [[ "$max_rounds" =~ ^[1-9][0-9]*$ ]]; then
  echo "[peer-claude] maxRounds must be a positive integer" >&2
  exit 2
fi
calls_completed="$(sed -n 's/^- Calls completed: \([0-9][0-9]*\)$/\1/p' "$deliberation_path" | head -1)"
if [ -n "$calls_completed" ] && [ "$calls_completed" -ge "$max_rounds" ]; then
  echo "[peer-claude] configured round limit reached ($calls_completed/$max_rounds)" >&2
  exit 3
fi
if [ "$session_policy" = "resume-within-task" ] &&
  [ -n "$calls_completed" ] &&
  [ "$calls_completed" -gt 0 ] &&
  [ -z "$resume_id" ]; then
  echo "[peer-claude] resume-within-task requires --resume after the first peer call" >&2
  exit 2
fi
if [ "$session_policy" = "ephemeral" ] && [ -n "$resume_id" ]; then
  echo "[peer-claude] ephemeral sessions cannot be resumed" >&2
  exit 2
fi
if [ "$session_policy" = "fresh-each-round" ] && [ -n "$resume_id" ]; then
  echo "[peer-claude] fresh-each-round forbids --resume" >&2
  exit 2
fi

if [ -z "$resume_id" ]; then
  session_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
else
  session_id="$resume_id"
fi

claude_args=(--print --output-format json --permission-mode plan --name peer-deliberation)
if [ -n "$resume_id" ]; then
  claude_args+=(--resume "$resume_id")
else
  claude_args+=(--session-id "$session_id")
fi
[ -z "$model" ] || claude_args+=(--model "$model")
[ -z "$effort" ] || claude_args+=(--effort "$effort")
[ -z "$max_budget" ] || claude_args+=(--max-budget-usd "$max_budget")
[ "$session_policy" != "ephemeral" ] || claude_args+=(--no-session-persistence)

echo "[peer-claude] repository: $repo_root"
echo "[peer-claude] deliberation: ${deliberation_path#"$repo_root"/}"
echo "[peer-claude] session: $session_id"
echo "[peer-claude] model: ${model:-environment default}"
echo "[peer-claude] effort: ${effort:-environment default}"
echo "[peer-claude] session policy: $session_policy"
if [ "$dry_run" = "1" ]; then
  echo "[peer-claude] dry run passed; Claude was not launched"
  exit 0
fi
command -v claude >/dev/null 2>&1 || {
  echo "[peer-claude] Claude CLI is unavailable" >&2
  exit 127
}

result_file="$(mktemp)"
trap 'rm -f "$result_file"' EXIT
set +e
{
  cat "$prompt_file"
  printf '\n\nRead `%s` as the durable deliberation record. Ground every claim against repository evidence. Return only your peer position; do not edit files. The initiating model will record and adjudicate it.\n' \
    "${deliberation_path#"$repo_root"/}"
  printf '\nYou are running non-interactively; no one can answer questions mid-turn. Do not end on a question or a request for permission. When information is missing, state the assumption you are proceeding under, or name the missing evidence as an open unknown in your position.\n'
} | (
  cd "$repo_root"
  claude "${claude_args[@]}"
) >"$result_file"
claude_status=$?
set -e
if [ "$claude_status" -ne 0 ]; then
  echo "[peer-claude] Claude exited with status $claude_status" >&2
  echo "[peer-claude] record BLOCKED_CLAUDE_CAPACITY or BLOCKED_EXECUTION and preserve session $session_id" >&2
  exit "$claude_status"
fi

python3 - "$result_file" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
result = data.get("result")
if not isinstance(result, str) or not result.strip():
    raise SystemExit("Claude returned no final result")
print(result)
PY
echo "[peer-claude] resume session: $session_id" >&2
