#!/usr/bin/env bash

set -uo pipefail

module_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  git -C "$repo" config user.name "Review Hooks Test"
  git -C "$repo" config user.email "review-hooks@example.invalid"
  printf '%s\n' "base" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "Initial"
  printf '%s\n' "$repo"
}

install_generic() {
  local repo="$1"
  "$module_root/install.sh" --repo "$repo" --profile generic >/dev/null
}

test_dry_run() {
  local repo
  repo="$(new_repo dry-run)"

  if "$module_root/install.sh" \
    --repo "$repo" \
    --profile generic \
    --dry-run >/dev/null &&
    [ ! -e "$repo/.review-hooks" ] &&
    [ -z "$(git -C "$repo" config --local --get core.hooksPath || true)" ]; then
    pass "dry run does not mutate the repository"
  else
    fail "dry run does not mutate the repository"
  fi
}

test_install_and_deactivate() {
  local repo
  repo="$(new_repo install)"

  if install_generic "$repo" &&
    [ "$(git -C "$repo" config --local --get core.hooksPath)" = ".collaboration-hooks" ] &&
    [ -x "$repo/.collaboration-hooks/pre-commit" ] &&
    [ -x "$repo/.review-hooks/scripts/run-ai-review-gate.sh" ] &&
    "$module_root/install.sh" --repo "$repo" --deactivate >/dev/null &&
    [ -z "$(git -C "$repo" config --local --get core.hooksPath || true)" ]; then
    pass "install activates and deactivate restores an unset hook path"
  else
    fail "install activates and deactivate restores an unset hook path"
  fi
}

test_existing_hook_refusal_and_composition() {
  local repo
  repo="$(new_repo conflict)"
  git -C "$repo" config --local core.hooksPath .husky

  if ! "$module_root/install.sh" \
    --repo "$repo" \
    --profile generic >/dev/null 2>&1 &&
    "$module_root/install.sh" \
      --repo "$repo" \
      --profile generic \
      --no-activate >/dev/null &&
    [ "$(git -C "$repo" config --local --get core.hooksPath)" = ".husky" ]; then
    pass "existing hook paths are refused unless composition is selected"
  else
    fail "existing hook paths are refused unless composition is selected"
  fi
}

test_hook_path_restore() {
  local repo
  repo="$(new_repo restore)"
  git -C "$repo" config --local core.hooksPath .husky

  if "$module_root/install.sh" \
    --repo "$repo" \
    --profile generic \
    --replace-hooks-path >/dev/null &&
    [ "$(git -C "$repo" config --local --get core.hooksPath)" = ".collaboration-hooks" ] &&
    "$module_root/install.sh" --repo "$repo" --deactivate >/dev/null &&
    [ "$(git -C "$repo" config --local --get core.hooksPath)" = ".husky" ]; then
    pass "explicit replacement records and restores the previous hook path"
  else
    fail "explicit replacement records and restores the previous hook path"
  fi
}

test_pre_commit_checks() {
  local repo
  repo="$(new_repo pre-commit)"
  install_generic "$repo"

  printf '%s\n' "safe" > "$repo/safe.txt"
  git -C "$repo" add safe.txt
  if ! git -C "$repo" commit -qm "Safe staged change"; then
    fail "pre-commit accepts safe staged changes"
    return
  fi
  pass "pre-commit accepts safe staged changes"

  printf '%s\n' "token=ghp_abcdefghijklmnopqrstuvwxyz123456" > "$repo/secret.txt"
  git -C "$repo" add secret.txt
  if git -C "$repo" commit -qm "Secret staged change" >/dev/null 2>&1; then
    fail "pre-commit blocks a staged secret"
  else
    pass "pre-commit blocks a staged secret"
  fi
}

