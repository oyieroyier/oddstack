#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: run-claude-frontend.sh --prompt-file PATH --backlog-file PATH [--repo PATH] [--allow-dirty] [--dry-run]

Runs a self-contained frontend handoff prompt inside the local Claude Code CLI.
The durable backlog must be a non-empty Markdown file under plans/agent-handoffs/.
The repository must otherwise be clean unless --allow-dirty is explicitly supplied.
USAGE
}

PROMPT_FILE=""
BACKLOG_FILE=""
REPO_PATH="$PWD"
ALLOW_DIRTY=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prompt-file)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PROMPT_FILE="$2"
      shift 2
      ;;
    --backlog-file)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      BACKLOG_FILE="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REPO_PATH="$2"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$PROMPT_FILE" ] || { echo "--prompt-file is required" >&2; exit 2; }
[ -f "$PROMPT_FILE" ] || { echo "Prompt file not found: $PROMPT_FILE" >&2; exit 2; }
[ -s "$PROMPT_FILE" ] || { echo "Prompt file is empty: $PROMPT_FILE" >&2; exit 2; }
[ -n "$BACKLOG_FILE" ] || { echo "--backlog-file is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is not installed" >&2; exit 127; }
command -v claude >/dev/null 2>&1 || { echo "claude is not installed or not on PATH" >&2; exit 127; }

REPO_ROOT="$(git -C "$REPO_PATH" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Not inside a git repository: $REPO_PATH" >&2
  exit 2
}

case "$BACKLOG_FILE" in
  /*) BACKLOG_PATH="$BACKLOG_FILE" ;;
  *) BACKLOG_PATH="$REPO_ROOT/$BACKLOG_FILE" ;;
esac

[ -f "$BACKLOG_PATH" ] || { echo "Backlog file not found: $BACKLOG_FILE" >&2; exit 2; }
[ -s "$BACKLOG_PATH" ] || { echo "Backlog file is empty: $BACKLOG_FILE" >&2; exit 2; }

BACKLOG_ROOT="$(cd "$(dirname "$BACKLOG_PATH")" && pwd -P)"
BACKLOG_NAME="$(basename "$BACKLOG_PATH")"
BACKLOG_PATH="$BACKLOG_ROOT/$BACKLOG_NAME"
case "$BACKLOG_PATH" in
  "$REPO_ROOT"/plans/agent-handoffs/*.md) ;;
  *)
    echo "Backlog must be a Markdown file under $REPO_ROOT/plans/agent-handoffs/." >&2
    exit 2
    ;;
esac
BACKLOG_RELATIVE="${BACKLOG_PATH#"$REPO_ROOT"/}"

for REQUIRED_BACKLOG_MARKER in \
  "Status:" \
  "Next owner:" \
  "## Codex queue" \
  "## Claude queue" \
  "## Codex return queue" \
  "## Resume instructions" \
  "### Exact next prompt"
do
  if ! grep -Fq "$REQUIRED_BACKLOG_MARKER" "$BACKLOG_PATH"; then
    echo "Backlog is missing required marker: $REQUIRED_BACKLOG_MARKER" >&2
    exit 2
  fi
done
if ! grep -Eq '^- \[ \] `[^`]+` ' "$BACKLOG_PATH"; then
  echo "Backlog must contain at least one open stable-id checkbox task." >&2
  exit 2
fi
OPEN_BACKLOG_TASKS="$(grep -E '^- \[ \] `[^`]+` ' "$BACKLOG_PATH")"

BEFORE_STATUS="$(git -C "$REPO_ROOT" status --short)"
OTHER_STATUS="$(git -C "$REPO_ROOT" status --short -- . ":(exclude)$BACKLOG_RELATIVE")"
if [ -n "$OTHER_STATUS" ] && [ "$ALLOW_DIRTY" -ne 1 ]; then
  echo "Refusing to launch Claude over a dirty working tree." >&2
  echo "Create an authorized clean checkpoint or rerun with --allow-dirty after proving all changes are in scope." >&2
  printf '%s\n' "$OTHER_STATUS" >&2
  exit 3
fi

echo "[claude-frontend] repository: $REPO_ROOT"
STARTING_HEAD="$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null || printf '<unborn>')"
echo "[claude-frontend] starting HEAD: $STARTING_HEAD"
echo "[claude-frontend] durable backlog: $BACKLOG_RELATIVE"
if [ -n "$BEFORE_STATUS" ]; then
  echo "[claude-frontend] pre-existing in-scope status:"
  printf '%s\n' "$BEFORE_STATUS"
else
  echo "[claude-frontend] working tree is clean"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[claude-frontend] dry run passed; Claude was not launched"
  exit 0
fi

BACKLOG_BEFORE_HASH="$(git hash-object "$BACKLOG_PATH")"
(
  cd "$REPO_ROOT"
  set +e
  {
    cat "$PROMPT_FILE"
    printf '\n\n## Durable delegation backlog (runner-enforced)\n\n'
    printf 'Read `%s` before any other task work. It is the source of truth for queues, checkpoints, blockers, evidence, and next owner. Update it before editing and before every yield. Preserve open tasks if capacity or execution fails. Never mark the task complete with an open Codex, Claude, or operator queue item.\n' "$BACKLOG_RELATIVE"
    printf '\nOpen tasks recorded at launch:\n\n'
    printf '%s\n' "$OPEN_BACKLOG_TASKS"
    printf '\n## Autonomous run (runner-enforced)\n\n'
    printf 'You are operating autonomously in a non-interactive run. Codex and the user cannot answer questions mid-task, so asking "Shall I..?" blocks the work. For reversible actions inside your ownership boundary, proceed without asking. If you are blocked by something only Codex or the operator can resolve, record the blocker and your open queue in the backlog and return your report instead of asking permission. Before ending your turn, check your last paragraph: if it is a question, a plan, or a promise about work you have not done ("I will now..."), do that work first with tool calls. End only when the slice is complete or the blocker is recorded.\n'
  } | claude --print \
      --permission-mode acceptEdits \
      --name codex-frontend-handoff
  CLAUDE_EXIT="$?"
  set -e
  if [ "$CLAUDE_EXIT" -ne 0 ]; then
    echo "[claude-frontend] Claude exited with status $CLAUDE_EXIT." >&2
    echo "[claude-frontend] Preserve the open queue and record the concrete failure in $BACKLOG_RELATIVE before ending the Codex session." >&2
    exit "$CLAUDE_EXIT"
  fi
)

BACKLOG_AFTER_HASH="$(git hash-object "$BACKLOG_PATH")"
if [ "$BACKLOG_AFTER_HASH" = "$BACKLOG_BEFORE_HASH" ]; then
  echo "[claude-frontend] Claude returned without updating $BACKLOG_RELATIVE." >&2
  echo "[claude-frontend] Treat the handoff as incomplete and preserve every open queue item." >&2
  exit 4
fi

echo "[claude-frontend] final status:"
git -C "$REPO_ROOT" status --short
