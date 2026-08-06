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
    [ -x "$repo/.collaboration-hooks/commit-msg" ] &&
    [ -x "$repo/.review-hooks/scripts/run-ai-review-gate.sh" ] &&
    [ -x "$repo/.review-hooks/bin/review-gate" ] &&
    [ -f "$repo/.review-hooks/review_gate/core.py" ] &&
    [ -f "$repo/.review-hooks/bundle-version" ] &&
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

test_doctor_tolerates_pre_2_1_runtime() {
  local repo
  local doctor="$module_root/../doctor.sh"
  local baseline
  local status
  local output
  repo="$(new_repo doctor-pre-2-1)"
  install_generic "$repo"

  "$doctor" --repo "$repo" --skip-archives >/dev/null 2>&1
  baseline=$?

  rm "$repo/.collaboration-hooks/commit-msg"
  printf '2.0.0\n' > "$repo/.review-hooks/VERSION"

  output="$("$doctor" --repo "$repo" --skip-archives 2>&1)"
  status=$?

  if [ "$status" -eq "$baseline" ] &&
    printf '%s\n' "$output" | grep -q "predates 2.1" &&
    ! printf '%s\n' "$output" | grep -q "commit-msg gate is missing or not executable"; then
    pass "doctor warns instead of failing on a pre-2.1 runtime"
  else
    fail "doctor warns instead of failing on a pre-2.1 runtime"
  fi
}

test_force_upgrade_keeps_profile() {
  local repo
  repo="$(new_repo upgrade)"
  install_generic "$repo"
  printf '%s\n' "PRE_PUSH_COMMANDS='true # custom-marker'" >> "$repo/.review-hooks.conf"
  rm "$repo/.collaboration-hooks/commit-msg"

  if "$module_root/install.sh" --repo "$repo" --force >/dev/null &&
    grep -q "custom-marker" "$repo/.review-hooks.conf" &&
    [ -x "$repo/.collaboration-hooks/commit-msg" ]; then
    pass "forced upgrade keeps the profile and restores the commit-msg gate"
  else
    fail "forced upgrade keeps the profile and restores the commit-msg gate"
  fi

  if "$module_root/install.sh" --repo "$repo" --force --profile generic >/dev/null &&
    ! grep -q "custom-marker" "$repo/.review-hooks.conf"; then
    pass "an explicit --profile replaces the existing profile"
  else
    fail "an explicit --profile replaces the existing profile"
  fi
}

