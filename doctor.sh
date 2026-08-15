#!/usr/bin/env bash

set -uo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./doctor.sh [--repo PATH] [--strict] [--skip-archives]

Read-only dependency, capability, and drift report. Warnings are informational
by default; --strict makes warnings fail. No packages, hooks, skills,
credentials, or approvals are changed.
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

# -P resolves symlinks so this stays comparable with the physical path
# `git rev-parse --show-toplevel` reports; see install.sh for the same reason.
bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ ! -f "$bundle_root/scripts/bundle-version.sh" ]; then
  echo "[doctor] incomplete bundle, missing: scripts/bundle-version.sh" >&2
  exit 2
fi
# shellcheck source=scripts/bundle-version.sh
. "$bundle_root/scripts/bundle-version.sh"

# Refuse to report on a target using a broken bundle: every mismatch would be
# blamed on the repository rather than on the bundle doing the comparing.
bundle_missing="$(bundle_missing_paths "$bundle_root")"
if [ -n "$bundle_missing" ]; then
  echo "[doctor] incomplete bundle, missing:" >&2
  printf '  %s\n' $bundle_missing >&2
  exit 2
fi
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

if command -v python3 >/dev/null 2>&1; then
  dependency_args=(check --repo "$repo_root")
  if [ "$strict" = "1" ]; then
    dependency_args+=(--strict)
  fi
  if python3 "$bundle_root/scripts/manage-dependencies.py" "${dependency_args[@]}"; then
    pass "required and active conditional dependencies are available"
  else
    fail "required or active conditional dependencies are unavailable"
  fi
else
  fail "python3 is required to run the dependency capability check"
fi

preferences_path=""
if [ -n "${HOME:-}" ]; then
  preferences_path="${XDG_CONFIG_HOME:-${HOME}/.config}/codex-claude-skills/preferences.json"
fi
if [ -n "$preferences_path" ] && [ -f "$preferences_path" ]; then
  if command -v python3 >/dev/null 2>&1 &&
    python3 -m json.tool "$preferences_path" >/dev/null 2>&1; then
    pass "user collaboration preferences are valid JSON"
  else
    fail "user collaboration preferences are invalid JSON: $preferences_path"
  fi
else
  pass "no user collaboration preference override is installed"
fi

if command -v python3 >/dev/null 2>&1 &&
  python3 "$bundle_root/scripts/configure-claude-alert.py" --status >/dev/null 2>&1; then
  pass "Claude Code terminal-bell notifications are enabled"
else
  warn "Claude Code terminal-bell notifications are not enabled"
fi

if command -v python3 >/dev/null 2>&1; then
  resolver="$bundle_root/.claude/skills/collab-config/scripts/resolve_config.py"
  resolver_args=(--repo "$repo_root" --show)
  if [ -n "$preferences_path" ] && [ -f "$preferences_path" ]; then
    resolver_args+=(--preferences "$preferences_path")
  fi
  if resolver_error="$(python3 "$resolver" "${resolver_args[@]}" 2>&1 >/dev/null)"; then
    if [ -f "$repo_root/.codex-claude-skills.json" ]; then
      pass "repository collaboration policy composes with user preferences"
    else
      pass "no repository collaboration policy override is present"
    fi
    if [ -n "$resolver_error" ]; then
      warn "collaboration configuration resolves with warnings: $(printf '%s' "$resolver_error" | head -n 1)"
    fi
  else
    fail "collaboration configuration does not resolve: ${resolver_error}"
  fi
else
  warn "python3 is unavailable; collaboration preferences and any repository policy were not checked"
fi

check_tree() {
  local src="$1"
  local dst="$2"
  local label="$3"

  if [ ! -e "$dst" ]; then
    warn "$label is not installed"
  elif diff -qr "${BUNDLE_DIFF_EXCLUDES[@]}" "$src" "$dst" >/dev/null; then
    pass "$label matches the bundle"
  else
    warn "$label has local drift; inspect with: diff -ru \"$dst\" \"$src\""
  fi
}

# Whether any *bundled* content is present. A repository's own unrelated skills
# do not make it an install, and review-hooks alone does. Directory existence is
# the wrong test in both directions.
bundle_content_installed=0

for skill_src in "$bundle_root"/.claude/skills/*; do
  [ -d "$skill_src" ] || continue
  skill_name="$(basename "$skill_src")"
  [ -e "$repo_root/.claude/skills/$skill_name" ] && bundle_content_installed=1
  check_tree "$skill_src" "$repo_root/.claude/skills/$skill_name" ".claude/skills/$skill_name"
done

for skill_src in "$bundle_root"/.agents/skills/*; do
  [ -d "$skill_src" ] || continue
  skill_name="$(basename "$skill_src")"
  [ -e "$repo_root/.agents/skills/$skill_name" ] && bundle_content_installed=1
  check_tree "$skill_src" "$repo_root/.agents/skills/$skill_name" ".agents/skills/$skill_name"
done

# Both the copied source tree and the activated runtime count as installed
# content; a repository holding only .review-hooks/ is an install too.
{ [ -e "$repo_root/review-hooks" ] || [ -e "$repo_root/.review-hooks" ] ||
  [ -e "$repo_root/$BUNDLE_STAMP_FILE" ]; } && bundle_content_installed=1
check_tree "$bundle_root/review-hooks" "$repo_root/review-hooks" "review-hooks"

# Both stamp comparisons below need sha256sum. Resolve it once so they degrade
# the same way rather than one warning and the other silently skipping.
have_sha256sum=0
if command -v sha256sum >/dev/null 2>&1; then
  have_sha256sum=1
fi

# integration-review is the one skill with a runtime dependency of its own: its
# readiness validator is Node. Check the interpreter only when the skill is
# actually installed, so repositories that never adopted it stay quiet.
if [ -d "$repo_root/.agents/skills/integration-review" ]; then
  if ! command -v node >/dev/null 2>&1; then
    warn "integration-review is installed but node is missing; its readiness validator cannot run"
  else
    node_major="$(node --version 2>/dev/null | sed -nE 's/^v([0-9]+).*/\1/p')"
    if [ -n "$node_major" ] && [ "$node_major" -lt 15 ]; then
      warn "node $(node --version) is older than the Node 15 the readiness validator requires"
    else
      pass "node satisfies the integration-review readiness validator"
    fi
  fi