test_pre_push_without_ai() {
  local repo
  local base
  local head
  repo="$(new_repo pre-push-disabled)"
  install_generic "$repo"
  base="$(git -C "$repo" rev-parse HEAD)"
  printf '%s\n' "next" >> "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "Next"
  head="$(git -C "$repo" rev-parse HEAD)"

  if printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$base" |
    (
      cd "$repo"
      .collaboration-hooks/pre-push
    ) >/dev/null; then
    pass "generic pre-push succeeds without consuming AI quota"
  else
    fail "generic pre-push succeeds without consuming AI quota"
  fi
}

test_ai_review_and_sensitive_refusal() {
  local repo
  local base
  local head
  local fake_claude="$test_root/fake-claude"
  repo="$(new_repo ai-review)"
  install_generic "$repo"

  cat > "$fake_claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' \
  "No findings." \
  "VERDICT: SAFE" \
  "BLOCKERS: no" \
  "RISK-CLASS: none"
EOF
  chmod +x "$fake_claude"
  printf '%s\n' "AI_REVIEW_ENABLED=1" >> "$repo/.review-hooks.conf"

  base="$(git -C "$repo" rev-parse HEAD)"
  printf '%s\n' "review me" >> "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "Reviewable"
  head="$(git -C "$repo" rev-parse HEAD)"

  if printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$base" |
    AI_REVIEW_CREDENTIAL_SCOPE=ci \
      AI_REVIEW_CLAUDE_BIN="$fake_claude" \
      bash -c "cd '$repo' && .review-hooks/scripts/run-pre-push-gate.sh" >/dev/null &&
    [ -s "$repo/ai-reviews/latest.md" ]; then
    pass "bounded AI review accepts a well-formed safe verdict"
  else
    fail "bounded AI review accepts a well-formed safe verdict"
  fi

  base="$head"
  printf '%s\n' "not-a-real-secret" > "$repo/.env"
  git -C "$repo" add .env
  SKIP_PRE_COMMIT_CHECKS=1 git -C "$repo" commit -qm "Sensitive path"
  head="$(git -C "$repo" rev-parse HEAD)"

  if printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$base" |
    AI_REVIEW_CREDENTIAL_SCOPE=ci \
      AI_REVIEW_CLAUDE_BIN="$fake_claude" \
      bash -c "cd '$repo' && .review-hooks/scripts/run-pre-push-gate.sh" >/dev/null 2>&1; then
    fail "AI review refuses configured sensitive paths"
  else
    pass "AI review refuses configured sensitive paths"
  fi
}

test_personal_quota_and_multi_ref_refusal() {
  local repo
  local base
  local head
  local status
  repo="$(new_repo refusal-modes)"
  install_generic "$repo"
  printf '%s\n' "AI_REVIEW_ENABLED=1" >> "$repo/.review-hooks.conf"

  base="$(git -C "$repo" rev-parse HEAD)"
  printf '%s\n' "review me" >> "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "Reviewable"
  head="$(git -C "$repo" rev-parse HEAD)"

  printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$base" |
    bash -c "cd '$repo' && .review-hooks/scripts/run-pre-push-gate.sh" >/dev/null 2>&1
  status=$?
  if [ "$status" = "2" ]; then
    pass "AI review refuses implicit personal quota"
  else
    fail "AI review refuses implicit personal quota"
  fi

  {
    printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$base"
    printf 'refs/heads/other %s refs/heads/other %s\n' "$head" "$base"
  } |
    AI_REVIEW_CREDENTIAL_SCOPE=ci \
      bash -c "cd '$repo' && .review-hooks/scripts/run-pre-push-gate.sh" >/dev/null 2>&1
  status=$?
  if [ "$status" = "2" ]; then
    pass "AI review refuses multi-branch pushes"
  else
    fail "AI review refuses multi-branch pushes"
  fi
}

test_dry_run
test_install_and_deactivate
test_existing_hook_refusal_and_composition
test_hook_path_restore
test_pre_commit_checks
test_pre_push_without_ai
test_ai_review_and_sensitive_refusal
test_personal_quota_and_multi_ref_refusal

if [ "$failures" -gt 0 ]; then
  echo "$failures of $tests tests failed" >&2
  exit 1
fi

echo "all $tests tests passed"
