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

new_deliberation() {
  local repo="$1"
  local path="$repo/plans/model-deliberations/test.md"

  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'EOF'
# Model deliberation: fixture

Status: IN_PROGRESS
Next owner: Claude

## Task

Fixture task.

## Configuration

- Calls completed: 0

## Disagreement ledger

None.

## Resume

- Exact next prompt: continue
EOF
  printf '%s\n' "$path"
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

test_claude_alert_configuration() {
  local settings_root="$test_root/claude-alert"
  local settings_path="$settings_root/settings.json"

  mkdir -p "$settings_root"
  printf '%s\n' '{"theme":"dark"}' >"$settings_path"
  if python3 "$bundle_root/scripts/configure-claude-alert.py" \
    --settings "$settings_path" >/dev/null &&
    python3 - "$settings_path" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
raise SystemExit(
    0
    if value.get("theme") == "dark"
    and value.get("preferredNotifChannel") == "terminal_bell"
    else 1
)
PY
  then
    pass "Claude alert setup preserves settings and enables the terminal bell"
  else
    fail "Claude alert setup preserves settings and enables the terminal bell"
  fi
}

test_peer_runner_dry_runs() {
  local repo
  local deliberation
  local prompt="$test_root/peer-prompt.md"
  local preferences="$test_root/preferences.json"
  repo="$(new_repo peer-dry-run)"
  deliberation="$(new_deliberation "$repo")"
  printf '%s\n' "Challenge this proposal." >"$prompt"
  cp "$bundle_root/preferences.example.json" "$preferences"

  if "$bundle_root/.agents/skills/deliberate-with-peer/scripts/run-claude-peer.sh" \
    --repo "$repo" \
    --prompt-file "$prompt" \
    --deliberation-file "$deliberation" \
    --preferences "$preferences" \
    --dry-run 2>&1 | grep -q 'model: claude-fable-5' &&
    "$bundle_root/.claude/skills/deliberate-with-peer/scripts/run-codex-peer.sh" \
      --repo "$repo" \
      --prompt-file "$prompt" \
      --deliberation-file "$deliberation" \
      --preferences "$preferences" \
      --dry-run 2>&1 | grep -q 'model: gpt-5.6-sol'; then
    pass "peer runners resolve configurable models without launching either CLI"
  else
    fail "peer runners resolve configurable models without launching either CLI"
  fi
}

test_peer_runner_outputs() {
  local repo
  local deliberation
  local prompt="$test_root/peer-output-prompt.md"
  local fake_bin="$test_root/fake-peer-bin"
  repo="$(new_repo peer-output)"
  deliberation="$(new_deliberation "$repo")"
  printf '%s\n' "Ground and challenge this." >"$prompt"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"type":"result","result":"Claude grounded position"}'
EOF
  cat >"$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
output_file=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    output_file="$2"
    shift 2
  else
    shift
  fi
done
cat >/dev/null
printf '%s\n' "Codex grounded position" >"$output_file"
printf '%s\n' '{"type":"thread.started","thread_id":"11111111-1111-1111-1111-111111111111"}'
EOF
  chmod +x "$fake_bin/claude" "$fake_bin/codex"

  if PATH="$fake_bin:$PATH" \
    "$bundle_root/.agents/skills/deliberate-with-peer/scripts/run-claude-peer.sh" \
      --repo "$repo" \
      --prompt-file "$prompt" \
      --deliberation-file "$deliberation" 2>/dev/null |
      grep -q 'Claude grounded position' &&
    PATH="$fake_bin:$PATH" \
      "$bundle_root/.claude/skills/deliberate-with-peer/scripts/run-codex-peer.sh" \
      --repo "$repo" \
      --prompt-file "$prompt" \
      --deliberation-file "$deliberation" 2>/dev/null |
      grep -q 'Codex grounded position'; then
    pass "peer runners capture bounded responses from both CLIs"
  else
    fail "peer runners capture bounded responses from both CLIs"
  fi
}

test_cross_environment_protocol_stays_synced() {
  if cmp -s \
    "$bundle_root/.agents/skills/deliberate-with-peer/references/protocol.md" \
    "$bundle_root/.claude/skills/deliberate-with-peer/references/protocol.md" &&
    cmp -s \
      "$bundle_root/.agents/skills/deliberate-with-peer/references/deliberation-template.md" \
      "$bundle_root/.claude/skills/deliberate-with-peer/references/deliberation-template.md" &&
    cmp -s \
      "$bundle_root/.agents/skills/deliberate-with-peer/scripts/read-preference.py" \
      "$bundle_root/.claude/skills/deliberate-with-peer/scripts/read-preference.py"; then
    pass "cross-environment deliberation protocol remains synchronized"
  else
    fail "cross-environment deliberation protocol remains synchronized"
  fi
}

test_reciprocal_frontend_audit_contract() {
  if grep -q 'C-AUDIT-' \
    "$bundle_root/.agents/skills/delegate-frontend-to-claude/SKILL.md" &&
    grep -q 'frontend logic audit opportunity' \
      "$bundle_root/.claude/skills/ui-nitpicker/SKILL.md" &&
    grep -q 'Claude-authored frontend' \
      "$bundle_root/.claude/skills/codex-review/SKILL.md"; then
    pass "delegated and direct Claude frontend work expose the Codex audit"
  else
    fail "delegated and direct Claude frontend work expose the Codex audit"
  fi
}

make_dependency_path() {
  local path="$1"
  shift

  mkdir -p "$path"
  for command_name in "$@"; do
    ln -s "$(command -v "$command_name")" "$path/$command_name"
  done
}