test_commit_msg_checks() {
  local repo
  repo="$(new_repo commit-msg)"
  install_generic "$repo"

  printf '%s\n' "one" > "$repo/one.txt"
  git -C "$repo" add one.txt
  if ! git -C "$repo" commit -qm "Empty commands leave the message alone"; then
    fail "commit-msg is a no-op with empty COMMIT_MSG_COMMANDS"
    return
  fi
  pass "commit-msg is a no-op with empty COMMIT_MSG_COMMANDS"

  cat >> "$repo/.review-hooks.conf" <<'EOF'
COMMIT_MSG_COMMANDS='! grep -qi "forbidden" "$REVIEW_HOOKS_COMMIT_MSG_FILE"'
EOF

  printf '%s\n' "two" > "$repo/two.txt"
  git -C "$repo" add two.txt
  if git -C "$repo" commit -qm "A forbidden message" >/dev/null 2>&1; then
    fail "commit-msg blocks a message the configured command rejects"
  else
    pass "commit-msg blocks a message the configured command rejects"
  fi

  if git -C "$repo" commit -qm "A clean message"; then
    pass "commit-msg accepts a message the configured command allows"
  else
    fail "commit-msg accepts a message the configured command allows"
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
cat <<'ENVELOPE'
{"type":"result","result":"No findings.\nREVIEW-RESULT-BEGIN\n{\"schema_version\": 1, \"verdict\": \"SAFE\", \"risk_class\": \"none\", \"findings\": [], \"limitations\": []}\nREVIEW-RESULT-END","session_id":"fake-session","total_cost_usd":0.0123}
ENVELOPE
EOF
  chmod +x "$fake_claude"
  {
    printf '%s\n' "AI_REVIEW_ENABLED=1"
    printf '%s\n' "AI_REVIEW_PUSH_MODE=run-if-missing"
    printf "AI_REVIEW_CLAUDE_BIN='%s'\n" "$fake_claude"
  } >> "$repo/.review-hooks.conf"

  base="$(git -C "$repo" rev-parse HEAD)"
  printf '%s\n' "review me" >> "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "Reviewable"
  head="$(git -C "$repo" rev-parse HEAD)"

  if printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$base" |
    AI_REVIEW_CREDENTIAL_SCOPE=ci \
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
  {
    printf '%s\n' "AI_REVIEW_ENABLED=1"
    printf '%s\n' "AI_REVIEW_PUSH_MODE=run-if-missing"
  } >> "$repo/.review-hooks.conf"

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

test_legacy_v1_profile_through_compat_adapter() {
  local repo
  local base
  local head
  local fake_claude="$test_root/fake-claude-legacy"
  repo="$(new_repo legacy-v1)"
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

  # A version 1 profile still loads for one release, with a warning, and
  # the legacy three-marker result contract still parses.
  cat > "$repo/.review-hooks.conf" <<EOF
REVIEW_HOOKS_PROFILE_VERSION=1
AI_REVIEW_ENABLED=1
AI_REVIEW_CLAUDE_BIN='$fake_claude'
EOF

  base="$(git -C "$repo" rev-parse HEAD)"
  printf '%s\n' "legacy review" >> "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm "Legacy reviewable"
  head="$(git -C "$repo" rev-parse HEAD)"

  if printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$base" |
    AI_REVIEW_CREDENTIAL_SCOPE=ci \
      bash -c "cd '$repo' && .review-hooks/scripts/run-ai-review-gate.sh" \
      >/dev/null 2>&1 &&
    [ -s "$repo/ai-reviews/latest.md" ]; then
    pass "version 1 profiles run through the compatibility adapter"
  else
    fail "version 1 profiles run through the compatibility adapter"
  fi
}

test_doctor_reports_profile_version_one() {
  local repo
  local doctor="$module_root/../doctor.sh"
  repo="$(new_repo doctor-v1)"
  install_generic "$repo"

  cat > "$repo/.review-hooks.conf" <<'EOF'
REVIEW_HOOKS_PROFILE_VERSION=1
AI_REVIEW_ENABLED=0
EOF

  local doctor_output
  doctor_output="$("$doctor" --repo "$repo" --skip-archives 2>/dev/null || true)"

  if printf '%s\n' "$doctor_output" |
    grep -q "review profile is version 1" &&
    ! "$doctor" --repo "$repo" --skip-archives --strict >/dev/null 2>&1; then
    pass "doctor reports profile version 1 and strict mode fails on it"
  else
    fail "doctor reports profile version 1 and strict mode fails on it"
  fi
}

test_python_review_gate_suite() {
  local suite_output
  if suite_output="$(
    cd "$module_root/tests" &&
      PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
        -s . -p 'test_*.py' 2>&1
  )"; then
    pass "python review_gate suite passes"
  else
    fail "python review_gate suite passes"
    printf '%s\n' "$suite_output" | tail -n 40 >&2
  fi
}

test_lmm_page_audit_contract() {
  local profile="$module_root/profiles/lmm.example.conf"

  if grep -q 'pnpm audit:pages' "$profile" &&
    ! grep -q -- '--approve' "$profile"; then
    pass "LMM profile checks page-audit state without approving pages"
  else
    fail "LMM profile checks page-audit state without approving pages"
  fi
}

