#!/usr/bin/env bash

set -uo pipefail

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
failures=0
tests=0

pass() {
  tests=$((tests + 1))
  echo "ok $tests - $1"
}

fail() {
  tests=$((tests + 1))
  failures=$((failures + 1))
  echo "not ok $tests - $1" >&2
}

new_repo() {
  local name="$1"
  local repo="$test_root/$name"

  git init -q --initial-branch=main "$repo"
  git -C "$repo" config user.name "Bundle Test"
  git -C "$repo" config user.email "bundle@example.invalid"
  printf '%s\n' "fixture" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "Initial"
  printf '%s\n' "$repo"
}

test_install_is_inactive() {
  local repo
  repo="$(new_repo inactive)"

  if "$bundle_root/install.sh" --repo "$repo" >/dev/null &&
    [ -f "$repo/.claude/skills/codex-implementation/SKILL.md" ] &&
    [ -f "$repo/.agents/skills/delegate-frontend-to-claude/SKILL.md" ] &&
    [ -z "$(git -C "$repo" config --local --get core.hooksPath || true)" ]; then
    pass "install copies helpers without activating hooks"
  else
    fail "install copies helpers without activating hooks"
  fi
}

test_drift_refusal() {
  local repo
  repo="$(new_repo drift)"
  "$bundle_root/install.sh" --repo "$repo" >/dev/null
  printf '%s\n' "# local policy" >> "$repo/.claude/skills/codex-review/SKILL.md"

  if ! "$bundle_root/install.sh" --repo "$repo" >/dev/null 2>&1 &&
    grep -q '# local policy' "$repo/.claude/skills/codex-review/SKILL.md"; then
    pass "install refuses and preserves locally drifted skills"
  else
    fail "install refuses and preserves locally drifted skills"
  fi
}

test_explicit_force() {
  local repo
  repo="$(new_repo force)"
  "$bundle_root/install.sh" --repo "$repo" >/dev/null
  printf '%s\n' "# locally-modified" >> "$repo/.claude/skills/codex-review/SKILL.md"

  if "$bundle_root/install.sh" --repo "$repo" --force >/dev/null 2>&1 &&
    ! grep -q '^# locally-modified$' "$repo/.claude/skills/codex-review/SKILL.md"; then
    pass "explicit force updates drifted bundled files"
  else
    fail "explicit force updates drifted bundled files"
  fi
}

test_symlink_refusal() {
  local repo
  local external_skill="$test_root/external-skill"
  repo="$(new_repo symlink)"
  mkdir -p "$repo/.claude/skills" "$external_skill"
  printf '%s\n' "external" > "$external_skill/SKILL.md"
  ln -s "$external_skill" "$repo/.claude/skills/codex-review"

  if ! "$bundle_root/install.sh" --repo "$repo" --force >/dev/null 2>&1 &&
    grep -q '^external$' "$external_skill/SKILL.md"; then
    pass "install never writes through a symlinked destination"
  else
    fail "install never writes through a symlinked destination"
  fi
}

test_doctor_is_read_only() {
  local repo
  local before
  local after
  repo="$(new_repo doctor)"
  before="$(git -C "$repo" status --porcelain=v1)"

  if "$bundle_root/doctor.sh" --repo "$repo" --skip-archives >/dev/null; then
    after="$(git -C "$repo" status --porcelain=v1)"
    if [ "$before" = "$after" ] &&
      [ -z "$(git -C "$repo" config --local --get core.hooksPath || true)" ]; then
      pass "doctor reports capabilities without mutation"
      return
    fi
  fi
  fail "doctor reports capabilities without mutation"
}

test_bootstrap_activation() {
  local repo
  repo="$(new_repo bootstrap)"

  if "$bundle_root/bootstrap.sh" \
    --repo "$repo" \
    --activate \
    --profile generic >/dev/null &&
    [ "$(git -C "$repo" config --local --get core.hooksPath)" = ".collaboration-hooks" ] &&
    [ -x "$repo/.collaboration-hooks/pre-commit" ] &&
    [ -x "$repo/.collaboration-hooks/pre-push" ] &&
    ! grep -Eq '^[[:space:]]*AI_REVIEW_ENABLED=1' "$repo/.review-hooks.conf"; then
    pass "bootstrap explicitly activates deterministic gates without AI review"
  else
    fail "bootstrap explicitly activates deterministic gates without AI review"
  fi
}

test_install_is_inactive
test_drift_refusal
test_explicit_force
test_symlink_refusal
test_doctor_is_read_only
test_bootstrap_activation

if [ "$failures" -gt 0 ]; then
  echo "$failures of $tests tests failed" >&2
  exit 1
fi

echo "all $tests tests passed"