test_dependency_check_is_profile_aware() {
  local repo
  local fake_bin="$test_root/dependency-profile-bin"
  local output
  repo="$(new_repo dependency-profile)"
  printf '%s\n' "AI_REVIEW_ENABLED=1" >"$repo/.review-hooks.conf"
  make_dependency_path "$fake_bin" git python3 rg sed awk grep find

  output="$(python3 "$bundle_root/scripts/manage-dependencies.py" \
    install \
    --repo "$repo" \
    --search-path "$fake_bin" \
    --package-manager apt \
    --dry-run 2>&1)"

  if grep -q 'apt-get install -y coreutils' <<<"$output" &&
    grep -q 'Claude, Codex, gh, and credentials remain operator-managed' <<<"$output"; then
    pass "dependency installer activates AI-review utilities without managing model credentials"
  else
    fail "dependency installer activates AI-review utilities without managing model credentials"
  fi
}

test_dependency_install_is_explicit_and_dry_runnable() {
  local repo
  local fake_bin="$test_root/dependency-install-bin"
  local output
  repo="$(new_repo dependency-install)"
  make_dependency_path "$fake_bin" git python3 sed awk grep find sha256sum

  output="$(python3 "$bundle_root/scripts/manage-dependencies.py" \
    install \
    --repo "$repo" \
    --search-path "$fake_bin" \
    --package-manager apt \
    --dry-run 2>&1)"

  if grep -q 'apt-get install -y ripgrep' <<<"$output" &&
    grep -q 'Dry run only; no packages were installed' <<<"$output"; then
    pass "dependency installation has an explicit non-mutating dry run"
  else
    fail "dependency installation has an explicit non-mutating dry run"
  fi
}

test_missing_model_clis_are_manual_capabilities() {
  local repo
  local fake_bin="$test_root/dependency-model-bin"
  local output
  repo="$(new_repo dependency-model)"
  make_dependency_path "$fake_bin" git python3 rg sed awk grep find sha256sum

  if output="$(python3 "$bundle_root/scripts/manage-dependencies.py" \
    check \
    --repo "$repo" \
    --search-path "$fake_bin" 2>&1)" &&
    grep -q 'WARN  claude' <<<"$output" &&
    grep -q 'WARN  codex' <<<"$output"; then
    pass "missing model CLIs require manual setup without blocking core installation"
  else
    fail "missing model CLIs require manual setup without blocking core installation"
  fi
}

test_deliberation_preferences_and_alerts_stay_scoped() {
  if grep -q 'claude.model' \
    "$bundle_root/.agents/skills/deliberate-with-peer/scripts/run-claude-peer.sh" &&
    grep -q 'codex.model' \
      "$bundle_root/.claude/skills/deliberate-with-peer/scripts/run-codex-peer.sh" &&
    ! grep -Rq 'codex-claude-skills/preferences.json' \
      "$bundle_root/.agents/skills/delegate-frontend-to-claude" \
      "$bundle_root/.claude/skills/codex-review" &&
    ! grep -Rq "printf.*\\\\a" \
      "$bundle_root/.agents/skills/deliberate-with-peer/scripts" \
      "$bundle_root/.agents/skills/delegate-frontend-to-claude/scripts"; then
    pass "expensive model preferences and Claude notifications remain narrowly scoped"
  else
    fail "expensive model preferences and Claude notifications remain narrowly scoped"
  fi
}

test_spend_ledger_settles_to_actual_spend() {
  local repo
  repo="$(new_repo spend-ledger)"

  if PYTHONPATH="$bundle_root/review-hooks" python3 - "$repo" <<'EOF'
import sys

from review_gate.adapter import ClaudeAdapter
from review_gate.store import SpendLedger

repo = sys.argv[1]
ledger = SpendLedger(repo)

reserved, total = ledger.reserve("run-1", 2.0, 25.0, 24)
assert reserved and total == 0.0, (reserved, total)
assert ledger.settle("run-1", 0.0375)

# The next run charges the settled cents, not the reserved cap.
reserved, total = ledger.reserve("run-2", 2.0, 25.0, 24)
assert reserved and abs(total - 0.0375) < 1e-9, (reserved, total)

# Settling an unknown run or a bad amount changes nothing.
assert not ledger.settle("missing-run", 1.0)
assert not ledger.settle("run-2", -1.0)
reserved, total = ledger.reserve("run-3", 2.0, 25.0, 24)
assert reserved and abs(total - 2.0375) < 1e-9, (reserved, total)

# The envelope parser feeds the settlement and rejects junk.
text, cost = ClaudeAdapter.parse_envelope(
    '{"result": "VERDICT: SAFE", "total_cost_usd": 0.031}'
)
assert text == "VERDICT: SAFE" and cost == 0.031, (text, cost)
assert ClaudeAdapter.parse_envelope("plain text") == (None, None)
assert ClaudeAdapter.parse_envelope(
    '{"result": 5, "total_cost_usd": true}'
) == (None, None)
EOF
  then
    pass "spend ledger settles reservations to reported actual spend"
  else
    fail "spend ledger settles reservations to reported actual spend"
  fi
}

test_install_is_inactive
test_drift_refusal
test_explicit_force
test_symlink_refusal
test_doctor_is_read_only
test_bootstrap_activation
test_claude_alert_configuration
test_peer_runner_dry_runs
test_peer_runner_outputs
test_cross_environment_protocol_stays_synced
test_reciprocal_frontend_audit_contract
test_dependency_check_is_profile_aware
test_dependency_install_is_explicit_and_dry_runnable
test_missing_model_clis_are_manual_capabilities
test_deliberation_preferences_and_alerts_stay_scoped
test_spend_ledger_settles_to_actual_spend

if [ "$failures" -gt 0 ]; then
  echo "$failures of $tests tests failed" >&2
  exit 1
fi

echo "all $tests tests passed"