test_merge_with_fixes_intake_profiles() {
  local generic_profile="$module_root/profiles/generic.conf"
  local lmm_profile="$module_root/profiles/lmm.example.conf"

  if grep -q "^AI_REVIEW_MERGE_WITH_FIXES_COMMAND=''$" "$generic_profile" &&
    grep -q "^AI_REVIEW_MERGE_WITH_FIXES_COMMAND='node plans/evidence/generate-merge-with-fixes-catalog.mjs'$" "$lmm_profile"; then
    pass "durable merge-with-fixes intake is opt-in with an LMM example"
  else
    fail "durable merge-with-fixes intake is opt-in with an LMM example"
  fi
}

test_hook_commands_all_run_when_one_reads_stdin() {
  local repo
  local marker="$test_root/hook-commands-marker"
  repo="$(new_repo hook-commands-stdin)"
  install_generic "$repo"

  cat >> "$repo/.review-hooks.conf" <<EOF
PRE_COMMIT_COMMANDS='cat > /dev/null
touch "$marker"'
EOF

  printf '%s\n' "safe" > "$repo/safe.txt"
  git -C "$repo" add safe.txt
  if git -C "$repo" commit -qm "Two commands, first reads stdin" &&
    [ -f "$marker" ]; then
    pass "all configured hook commands run even when an earlier one reads stdin"
  else
    fail "all configured hook commands run even when an earlier one reads stdin"
  fi
}

test_env_cannot_redirect_the_profile() {
  local repo
  local marker
  local alt_profile
  repo="$(new_repo env-redirect)"
  install_generic "$repo"
  marker="$repo/.marker-created"
  alt_profile="$test_root/env-redirect-alt.conf"
  cp "$repo/.review-hooks.conf" "$alt_profile"
  printf '%s\n' "PRE_COMMIT_COMMANDS='touch \"$marker\"'" >> "$alt_profile"

  printf '%s\n' "safe" > "$repo/redirect.txt"
  git -C "$repo" add redirect.txt
  if REVIEW_HOOKS_PROFILE="$alt_profile" \
    git -C "$repo" commit -qm "Redirect attempt" &&
    [ ! -e "$marker" ]; then
    pass "REVIEW_HOOKS_PROFILE cannot redirect which profile governs a commit"
  else
    fail "REVIEW_HOOKS_PROFILE cannot redirect which profile governs a commit"
  fi
}

test_install_writes_gitignore_entry() {
  local repo
  repo="$(new_repo gitignore)"

  if install_generic "$repo" &&
    [ -f "$repo/.gitignore" ] &&
    [ "$(grep -cx 'ai-reviews/' "$repo/.gitignore")" -eq 1 ] &&
    "$module_root/install.sh" \
      --repo "$repo" --force --profile generic >/dev/null &&
    [ "$(grep -cx 'ai-reviews/' "$repo/.gitignore")" -eq 1 ]; then
    pass "install adds an idempotent ai-reviews/ ignore entry"
  else
    fail "install adds an idempotent ai-reviews/ ignore entry"
  fi
}

test_dry_run
test_install_and_deactivate
test_existing_hook_refusal_and_composition
test_hook_path_restore
test_pre_commit_checks
test_doctor_tolerates_pre_2_1_runtime
test_force_upgrade_keeps_profile
test_commit_msg_checks
test_pre_push_without_ai
test_ai_review_and_sensitive_refusal
test_personal_quota_and_multi_ref_refusal
test_legacy_v1_profile_through_compat_adapter
test_doctor_reports_profile_version_one
test_python_review_gate_suite
test_lmm_page_audit_contract
test_merge_with_fixes_intake_profiles
test_hook_commands_all_run_when_one_reads_stdin
test_env_cannot_redirect_the_profile
test_install_writes_gitignore_entry

if [ "$failures" -gt 0 ]; then
  echo "$failures of $tests tests failed" >&2
  exit 1
fi

echo "all $tests tests passed"