fi

# The per-tree checks above prove whether installed files differ from the
# bundle; the stamp says which release they came from, which is what separates
# "edited here" from "installed from an older bundle".
if [ "$repo_root" != "$bundle_root" ]; then
  bundle_stamp_path="$repo_root/$BUNDLE_STAMP_FILE"
  bundle_release="$(bundle_version "$bundle_root")"
  installed_release="$(bundle_stamp_field "$bundle_stamp_path" version)"

  if [ -z "$installed_release" ] && [ "$bundle_content_installed" = "0" ]; then
    pass "no bundle is installed here; nothing to compare against $bundle_release"
  elif [ -z "$installed_release" ]; then
    warn "$BUNDLE_STAMP_FILE is missing; the install predates bundle $bundle_release"
  elif [ "$have_sha256sum" != "1" ]; then
    warn "sha256sum is unavailable; stamped bundle $installed_release was not verified"
  elif [ "$installed_release" != "$bundle_release" ]; then
    warn "skills bundle is $installed_release, a different release than $bundle_release; rerun install.sh --force"
  elif ! computed_bundle_digest="$(bundle_source_digest "$bundle_root")"; then
    fail "cannot digest this bundle; its report about $repo_root is not trustworthy"
  elif [ "$(bundle_stamp_field "$bundle_stamp_path" source-digest)" = "$computed_bundle_digest" ]; then
    pass "skills bundle $installed_release matches this bundle release"
  else
    warn "skills bundle came from another build of $installed_release; rerun install.sh --force"
  fi
fi

if [ -d "$repo_root/.review-hooks" ] && [ "$repo_root" != "$bundle_root" ]; then
  for runtime_part in scripts review_gate bin; do
    check_tree \
      "$bundle_root/review-hooks/$runtime_part" \
      "$repo_root/.review-hooks/$runtime_part" \
      ".review-hooks/$runtime_part"
  done

  if [ -d "$repo_root/.collaboration-hooks" ]; then
    check_tree \
      "$bundle_root/review-hooks/hooks" \
      "$repo_root/.collaboration-hooks" \
      ".collaboration-hooks"
  fi

  if [ -f "$repo_root/.review-hooks/VERSION" ]; then
    if cmp -s "$bundle_root/review-hooks/VERSION" "$repo_root/.review-hooks/VERSION"; then
      pass "installed runtime VERSION matches the bundle"
    else
      warn "installed runtime VERSION differs from the bundle"
    fi
  else
    warn ".review-hooks/VERSION is missing; the runtime predates version 2"
  fi

  runtime_stamp_path="$repo_root/.review-hooks/bundle-version"
  if [ ! -f "$runtime_stamp_path" ]; then
    warn ".review-hooks/bundle-version stamp is missing; the runtime predates version 2"
  elif [ "$have_sha256sum" != "1" ]; then
    warn "sha256sum is unavailable; the installed review runtime was not verified"
  else
    installed_digest="$(bundle_stamp_field "$runtime_stamp_path" source-digest)"
    if ! runtime_digest="$(runtime_source_digest "$bundle_root")"; then
      # Never blame the target for a digest this bundle could not compute; that
      # would send the operator to reinstall from the broken bundle.
      fail "cannot digest this bundle's review runtime; its verdict on $repo_root is not trustworthy"
    elif [ "$installed_digest" = "$runtime_digest" ]; then
      pass "installed review runtime matches this bundle release"
    else
      warn "installed review runtime came from another bundle release; rerun review-hooks/install.sh --force"
    fi
  fi
fi

hooks_path="$(git -C "$repo_root" config --local --get core.hooksPath || true)"
case "$hooks_path" in
  .collaboration-hooks)
    pass "collaboration hardening gates are activated"
    for hook_name in pre-commit commit-msg pre-push; do
      if [ -x "$repo_root/.collaboration-hooks/$hook_name" ]; then
        pass "$hook_name gate is executable"
      elif [ "$hook_name" = "commit-msg" ] &&
        ! cmp -s "$bundle_root/review-hooks/VERSION" "$repo_root/.review-hooks/VERSION" 2>/dev/null; then
        # The commit-msg gate arrived in 2.1; an older runtime is stale, not broken.
        warn "commit-msg gate is missing; the installed runtime predates 2.1, rerun review-hooks/install.sh --force"
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

  profile_version="$(
    sed -nE 's/^[[:space:]]*REVIEW_HOOKS_PROFILE_VERSION=([0-9]+).*$/\1/p' \
      "$profile_path" | tail -n 1
  )"
  case "$profile_version" in
    2)
      pass "review profile is version 2"
      ;;
    1)
      warn "review profile is version 1; its timeout and retry meanings are deprecated — migrate to version 2"
      ;;
    *)
      warn "review profile declares no known version"
      ;;
  esac

  if command -v python3 >/dev/null 2>&1; then
    pass "python3 is available for the review runtime"
  else
    warn "python3 is missing; the version 2 review runtime cannot run"
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
    "$repo_root/review-hooks/scripts" \
    "$repo_root/review-hooks/review_gate" \
    "$repo_root/review-hooks/bin" >/dev/null 2>&1; then
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
