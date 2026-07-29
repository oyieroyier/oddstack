#!/usr/bin/env bash

set -uo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./doctor.sh [--repo PATH] [--strict] [--skip-archives]

Read-only capability and drift report. Warnings are informational by default;
--strict makes warnings fail. No hooks, skills, credentials, or approvals are
changed.
EOF
}

repo_input="$PWD"
strict=0
check_archives=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 2
      }
      repo_input="$2"
      shift 2
      ;;
    --strict)
      strict=1
      shift
      ;;
    --skip-archives)
      check_archives=0
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

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$repo_input" rev-parse --show-toplevel 2>/dev/null || true)"
passes=0
warnings=0
failures=0

pass() {
  passes=$((passes + 1))
  printf 'PASS  %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN  %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL  %s\n' "$1"
}

if [ -z "$repo_root" ]; then
  fail "target is not a Git repository: $repo_input"
  printf '\nSummary: %s pass, %s warning, %s failure\n' "$passes" "$warnings" "$failures"
  exit 1
fi
pass "Git repository: $repo_root"

if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  pass "Bash ${BASH_VERSINFO[0]} satisfies the Bash 4+ requirement"
else
  fail "Bash 4 or newer is required"
fi

for command_name in git claude codex; do
  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name CLI is available"
  else
    warn "$command_name CLI is unavailable"
  fi
done

check_tree() {
  local src="$1"
  local dst="$2"
  local label="$3"

  if [ ! -e "$dst" ]; then
    warn "$label is not installed"
  elif diff -qr "$src" "$dst" >/dev/null; then
    pass "$label matches the bundle"
  else
    warn "$label has local drift; inspect with: diff -ru \"$dst\" \"$src\""
  fi
}

for skill_src in "$bundle_root"/.claude/skills/*; do
  [ -d "$skill_src" ] || continue
  skill_name="$(basename "$skill_src")"
  check_tree "$skill_src" "$repo_root/.claude/skills/$skill_name" ".claude/skills/$skill_name"
done

for skill_src in "$bundle_root"/.agents/skills/*; do
  [ -d "$skill_src" ] || continue
  skill_name="$(basename "$skill_src")"
  check_tree "$skill_src" "$repo_root/.agents/skills/$skill_name" ".agents/skills/$skill_name"
done

check_tree "$bundle_root/review-hooks" "$repo_root/review-hooks" "review-hooks"

hooks_path="$(git -C "$repo_root" config --local --get core.hooksPath || true)"
case "$hooks_path" in
  .collaboration-hooks)
    pass "collaboration hardening gates are activated"
    for hook_name in pre-commit pre-push; do
      if [ -x "$repo_root/.collaboration-hooks/$hook_name" ]; then
        pass "$hook_name gate is executable"
      else
        fail "$hook_name gate is missing or not executable"
      fi
    done
    ;;
  "")
    warn "core.hooksPath is unset; collaboration hardening gates are inactive"
    ;;
  *)
    warn "another hook system is active at core.hooksPath=$hooks_path"
    ;;
esac

profile_path="$repo_root/.review-hooks.conf"
if [ -f "$profile_path" ]; then
  if bash -n "$profile_path"; then
    pass ".review-hooks.conf is valid Bash"
  else
    fail ".review-hooks.conf is invalid Bash"
  fi

  if grep -Eq '^[[:space:]]*AI_REVIEW_ENABLED=1([[:space:]]|$)' "$profile_path"; then
    warn "AI pre-push review is enabled; confirm credential ownership and quota policy"
  else
    pass "AI pre-push review is not enabled"
  fi
else
  warn ".review-hooks.conf is not installed"
fi

implement_refs=0
tdd_available=0
user_root="${HOME:-}"
declare -a skill_roots=(
  "$repo_root/.agents/skills"
  "$repo_root/.claude/skills"
)
if [ -n "$user_root" ]; then
  skill_roots+=(
    "$user_root/.agents/skills"
    "$user_root/.claude/skills"
    "$user_root/.codex/skills"
  )
fi

for skill_root in "${skill_roots[@]}"; do
  if [ -f "$skill_root/implement/SKILL.md" ] &&
    grep -Eq '(^|[^[:alnum:]_-])/tdd([^[:alnum:]_-]|$)' "$skill_root/implement/SKILL.md"; then
    implement_refs=1
  fi
  if [ -f "$skill_root/tdd/SKILL.md" ]; then
    tdd_available=1
  fi
done

if [ "$implement_refs" = "1" ] && [ "$tdd_available" = "1" ]; then
  pass "implement → /tdd dependency is satisfied"
elif [ "$implement_refs" = "1" ]; then
  fail "implement invokes /tdd, but no tdd skill is installed"
else
  pass "no dangling implement → /tdd reference was found"
fi

if [ -d "$repo_root/docs/implementation" ] &&
  find "$repo_root/docs/implementation" -maxdepth 1 -iname '*page*visual*audit*' -print -quit |
    grep -q .; then
  pass "manual page-audit documentation is present"
  if grep -R -- '--approve' \
    "$repo_root/review-hooks/profiles" \
    "$repo_root/review-hooks/scripts" >/dev/null 2>&1; then
    fail "review-hook automation contains a page-approval command"
  else
    pass "review-hook automation does not approve pages"
  fi
else
  pass "no repository page-audit ledger was detected"
fi

if [ "$check_archives" = "1" ]; then
  if [ ! -e "$bundle_root/codex-claude-skills.tar.gz" ] &&
    [ ! -e "$bundle_root/codex-claude-skills.zip" ]; then
    pass "release archives are not embedded in this distribution"
  elif "$bundle_root/package.sh" --check >/dev/null 2>&1; then
    pass "release archives match the bundle source"
  else
    warn "release archives are stale or missing; run ./package.sh"
  fi
fi

printf '\nSummary: %s pass, %s warning, %s failure\n' "$passes" "$warnings" "$failures"

if [ "$failures" -gt 0 ]; then
  exit 1
fi
if [ "$strict" = "1" ] && [ "$warnings" -gt 0 ]; then
  exit 1
fi
