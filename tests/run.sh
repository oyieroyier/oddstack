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

# Content plus size and mtime for every tracked-or-not file outside .git, so a
# read-only assertion catches an in-place rewrite, not just an added path.
snapshot_repo() {
  local listing
  listing="$(mktemp)"
  find "$1" -path '*/.git' -prune -o -type f -print0 |
    LC_ALL=C sort -z > "$listing"
  {
    xargs -0 sha256sum < "$listing"
    xargs -0 stat -c '%n %s %Y' < "$listing"
  } | sha256sum
  rm -f "$listing"
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
    [ -f "$repo/.agents/skills/route-codex-subagents/SKILL.md" ] &&
    [ -z "$(git -C "$repo" config --local --get core.hooksPath || true)" ]; then
    pass "install copies helpers without activating hooks"
  else
    fail "install copies helpers without activating hooks"
  fi
}

test_install_stamps_the_bundle_release() {
  local repo
  local stamp
  repo="$(new_repo stamped)"
  "$bundle_root/install.sh" --repo "$repo" >/dev/null
  stamp="$repo/.codex-claude-skills-version"

  if [ -f "$stamp" ] &&
    grep -qx "version: $(cat "$bundle_root/VERSION")" "$stamp" &&
    grep -qE '^source-digest: [0-9a-f]{64}$' "$stamp"; then
    pass "install stamps the repository with the bundle release"
  else
    fail "install stamps the repository with the bundle release"
  fi
}

test_check_reports_a_current_install() {
  local repo
  repo="$(new_repo check_current)"
  "$bundle_root/install.sh" --repo "$repo" >/dev/null

  if "$bundle_root/install.sh" --check --repo "$repo" >/dev/null 2>&1; then
    pass "check exits zero for a freshly installed repository"
  else
    fail "check exits zero for a freshly installed repository"
  fi
}

test_check_detects_missing_and_drifted_content() {
  local repo
  local report
  repo="$(new_repo check_stale)"
  "$bundle_root/install.sh" --repo "$repo" >/dev/null
  printf '%s\n' "# local policy" >> "$repo/.claude/skills/codex-review/SKILL.md"
  rm -rf "$repo/.claude/skills/codex-computer-use"

  report="$("$bundle_root/install.sh" --check --repo "$repo" 2>&1)"
  if [ "$?" -eq 0 ]; then
    fail "check reports drifted and missing skills"
    return
  fi

  if printf '%s\n' "$report" | grep -q 'drifted   .claude/skills/codex-review' &&
    printf '%s\n' "$report" | grep -q 'missing   .claude/skills/codex-computer-use'; then
    pass "check reports drifted and missing skills"
  else
    fail "check reports drifted and missing skills"
    printf '%s\n' "$report" >&2
  fi
}

test_check_detects_an_older_bundle_release() {
  local repo
  local report
  repo="$(new_repo check_release)"
  "$bundle_root/install.sh" --repo "$repo" >/dev/null

  # Content matches the bundle, so only the stamp can reveal that these files
  # were installed from a different release.
  printf 'version: 0.0.1\nsource-digest: %064d\n' 0 \
    > "$repo/.codex-claude-skills-version"

  report="$("$bundle_root/install.sh" --check --repo "$repo" 2>&1)"
  if [ "$?" -ne 0 ] &&
    printf '%s\n' "$report" | grep -q 'a different bundle release than'; then
    pass "check detects content installed from a different bundle release"
  else
    fail "check detects content installed from a different bundle release"
    printf '%s\n' "$report" >&2
  fi
}

test_check_detects_another_build_of_the_same_release() {
  local repo
  local report
  repo="$(new_repo check_rebuild)"
  "$bundle_root/install.sh" --repo "$repo" >/dev/null

  # Same release number, different content digest: the bundle was rebuilt from
  # different sources. Only the digest can catch this, not the version.
  printf 'version: %s\nsource-digest: %064d\n' "$(cat "$bundle_root/VERSION")" 0 \
    > "$repo/.codex-claude-skills-version"

  report="$("$bundle_root/install.sh" --check --repo "$repo" 2>&1)"
  if [ "$?" -ne 0 ] &&
    printf '%s\n' "$report" | grep -q 'from another build of the bundle'; then
    pass "check separates another build of a release from a different release"
  else
    fail "check separates another build of a release from a different release"
    printf '%s\n' "$report" >&2
  fi
}

test_bundle_is_not_an_install_target() {
  local check_output
  local install_status=0
  local doctor_status=0
  local missing
  local required_paths

  # A sweep over a directory of repositories necessarily includes the bundle
  # itself; it must not be reported as an out-of-date install, and installing
  # into it must be refused rather than writing a stray stamp.
  if ! check_output="$("$bundle_root/install.sh" --check --repo "$bundle_root" 2>&1)"; then
    fail "the bundle reports itself as a source, not a stale install target"
    printf '%s\n' "$check_output" >&2
    return
  fi

  "$bundle_root/install.sh" --repo "$bundle_root" >/dev/null 2>&1 || install_status=$?

  if printf '%s\n' "$check_output" | grep -q 'bundle source, not an install target' &&
    [ "$install_status" -eq 2 ] &&
    [ ! -e "$bundle_root/.codex-claude-skills-version" ]; then
    pass "the bundle refuses to be installed into itself"
  else
    fail "the bundle refuses to be installed into itself"
  fi
}

test_bundle_guard_survives_a_symlinked_invocation() {
  local link_root
  local check_output

  # bundle_root is resolved with `pwd -P` so it stays comparable with the
  # physical path git reports. Invoking through a symlink previously defeated
  # the guard and wrote a stamp into the bundle.
  link_root="$test_root/symlinked-bundle"
  ln -sfn "$bundle_root" "$link_root"

  check_output="$("$link_root/install.sh" --check --repo "$link_root" 2>&1)" || true

  if printf '%s\n' "$check_output" | grep -q 'bundle source, not an install target' &&
    [ ! -e "$bundle_root/.codex-claude-skills-version" ]; then
    pass "the bundle guard holds through a symlinked invocation"
  else
    fail "the bundle guard holds through a symlinked invocation"
    printf '%s\n' "$check_output" >&2
  fi
}

test_doctor_distinguishes_no_install_from_foreign_skills() {
  local empty_repo
  local foreign_repo
  local empty_output
  local foreign_output
  local runtime_repo
  local runtime_output

  # "no bundle is installed here" must key off bundled content, not directory
  # existence: a repository's own unrelated skills are not an install, and
  # review-hooks alone is one.
  empty_repo="$(new_repo doctor_empty)"
  foreign_repo="$(new_repo doctor_foreign)"
  mkdir -p "$foreign_repo/.claude/skills/my-own"
  printf 'name: mine\n' > "$foreign_repo/.claude/skills/my-own/SKILL.md"

  # Capture before matching: `grep -q` closes the pipe on its first hit, and
  # under pipefail the resulting SIGPIPE would fail the pipeline regardless of
  # what doctor.sh reported.
  empty_output="$("$bundle_root/doctor.sh" --repo "$empty_repo" --skip-archives 2>&1)" || true
  foreign_output="$("$bundle_root/doctor.sh" --repo "$foreign_repo" --skip-archives 2>&1)" || true

  # Negative case: a repository holding only the activated runtime IS an
  # install, so the same string must NOT appear. Without this, a helper that
  # always printed it would satisfy the test.
  runtime_repo="$(new_repo doctor_runtime)"
  mkdir -p "$runtime_repo/.review-hooks"
  printf '2.2.0\n' > "$runtime_repo/.review-hooks/VERSION"
  runtime_output="$("$bundle_root/doctor.sh" --repo "$runtime_repo" --skip-archives 2>&1)" || true

  if printf '%s\n' "$empty_output" | grep -q 'no bundle is installed here' &&
    printf '%s\n' "$foreign_output" | grep -q 'no bundle is installed here' &&
    ! printf '%s\n' "$runtime_output" | grep -q 'no bundle is installed here'; then
    pass "doctor reports no install for empty and foreign-skill repositories"
  else
    fail "doctor reports no install for empty and foreign-skill repositories"
  fi
}

test_required_paths_cover_every_digest_input() {
  local helper="$bundle_root/scripts/bundle-version.sh"
  local consumed
  local uncovered=""
  local required
  local path

  # The completeness guard must cover everything the digests actually read.
  # The incomplete-bundle test reads BUNDLE_REQUIRED_PATHS, so it cannot notice
  # the manifest being too narrow — that is precisely how a bundle missing
  # review-hooks/bin installed cleanly and passed --check. This asserts the
  # invariant directly, against the digest definitions rather than the manifest.
  # Read the arrays the digests actually expand, rather than parsing them out of
  # the function bodies. The parsing version had the defect it was written to
  # catch: it guarded on the COMBINED extraction being non-empty, so refactoring
  # one digest function dropped its paths from the assertion silently.
  consumed="$(
    . "$helper"
    printf '%s\n' "${BUNDLE_DIGEST_PATHS[@]}"
    printf 'review-hooks/%s\n' "${RUNTIME_DIGEST_PATHS[@]}"
  )"

  if [ -z "$consumed" ]; then
    fail "digest input paths could not be read from bundle-version.sh"
    return
  fi

  # Both lists must be non-empty independently; a combined check cannot tell
  # that one of them vanished.
  if [ "$(printf '%s\n' "$consumed" | grep -c '^review-hooks/')" -eq 0 ] ||
    [ "$(printf '%s\n' "$consumed" | grep -vc '^review-hooks/')" -eq 0 ]; then
    fail "digest input paths are missing an entire list"
    return
  fi

  # Read the manifest in a subshell, matching the sibling call sites; sourcing
  # into the test shell leaked the arrays and functions into every later test.
  required="$(
    . "$helper"
    printf '%s\n' "${BUNDLE_REQUIRED_PATHS[@]}"
  )"

  for path in $consumed; do
    case "
$required
" in
      *"
$path
"*) ;;
      *) uncovered="$uncovered $path" ;;
    esac
  done

  if [ -z "$uncovered" ]; then
    pass "required-path manifest covers every digest input"
  else
    fail "required-path manifest covers every digest input"
    printf 'uncovered:%s\n' "$uncovered" >&2
  fi
}

test_hollow_bundle_is_refused() {
  local bundle_copy
  local repo
  local case_label
  local check_status
  local install_status
  local doctor_status

  # Hardcoded cases on purpose. test_incomplete_bundle_is_a_requirement_error
  # derives its cases from BUNDLE_REQUIRED_PATHS, so it shrinks when the
  # manifest shrinks and cannot notice a requirement being dropped. These two
  # shapes are the ones that shipped: skills trees present but empty, and a
  # bundle-owned tool doctor.sh executes.
  repo="$(new_repo hollow_target)"

  # empty-agents-skills is the case that isolates the non-empty check: emptying
  # .claude/skills also removes collab-config, which is a tool path, so that
  # case is caught by the existence check and proves nothing about emptiness.
  for case_label in empty-skills empty-agents-skills missing-tool; do
    bundle_copy="$test_root/hollow-bundle"
    rm -rf "$bundle_copy"
    mkdir -p "$bundle_copy"
    cp -R "$bundle_root/.claude" "$bundle_root/.agents" "$bundle_root/scripts" \
      "$bundle_root/review-hooks" "$bundle_root/VERSION" \
      "$bundle_root/install.sh" "$bundle_root/doctor.sh" "$bundle_copy/"

    case "$case_label" in
      empty-skills)
        rm -rf "${bundle_copy:?}/.claude/skills"/* "${bundle_copy:?}/.agents/skills"/*
        ;;
      empty-agents-skills)
        rm -rf "${bundle_copy:?}/.agents/skills"/*
        ;;
      missing-tool)
        rm -f "$bundle_copy/scripts/manage-dependencies.py"
        ;;
    esac

    check_status=0
    install_status=0
    doctor_status=0
    "$bundle_copy/install.sh" --check --repo "$repo" >/dev/null 2>&1 || check_status=$?
    "$bundle_copy/install.sh" --repo "$repo" >/dev/null 2>&1 || install_status=$?
    "$bundle_copy/doctor.sh" --repo "$repo" --skip-archives >/dev/null 2>&1 || doctor_status=$?

    if [ "$check_status" -ne 2 ] || [ "$install_status" -ne 2 ] ||
      [ "$doctor_status" -ne 2 ]; then
      fail "a hollow bundle is refused rather than installed and stamped"
      printf 'case=%s check=%s install=%s doctor=%s\n' \
        "$case_label" "$check_status" "$install_status" "$doctor_status" >&2
      return
    fi
  done

  if [ -e "$repo/.codex-claude-skills-version" ]; then
    fail "a hollow bundle is refused rather than installed and stamped"
    return
  fi

  pass "a hollow bundle is refused rather than installed and stamped"
}

test_review_hooks_installer_refuses_an_incomplete_module() {
  local module_copy
  local target
  local rc=0
  local dry_rc=0
  local declared
  local expected

  # The module installer cannot source ../scripts/bundle-version.sh — it runs
  # from inside target repositories — so it keeps its own copy of the required
  # list. Assert the two agree rather than trusting the comment that says to
  # keep them in sync.
  declared="$(
    sed -nE 's/^for required in (.*); do$/\1/p' "$bundle_root/review-hooks/install.sh" |
      head -n 1 | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' '
  )"
  expected="$(
    . "$bundle_root/scripts/bundle-version.sh"
    printf '%s\n' "${RUNTIME_DIGEST_PATHS[@]}" | LC_ALL=C sort | tr '\n' ' '
  )"

  if [ -z "$declared" ] || [ "$declared" != "$expected" ]; then
    fail "review-hooks installer's required list matches RUNTIME_DIGEST_PATHS"
    printf 'declared=[%s] expected=[%s]\n' "$declared" "$expected" >&2
    return
  fi

  module_copy="$test_root/broken-module"
  rm -rf "$module_copy"
  cp -R "$bundle_root/review-hooks" "$module_copy"
  rm -rf "$module_copy/bin"

  target="$(new_repo broken_module_target)"
  "$module_copy/install.sh" --repo "$target" --dry-run >/dev/null 2>&1 || dry_rc=$?
  "$module_copy/install.sh" --repo "$target" --no-activate >/dev/null 2>&1 || rc=$?

  # Exit 2, and nothing written: the old behaviour left a partial .review-hooks/
  # and exited 1, and --dry-run reported success on the same broken module.
  if [ "$rc" -eq 2 ] && [ "$dry_rc" -eq 2 ] && [ ! -e "$target/.review-hooks" ]; then
    pass "review-hooks installer refuses an incomplete module without writing"
  else
    fail "review-hooks installer refuses an incomplete module without writing"
    printf 'install=%s dry-run=%s runtime-dir-exists=%s\n' \
      "$rc" "$dry_rc" "$([ -e "$target/.review-hooks" ] && echo yes || echo no)" >&2
  fi
}

test_incomplete_bundle_is_a_requirement_error() {
  local bundle_copy
  local repo
  local check_status=0
  local install_status=0
  local doctor_status=0
  local missing
  local required_paths

  # A bundle missing any input the digest needs is a broken source, not a stale
  # target: every entry point must exit 2 ("a missing requirement"), never 1.
  # Each removable path is exercised, because guarding only the ones that had
  # already broken is what let this recur through a different path.
  repo="$(new_repo incomplete_target)"

  # Driven from the shared manifest rather than a copy of it, so a path added
  # to BUNDLE_REQUIRED_PATHS is automatically exercised. The earlier version
  # restated the guard's own five top-level paths, so it re-asserted the guard
  # and never reached the digest inputs beneath review-hooks/.
  required_paths="$(
    . "$bundle_root/scripts/bundle-version.sh"
    printf '%s\n' "${BUNDLE_REQUIRED_PATHS[@]}"
  )"

  for missing in $required_paths; do
    bundle_copy="$test_root/incomplete-bundle"
    rm -rf "$bundle_copy"
    mkdir -p "$bundle_copy"
    cp -R "$bundle_root/.claude" "$bundle_root/.agents" "$bundle_root/scripts" \
      "$bundle_root/review-hooks" "$bundle_root/VERSION" \
      "$bundle_root/install.sh" "$bundle_root/doctor.sh" "$bundle_copy/"
    rm -rf "${bundle_copy:?}/$missing"

    check_status=0
    install_status=0
    doctor_status=0
    "$bundle_copy/install.sh" --check --repo "$repo" >/dev/null 2>&1 || check_status=$?
    "$bundle_copy/install.sh" --repo "$repo" >/dev/null 2>&1 || install_status=$?
    "$bundle_copy/doctor.sh" --repo "$repo" --skip-archives >/dev/null 2>&1 || doctor_status=$?

    if [ "$check_status" -ne 2 ] || [ "$install_status" -ne 2 ] ||
      [ "$doctor_status" -ne 2 ]; then
      fail "an incomplete bundle exits 2 rather than reporting a stale target"
      printf 'missing=%s check=%s install=%s doctor=%s\n' \
        "$missing" "$check_status" "$install_status" "$doctor_status" >&2
      return
    fi
  done

  pass "an incomplete bundle exits 2 rather than reporting a stale target"
}

test_syntax_check_still_fails_on_a_missing_named_script() {
  local helper
  local missing_status=0
  local present_status=0
  local glob_status=0

  # The unexpanded-glob skip must not silence an explicitly named path, or
  # renaming a checked script would drop its coverage unnoticed.
  #
  # Extraction is asserted before use: if the sed anchors ever drift, `helper`
  # is empty, `eval ""` succeeds, and every call below returns 127 — which
  # would look like a pass without testing anything.
  helper="$(sed -n '/^check_shell_syntax()/,/^}/p' "$bundle_root/tests/run-all.sh")"
  if ! printf '%s\n' "$helper" | grep -q '^check_shell_syntax()' ||
    ! printf '%s\n' "$helper" | grep -q 'bash -n'; then
    fail "syntax check helper could not be extracted from run-all.sh"
    return
  fi

  (
    eval "$helper"
    if ! declare -F check_shell_syntax >/dev/null; then
      exit 3
    fi

    # Negative: a named path that does not exist must fail.
    check_shell_syntax "$test_root/definitely-not-here.sh" >/dev/null 2>&1 || exit 10
    exit 0
  )
  missing_status=$?

  (
    eval "$helper"
    # Positive: a real, valid script must pass, so a helper that always fails
    # cannot satisfy this test.
    check_shell_syntax "$bundle_root/install.sh" >/dev/null 2>&1 || exit 11
    exit 0
  )
  present_status=$?

  (
    eval "$helper"
    # An unexpanded glob must still be skipped rather than failing.
    check_shell_syntax "$test_root"/no-such-dir/*.sh >/dev/null 2>&1 || exit 12
    exit 0
  )
  glob_status=$?

  if [ "$missing_status" -eq 10 ] && [ "$present_status" -eq 0 ] &&
    [ "$glob_status" -eq 0 ]; then
    pass "syntax check fails on a named script that is missing"
  else
    fail "syntax check fails on a named script that is missing"
    printf 'missing=%s present=%s glob=%s\n' \
      "$missing_status" "$present_status" "$glob_status" >&2
  fi
}

test_install_and_doctor_share_cache_exclusions() {
  local repo
  local doctor_output

  # install.sh --check and doctor.sh must not contradict each other on the same
  # repository. A tool cache in an installed skill is the case that historically
  # split them.
  repo="$(new_repo exclusions)"
  "$bundle_root/install.sh" --repo "$repo" >/dev/null
  mkdir -p "$repo/.claude/skills/codex-review/.pytest_cache"
  printf 'tag\n' > "$repo/.claude/skills/codex-review/.pytest_cache/CACHEDIR.TAG"

  doctor_output="$("$bundle_root/doctor.sh" --repo "$repo" --skip-archives 2>&1)"

  if "$bundle_root/install.sh" --check --repo "$repo" >/dev/null 2>&1 &&
    printf '%s\n' "$doctor_output" | grep -q 'PASS  .claude/skills/codex-review matches the bundle'; then
    pass "install and doctor agree about tool caches in installed skills"
  else
    fail "install and doctor agree about tool caches in installed skills"
    printf '%s\n' "$doctor_output" | grep 'codex-review' >&2
  fi
}

test_runtime_digest_matches_the_review_hooks_installer() {
  local bundle_copy
  local helper_digest
  local installer_digest
  local case_label
  local target

  # doctor.sh compares runtime_source_digest() against the digest
  # review-hooks/install.sh stamps. The two are separate implementations by
  # necessity, so agreement on a clean tree proves nothing — exercise the file
  # shapes that actually distinguish the idioms.
  for case_label in clean pytest-cache spaced-name; do
    bundle_copy="$test_root/digest-$case_label"
    rm -rf "$bundle_copy"
    mkdir -p "$bundle_copy"
    cp -R "$bundle_root/review-hooks" "$bundle_copy/"
    cp -R "$bundle_root/scripts" "$bundle_copy/"

    case "$case_label" in
      pytest-cache)
        mkdir -p "$bundle_copy/review-hooks/scripts/.pytest_cache"
        printf 'tag\n' > "$bundle_copy/review-hooks/scripts/.pytest_cache/CACHEDIR.TAG"
        ;;
      spaced-name)
        printf 'x\n' > "$bundle_copy/review-hooks/bin/a b.txt"
        ;;
    esac

    # Drive the real installer rather than restating its idiom here, so an edit
    # to review-hooks/install.sh breaks this test instead of slipping through.
    target="$(new_repo "digest-target-$case_label")"
    "$bundle_copy/review-hooks/install.sh" \
      --repo "$target" --no-activate >/dev/null 2>&1

    helper_digest="$(
      . "$bundle_copy/scripts/bundle-version.sh"
      runtime_source_digest "$bundle_copy"
    )"
    installer_digest="$(
      sed -nE 's/^source-digest: (.*)$/\1/p' "$target/.review-hooks/bundle-version"
    )"

    if [ "$helper_digest" != "$installer_digest" ]; then
      fail "runtime digest helper matches the review-hooks installer ($case_label)"
      return
    fi
  done

  pass "runtime digest helper matches the review-hooks installer"
}

test_check_writes_nothing() {
  local repo
  local before
  local after
  repo="$(new_repo check_readonly)"
  # Install first, so every tree exists and --check takes its comparison paths
  # rather than short-circuiting on "missing". Digest the content and the mtimes,
  # not just the path list, so an in-place rewrite cannot pass.
  "$bundle_root/install.sh" --repo "$repo" >/dev/null

  before="$(snapshot_repo "$repo")"
  "$bundle_root/install.sh" --check --repo "$repo" >/dev/null 2>&1 || true
  after="$(snapshot_repo "$repo")"

  if [ "$before" = "$after" ]; then
    pass "check never writes to the target repository"
  else
    fail "check never writes to the target repository"
  fi
}

test_subagent_routing_policy_is_bounded() {
  local skill="$bundle_root/.agents/skills/route-codex-subagents/SKILL.md"
  local packet="$bundle_root/.agents/skills/route-codex-subagents/references/task-packet.md"
  local tool="$bundle_root/.agents/skills/route-codex-subagents/scripts/subagent_ledger.py"
  local ledger="$test_root/subagent-ledger.json"
  local descendant_ledger="$test_root/subagent-descendant-ledger.json"
  local descendant_observe_status
  local descendant_status
  local token

  python3 "$tool" --ledger "$ledger" init --task-id task-a --root-agent /root >/dev/null || {
    fail "Codex subagent routing enforces durable budgets and descendant reconciliation"
    return
  }
  for agent_id in /root/a /root/b /root/c; do
    token="$(python3 "$tool" --ledger "$ledger" reserve-spawn \
      --role explorer --model gpt-5.6-terra)" || {
      fail "Codex subagent routing enforces durable budgets and descendant reconciliation"
      return
    }
    python3 "$tool" --ledger "$ledger" settle-spawn \
      --token "$token" --agent-id "$agent_id" >/dev/null || {
      fail "Codex subagent routing enforces durable budgets and descendant reconciliation"
      return
    }
  done

  if python3 "$tool" --ledger "$ledger" reserve-spawn \
    --role explorer --model gpt-5.6-terra >/dev/null 2>&1; then
    fail "Codex subagent routing enforces durable budgets and descendant reconciliation"
    return
  fi
  # Reopening and even mistakenly re-initializing the same ledger cannot reset usage.
  if ! python3 "$tool" --ledger "$ledger" resume --task-id task-a |
    grep -q '"creations": 3' ||
    ! python3 "$tool" --ledger "$ledger" init --task-id task-a --root-agent /root |
      grep -q '"creations": 3' ||
    python3 "$tool" --ledger "$test_root/missing-ledger.json" resume \
      --task-id task-a >/dev/null 2>&1; then
    fail "Codex subagent routing enforces durable budgets and descendant reconciliation"
    return
  fi

  python3 "$tool" --ledger "$descendant_ledger" init --task-id task-b --root-agent /root >/dev/null
  token="$(python3 "$tool" --ledger "$descendant_ledger" reserve-spawn \
    --role implementer --model gpt-5.6-terra)"
  python3 "$tool" --ledger "$descendant_ledger" settle-spawn \
    --token "$token" --agent-id /root/worker >/dev/null
  python3 "$tool" --ledger "$descendant_ledger" observe-agent \
    --agent-id /root/worker/grandchild --parent-id /root/worker >/dev/null 2>&1
  descendant_observe_status="$?"
  descendant_status="$(python3 "$tool" --ledger "$descendant_ledger" status)"
  if [ "$descendant_observe_status" -ne 3 ] ||
    ! grep -q '"status": "VIOLATED"' <<<"$descendant_status" ||
    ! grep -q '"creations": 2' <<<"$descendant_status" ||
    ! grep -q '"turns": 2' <<<"$descendant_status" ||
    python3 "$tool" --ledger "$descendant_ledger" reserve-spawn \
      --role reviewer --model gpt-5.6-sol >/dev/null 2>&1 ||
    ! grep -q 'inspect the complete root agent tree' "$skill" ||
    ! grep -q 'SATISFIED / UNSATISFIED / UNCERTAIN' "$skill" ||
    ! grep -q 'Do not spawn subagents' "$packet"; then
    fail "Codex subagent routing enforces durable budgets and descendant reconciliation"
    return
  fi

  pass "Codex subagent routing enforces durable budgets and descendant reconciliation"
}

test_subagent_ledger_requires_canonical_root() {
  local tool="$bundle_root/.agents/skills/route-codex-subagents/scripts/subagent_ledger.py"
  local root_ledger="$test_root/subagent-root-ledger.json"
  local status

  if python3 "$tool" --ledger "$root_ledger" init --task-id missing-root >/dev/null 2>&1; then
    fail "Codex subagent ledger requires and honors the canonical root agent"
    return
  fi

  python3 "$tool" --ledger "$root_ledger" init --task-id custom-root \
    --root-agent /session/root >/dev/null
  python3 "$tool" --ledger "$root_ledger" observe-agent \
    --agent-id /session/root/direct --parent-id /session/root >/dev/null || {
    fail "Codex subagent ledger requires and honors the canonical root agent"
    return
  }
  status="$(python3 "$tool" --ledger "$root_ledger" status)"
  if ! grep -q '"creations": 1' <<<"$status" ||
    ! grep -q '"status": "ACTIVE"' <<<"$status"; then
    fail "Codex subagent ledger requires and honors the canonical root agent"
    return
  fi

  pass "Codex subagent ledger requires and honors the canonical root agent"
}

test_subagent_ledger_baselines_historical_agents() {
  local tool="$bundle_root/.agents/skills/route-codex-subagents/scripts/subagent_ledger.py"
  local ledger="$test_root/subagent-baseline-ledger.json"
  local status

  python3 "$tool" --ledger "$ledger" init --task-id baseline \
    --root-agent /session/root \
    --baseline-agent /session/root/old-worker \
    --baseline-agent /session/root/old-worker/descendant >/dev/null || {
    fail "Codex subagent ledger does not charge historical baseline agents"
    return
  }
  python3 "$tool" --ledger "$ledger" observe-agent \
    --agent-id /session/root/old-worker --parent-id /session/root >/dev/null || {
    fail "Codex subagent ledger does not charge historical baseline agents"
    return
  }
  python3 "$tool" --ledger "$ledger" observe-agent \
    --agent-id /session/root/old-worker/descendant \
    --parent-id /session/root/old-worker >/dev/null || {
    fail "Codex subagent ledger does not charge historical baseline agents"
    return
  }
  status="$(python3 "$tool" --ledger "$ledger" status)"
  if ! grep -q '"version": 2' "$ledger" ||
    ! grep -q '"root_agent": "/session/root"' <<<"$status" ||
    ! grep -q '"creations": 0' <<<"$status" ||
    ! grep -q '"turns": 0' <<<"$status" ||
    ! grep -q '"status": "ACTIVE"' <<<"$status" ||
    python3 "$tool" --ledger "$ledger" init --task-id baseline \
      --root-agent /session/root \
      --baseline-agent /session/root/old-worker \
      --baseline-agent /session/root/old-worker/descendant \
      --baseline-agent /session/root/new-worker >/dev/null 2>&1; then
    fail "Codex subagent ledger does not charge historical baseline agents"
    return
  fi

  pass "Codex subagent ledger does not charge historical baseline agents"
}

test_subagent_ledger_rejects_baseline_spawn_settlement() {
  local tool="$bundle_root/.agents/skills/route-codex-subagents/scripts/subagent_ledger.py"
  local ledger="$test_root/subagent-baseline-settlement-ledger.json"
  local token

  python3 "$tool" --ledger "$ledger" init --task-id baseline-settlement \
    --root-agent /session/root \
    --baseline-agent /session/root/old-worker >/dev/null
  token="$(python3 "$tool" --ledger "$ledger" reserve-spawn \
    --role explorer --model gpt-5.6-terra)"
  if python3 "$tool" --ledger "$ledger" settle-spawn \
    --token "$token" --agent-id /session/root/old-worker >/dev/null 2>&1; then
    fail "Codex subagent ledger rejects baseline ids during spawn settlement"
    return
  fi
  if ! python3 - "$ledger" "$token" <<'PY'
import json
import sys

ledger, token = sys.argv[1:]
state = json.loads(open(ledger, encoding="utf-8").read())
assert "/session/root/old-worker" not in state["agents"]
assert state["reservations"][token]["status"] == "RESERVED"
assert state["usage"] == {"creations": 1, "turns": 1}
PY
  then
    fail "Codex subagent ledger rejects baseline ids during spawn settlement"
    return
  fi
  python3 "$tool" --ledger "$ledger" settle-spawn \
    --token "$token" --agent-id /session/root/new-worker >/dev/null || {
    fail "Codex subagent ledger rejects baseline ids during spawn settlement"
    return
  }

  pass "Codex subagent ledger rejects baseline ids during spawn settlement"
}

test_subagent_ledger_reconciles_pending_spawn() {
  local tool="$bundle_root/.agents/skills/route-codex-subagents/scripts/subagent_ledger.py"
  local ledger="$test_root/subagent-pending-ledger.json"
  local pending_token
  local status
  local token

  python3 "$tool" --ledger "$ledger" init --task-id pending \
    --root-agent /session/root >/dev/null
  for agent_id in /session/root/one /session/root/two; do
    token="$(python3 "$tool" --ledger "$ledger" reserve-spawn \
      --role explorer --model gpt-5.6-terra)"
    python3 "$tool" --ledger "$ledger" settle-spawn \
      --token "$token" --agent-id "$agent_id" >/dev/null
  done
  pending_token="$(python3 "$tool" --ledger "$ledger" reserve-spawn \
    --role explorer --model gpt-5.6-terra)"
  python3 "$tool" --ledger "$ledger" observe-agent \
    --agent-id /session/root/recovered --parent-id /session/root >/dev/null || {
    fail "Codex subagent ledger reconciles an observed child with its pending spawn"
    return
  }
  # A delayed spawn response may still attempt the original settlement; it is idempotent.
  python3 "$tool" --ledger "$ledger" settle-spawn \
    --token "$pending_token" --agent-id /session/root/recovered >/dev/null || {
    fail "Codex subagent ledger reconciles an observed child with its pending spawn"
    return
  }
  status="$(python3 "$tool" --ledger "$ledger" status)"
  if ! grep -q '"creations": 3' <<<"$status" ||
    ! grep -q '"turns": 3' <<<"$status" ||
    ! grep -q '"status": "ACTIVE"' <<<"$status" ||
    ! grep -q '"agent_id": "/session/root/recovered"' <<<"$status" ||
    grep -q '"status": "PENDING"' <<<"$status" ||
    [ -z "$pending_token" ]; then
    fail "Codex subagent ledger reconciles an observed child with its pending spawn"
    return
  fi

  pass "Codex subagent ledger reconciles an observed child with its pending spawn"
}

test_subagent_ledger_rejects_multiple_pending_spawns() {
  local tool="$bundle_root/.agents/skills/route-codex-subagents/scripts/subagent_ledger.py"
  local ledger="$test_root/subagent-multiple-pending-ledger.json"
  local status

  python3 "$tool" --ledger "$ledger" init --task-id multiple-pending \
    --root-agent /session/root >/dev/null
  python3 "$tool" --ledger "$ledger" reserve-spawn \
    --role explorer --model gpt-5.6-terra >/dev/null
  if python3 "$tool" --ledger "$ledger" reserve-spawn \
    --role implementer --model gpt-5.6-terra >/dev/null 2>&1; then
    fail "Codex subagent ledger permits only one unresolved spawn reservation"
    return
  fi
  status="$(python3 "$tool" --ledger "$ledger" status)"
  if ! grep -q '"creations": 1' <<<"$status" ||
    ! grep -q '"turns": 1' <<<"$status" ||
    ! grep -q '"status": "ACTIVE"' <<<"$status"; then
    fail "Codex subagent ledger permits only one unresolved spawn reservation"
    return
  fi

  pass "Codex subagent ledger permits only one unresolved spawn reservation"
}

test_subagent_ledger_closes_charged_failed_spawn() {
  local tool="$bundle_root/.agents/skills/route-codex-subagents/scripts/subagent_ledger.py"
  local ledger="$test_root/subagent-failed-spawn-ledger.json"
  local failed_token
  local next_token
  local status

  python3 "$tool" --ledger "$ledger" init --task-id failed-spawn \
    --root-agent /session/root >/dev/null
  failed_token="$(python3 "$tool" --ledger "$ledger" reserve-spawn \
    --role explorer --model gpt-5.6-terra)"
  if python3 "$tool" --ledger "$ledger" fail-spawn \
    --token "$failed_token" --reason "CLI rejected the spawn" >/dev/null 2>&1; then
    fail "Codex subagent ledger closes charged failed spawns after tree reconciliation"
    return
  fi
  python3 "$tool" --ledger "$ledger" fail-spawn \
    --token "$failed_token" --reason "CLI rejected the spawn" \
    --tree-reconciled >/dev/null || {
    fail "Codex subagent ledger closes charged failed spawns after tree reconciliation"
    return
  }
  next_token="$(python3 "$tool" --ledger "$ledger" reserve-spawn \
    --role implementer --model gpt-5.6-terra)" || {
    fail "Codex subagent ledger closes charged failed spawns after tree reconciliation"
    return
  }
  status="$(python3 "$tool" --ledger "$ledger" status)"
  if ! grep -q '"creations": 2' <<<"$status" ||
    ! grep -q '"turns": 2' <<<"$status" ||
    ! grep -q '"status": "FAILED"' <<<"$status" ||
    ! grep -q '"tree_reconciled": true' <<<"$status" ||
    [ -z "$next_token" ]; then
    fail "Codex subagent ledger closes charged failed spawns after tree reconciliation"
    return
  fi

  pass "Codex subagent ledger closes charged failed spawns after tree reconciliation"
}

test_subagent_ledger_rejects_prebaseline_schema() {
  local tool="$bundle_root/.agents/skills/route-codex-subagents/scripts/subagent_ledger.py"
  local ledger="$test_root/subagent-legacy-ledger.json"

  cat >"$ledger" <<'EOF'
{
  "version": 1,
  "task_id": "legacy",
  "root_agent": "/root",
  "status": "ACTIVE",
  "caps": {"creations": 3, "turns": 4},
  "usage": {"creations": 0, "turns": 0},
  "agents": {},
  "reservations": {},
  "violations": [],
  "events": []
}
EOF

  if python3 "$tool" --ledger "$ledger" resume --task-id legacy >/dev/null 2>&1; then
    fail "Codex subagent ledger rejects schemas that predate task baselines"
    return
  fi

  pass "Codex subagent ledger rejects schemas that predate task baselines"
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
    [ -x "$repo/.collaboration-hooks/commit-msg" ] &&
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

  if PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$bundle_root/review-hooks" python3 - "$repo" <<'EOF'
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

# The envelope parser feeds the settlement and rejects junk. Only the
# captured success shape (type/result, subtype/success, is_error false)
# may expose result text.
parsed = ClaudeAdapter.parse_envelope(
    '{"type": "result", "subtype": "success", "is_error": false,'
    ' "result": "VERDICT: SAFE", "total_cost_usd": 0.031}'
)
assert parsed.outcome == "completed", parsed
assert parsed.result_text == "VERDICT: SAFE" and parsed.actual_usd == 0.031
assert ClaudeAdapter.parse_envelope("plain text").outcome == "invalid_envelope"
assert ClaudeAdapter.parse_envelope(
    '{"result": 5, "total_cost_usd": true}'
).outcome == "invalid_envelope"

# H1: an error envelope embedding a valid result never exposes it, but
# its trustworthy cost still reaches the settlement.
h1 = ClaudeAdapter.parse_envelope(
    '{"type": "result", "subtype": "error_during_execution",'
    ' "is_error": true, "api_error_status": 429,'
    ' "result": "VERDICT: SAFE", "total_cost_usd": 0.002}'
)
assert h1.outcome == "rate_limited" and h1.result_text is None, h1
assert h1.actual_usd == 0.002

# Non-finite costs cannot poison the window into permitting all spend.
nan = ClaudeAdapter.parse_envelope(
    '{"type": "result", "subtype": "success", "is_error": false,'
    ' "result": "x", "total_cost_usd": NaN}'
)
assert nan.outcome == "completed" and nan.actual_usd is None, nan
assert not ledger.settle("run-2", float("nan"))
assert not ledger.settle("run-2", float("inf"))

# Settled amounts round up, never down.
assert ledger.settle("run-3", 0.00001)
reserved, total = ledger.reserve("run-4", 2.0, 25.0, 24)
assert reserved and abs(total - 2.0376) < 1e-9, (reserved, total)
EOF
  then
    pass "spend ledger settles reservations to reported actual spend"
  else
    fail "spend ledger settles reservations to reported actual spend"
  fi
}

test_collab_config_resolution() {
  local resolver="$bundle_root/.claude/skills/collab-config/scripts/resolve_config.py"
  local repo
  local prefs="$test_root/collab-prefs.json"
  repo="$(new_repo collab-config)"

  cat >"$prefs" <<'EOF'
{
  "claude": {"model": "claude-fable-5", "effort": "xhigh"},
  "codex": {"model": "gpt-5.6-sol", "effort": "high"},
  "skills": {"codex-review": {"model": "gpt-5.6-terra", "effort": "medium"}},
  "modelRates": {
    "gpt-5.6-sol": {"input": 1.75, "output": 14.0},
    "broken": {"input": "not-a-number"}
  }
}
EOF

  if python3 "$resolver" --preferences "$prefs" --repo "$repo" --skill codex-review |
    grep -q '"model": "gpt-5.6-terra"' &&
    python3 "$resolver" --preferences "$prefs" --repo "$repo" --skill codex-implementation |
      grep -q '"model": "gpt-5.6-sol"' &&
    python3 "$resolver" --preferences "$prefs" --repo "$repo" \
      --skill deliberate-with-peer --provider claude |
      grep -q '"model": "claude-fable-5"' &&
    ! python3 "$resolver" --preferences "$prefs" --repo "$repo" \
      --skill deliberate-with-peer >/dev/null 2>&1 &&
    python3 "$resolver" --preferences "$prefs" --repo "$repo" --show 2>&1 >/dev/null |
      grep -q 'malformed modelRates entry' &&
    python3 "$resolver" --preferences "$prefs" --repo "$repo" --show 2>/dev/null |
      python3 -c 'import json,sys; rates=json.load(sys.stdin)["modelRates"]; \
raise SystemExit(0 if "broken" not in rates and rates["gpt-5.6-sol"]["cacheRead"] == 0.175 else 1)' &&
    ! python3 "$resolver" --preferences "$prefs" --repo "$repo" \
      --skill codex-review --provider claude >/dev/null 2>&1; then
    pass "collab-config resolves skill overrides and drops malformed rates"
  else
    fail "collab-config resolves skill overrides and drops malformed rates"
    return
  fi

  # Malformed user preferences fail with the loud named error, not a
  # traceback: wrong scalar types, non-object sections, unhashable policy
  # values, and non-finite budgets alike. A null skill entry means unset.
  local prefs_error
  local bad_prefs
  for bad_prefs in \
    '{"codex": {"maxBudgetUsd": "20"}}' \
    '{"peerAudit": "off"}' \
    '{"deliberation": 5}' \
    '{"peerAudit": {"policy": []}}' \
    '{"claude": {"maxBudgetUsd": Infinity}}'; do
    printf '%s\n' "$bad_prefs" >"$test_root/collab-bad-prefs.json"
    prefs_error="$(python3 "$resolver" --preferences "$test_root/collab-bad-prefs.json" \
      --repo "$repo" --skill codex-implementation 2>&1 >/dev/null)"
    if [ "$?" -ne 2 ] || grep -q 'Traceback' <<<"$prefs_error"; then
      fail "collab-config validates user preferences before comparing them"
      return
    fi
  done
  printf '%s\n' '{"codex": {"model": "gpt-5.6-sol"}, "skills": {"codex-review": null}}' \
    >"$test_root/collab-null-skill.json"
  if python3 "$resolver" --preferences "$test_root/collab-null-skill.json" \
    --repo "$repo" --skill codex-review |
    grep -q '"model": "gpt-5.6-sol"'; then
    pass "collab-config validates user preferences before comparing them"
  else
    fail "collab-config validates user preferences before comparing them"
  fi
}

test_repo_policy_only_tightens() {
  local resolver="$bundle_root/.claude/skills/collab-config/scripts/resolve_config.py"
  local repo
  local prefs="$test_root/tighten-prefs.json"
  local widen_error
  repo="$(new_repo repo-policy)"

  cat >"$prefs" <<'EOF'
{"codex": {"model": "gpt-5.6-sol", "maxBudgetUsd": 20}, "peerAudit": {"policy": "offer"}}
EOF

  printf '%s\n' '{"peerAudit": {"policy": "required"}, "codex": {"maxBudgetUsd": 5}}' \
    >"$repo/.codex-claude-skills.json"
  if ! python3 "$resolver" --preferences "$prefs" --repo "$repo" --policy peerAudit |
    grep -q '"source": "repo"' ||
    ! python3 "$resolver" --preferences "$prefs" --repo "$repo" --skill codex-implementation |
      grep -q '"maxBudgetUsd": 5'; then
    fail "repository policy tightens spend and process controls, never widens them"
    return
  fi

  printf '%s\n' '{"peerAudit": {"policy": "off"}}' >"$repo/.codex-claude-skills.json"
  widen_error="$(python3 "$resolver" --preferences "$prefs" --repo "$repo" \
    --policy peerAudit 2>&1 >/dev/null)"
  if [ "$?" -eq 0 ] ||
    ! grep -q "'off'" <<<"$widen_error" ||
    ! grep -q "'offer'" <<<"$widen_error"; then
    fail "repository policy tightens spend and process controls, never widens them"
    return
  fi

  printf '%s\n' '{"codex": {"maxBudgetUsd": 50}}' >"$repo/.codex-claude-skills.json"
  widen_error="$(python3 "$resolver" --preferences "$prefs" --repo "$repo" \
    --skill codex-implementation 2>&1 >/dev/null)"
  if [ "$?" -eq 0 ] ||
    ! grep -q '50' <<<"$widen_error" ||
    ! grep -q '20' <<<"$widen_error"; then
    fail "repository policy tightens spend and process controls, never widens them"
    return
  fi

  printf '%s\n' '{"codex": {"model": "gpt-9"}}' >"$repo/.codex-claude-skills.json"
  if python3 "$resolver" --preferences "$prefs" --repo "$repo" \
    --skill codex-implementation >/dev/null 2>&1; then
    fail "repository policy tightens spend and process controls, never widens them"
    return
  fi

  # A repository cannot weaken below the documented default either, even when
  # the operator never wrote the key.
  printf '%s\n' '{"codex": {"model": "gpt-5.6-sol"}}' >"$test_root/tighten-defaults.json"
  printf '%s\n' '{"peerAudit": {"policy": "off"}}' >"$repo/.codex-claude-skills.json"
  widen_error="$(python3 "$resolver" --preferences "$test_root/tighten-defaults.json" \
    --repo "$repo" --policy peerAudit 2>&1 >/dev/null)"
  if [ "$?" -eq 0 ] ||
    ! grep -q "'off'" <<<"$widen_error" ||
    ! grep -q "'offer'" <<<"$widen_error"; then
    fail "repository policy tightens spend and process controls, never widens them"
    return
  fi

  # Structurally malformed repo values get the loud named error, not a traceback.
  printf '%s\n' '{"codex": {"maxBudgetUsd": {}}}' >"$repo/.codex-claude-skills.json"
  widen_error="$(python3 "$resolver" --preferences "$prefs" --repo "$repo" \
    --skill codex-implementation 2>&1 >/dev/null)"
  if [ "$?" -ne 2 ] || ! grep -q 'non-negative number' <<<"$widen_error"; then
    fail "repository policy tightens spend and process controls, never widens them"
    return
  fi

  # A repo budget cap bounds per-skill overrides too — including a cap equal
  # to the user's own provider value, and a null override cannot dodge it.
  local cap_case cap_value cap_prefs
  printf '%s\n' \
    '{"codex": {"model": "gpt-5.6-sol", "maxBudgetUsd": 20}, "skills": {"codex-review": {"maxBudgetUsd": 100}}}' \
    >"$test_root/tighten-skill-budget.json"
  printf '%s\n' \
    '{"codex": {"model": "gpt-5.6-sol", "maxBudgetUsd": 20}, "skills": {"codex-review": {"maxBudgetUsd": null, "model": null}}}' \
    >"$test_root/tighten-null-budget.json"
  for cap_case in "5 skill" "20 skill" "5 null"; do
    cap_value="${cap_case%% *}"
    case "${cap_case#* }" in
      skill) cap_prefs="$test_root/tighten-skill-budget.json" ;;
      null) cap_prefs="$test_root/tighten-null-budget.json" ;;
    esac
    printf '{"codex": {"maxBudgetUsd": %s}}\n' "$cap_value" \
      >"$repo/.codex-claude-skills.json"
    if ! python3 "$resolver" --preferences "$cap_prefs" \
      --repo "$repo" --skill codex-review |
      python3 -c "
import json, sys
resolved = json.load(sys.stdin)
assert resolved['maxBudgetUsd'] == ${cap_value}, resolved
assert resolved['sources']['maxBudgetUsd'] == 'repo', resolved
assert resolved['model'] == 'gpt-5.6-sol', resolved
"; then
      fail "repository policy tightens spend and process controls, never widens them"
      return
    fi
  done

  # A null top-level section means unset: it takes the repo tightening
  # instead of crashing the merge or dodging the cap.
  printf '%s\n' '{"codex": null, "peerAudit": null}' >"$test_root/tighten-null-section.json"
  printf '%s\n' '{"codex": {"maxBudgetUsd": 5}, "peerAudit": {"policy": "required"}}' \
    >"$repo/.codex-claude-skills.json"
  if ! python3 "$resolver" --preferences "$test_root/tighten-null-section.json" \
    --repo "$repo" --skill codex-implementation |
    grep -q '"maxBudgetUsd": 5' ||
    ! python3 "$resolver" --preferences "$test_root/tighten-null-section.json" \
      --repo "$repo" --policy peerAudit |
      grep -q '"policy": "required"'; then
    fail "repository policy tightens spend and process controls, never widens them"
    return
  fi

  # Structural junk in the policy value slot, non-finite numbers, and an
  # empty policy file all get the loud named error, never a traceback.
  local structural_error
  local bad_policy
  for bad_policy in \
    '{"peerAudit": {"policy": {}}}' \
    '{"codex": {"maxBudgetUsd": Infinity}}' \
    '{}'; do
    printf '%s\n' "$bad_policy" >"$repo/.codex-claude-skills.json"
    structural_error="$(python3 "$resolver" --preferences "$prefs" --repo "$repo" \
      --policy peerAudit 2>&1 >/dev/null)"
    if [ "$?" -ne 2 ] || grep -q 'Traceback' <<<"$structural_error"; then
      fail "repository policy tightens spend and process controls, never widens them"
      return
    fi
  done

  pass "repository policy tightens spend and process controls, never widens them"
}

test_session_governor_advises_without_blocking() {
  local governor="$bundle_root/.claude/skills/collab-config/scripts/session_governor.py"
  local prefs="$test_root/governor-prefs.json"
  local drifted="$test_root/governor-drifted.jsonl"
  local focused="$test_root/governor-focused.jsonl"

  cat >"$prefs" <<'EOF'
{"modelRates": {"claude-fable-5": {"input": 5.0, "output": 25.0}}}
EOF
  python3 - "$drifted" "$focused" <<'EOF'
import json
import sys


def transcript(path, files):
    lines = []
    for i in range(20):
        usage = {
            "input_tokens": 200,
            "output_tokens": 500,
            "cache_read_input_tokens": 400_000,
            "cache_creation_input_tokens": 20_000,
            "cache_creation": {
                "ephemeral_5m_input_tokens": 20_000,
                "ephemeral_1h_input_tokens": 0,
            },
        }
        message = {
            "model": "claude-fable-5",
            "usage": usage,
            "content": [
                {
                    "type": "tool_use",
                    "name": "Read",
                    "input": {"file_path": files[0] if i < 10 else files[-1]},
                }
            ],
        }
        lines.append(
            json.dumps({"type": "assistant", "requestId": f"req_{i}", "message": message})
        )
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


transcript(sys.argv[1], ["/repo/early.py", "/elsewhere/late.py"])
transcript(sys.argv[2], ["/repo/only.py"])
EOF

  if python3 "$governor" --transcript "$drifted" --preferences "$prefs" \
    --billing api --expensive-usd 1 |
    grep -q 'consider /session-handoff' &&
    ! python3 "$governor" --transcript "$focused" --preferences "$prefs" \
      --billing api --expensive-usd 1 |
      grep -q 'consider /session-handoff' &&
    python3 "$governor" --transcript "$drifted" --preferences "$prefs" --billing plan |
      grep -q 'API-equivalent (not charged on a plan)' &&
    printf 'not json' | python3 "$governor" --hook >/dev/null 2>&1; then
    pass "session governor prices transcripts and only advises on expensive drift"
  else
    fail "session governor prices transcripts and only advises on expensive drift"
    return
  fi

  # Hook mode swallows every failure: explicit JSON nulls in token counts and
  # malformed preferences must both still exit zero.
  local hostile="$test_root/governor-hostile.jsonl"
  printf '%s\n' \
    '{"type": "assistant", "message": {"model": "claude-fable-5", "usage": {"input_tokens": null, "cache_read_input_tokens": 5, "cache_creation": {"ephemeral_5m_input_tokens": null}}}}' \
    >"$hostile"
  printf '%s\n' 'not json at all' >"$test_root/governor-bad-prefs.json"
  printf '%s\n' \
    '{"type": "assistant", "message": {"model": "claude-fable-5", "usage": {"input_tokens": NaN, "cache_read_input_tokens": Infinity}}}' \
    >>"$hostile"
  if python3 "$governor" --transcript "$hostile" --preferences "$prefs" >/dev/null 2>&1 &&
    printf '{"transcript_path": "%s"}' "$hostile" |
    python3 "$governor" --hook --preferences "$test_root/governor-bad-prefs.json" \
      >/dev/null 2>&1 &&
    printf '{}' | python3 "$governor" --hook --billing plna >/dev/null 2>&1 &&
    printf '{}' | python3 "$governor" --hook --drift-threshold abc >/dev/null 2>&1 &&
    ! python3 "$governor" --transcript "$hostile" --billing plna >/dev/null 2>&1 &&
    ! printf '{}' | python3 "$governor" --hoo >/dev/null 2>&1; then
    pass "session governor hook mode never exits nonzero"
  else
    fail "session governor hook mode never exits nonzero"
  fi
}

test_collab_config_stays_synced() {
  if cmp -s \
    "$bundle_root/.claude/skills/collab-config/scripts/resolve_config.py" \
    "$bundle_root/.agents/skills/collab-config/scripts/resolve_config.py"; then
    pass "cross-environment collab-config resolver remains synchronized"
  else
    fail "cross-environment collab-config resolver remains synchronized"
  fi
}

test_release_archives_contain_no_tool_caches() {
  if tar -tzf "$bundle_root/codex-claude-skills.tar.gz" \
      | grep -Eq '__pycache__|\.pytest_cache|\.pyc$'; then
    fail "release archives contain no tool caches"
  else
    pass "release archives contain no tool caches"
  fi
}

test_release_archives_contain_only_bundle_content() {
  local listing
  listing="$(tar -tzf "$bundle_root/codex-claude-skills.tar.gz")"

  # package.sh --check only proves the archive matches the working tree, so
  # it cannot catch local tooling leaking into the bundle. Assert the shape
  # directly: no agent worktrees, no nested release archives, no VCS state.
  if printf '%s\n' "$listing" | grep -Eq 'worktrees/|codex-claude-skills\.(tar\.gz|zip)$|(^|/)\.git/'; then
    fail "release archives contain only bundle content"
    printf '%s\n' "$listing" \
      | grep -E 'worktrees/|codex-claude-skills\.(tar\.gz|zip)$|(^|/)\.git/' \
      | head -5 >&2
  elif [ -n "$(printf '%s\n' "$listing" \
      | sed -n 's|^codex-claude-skills/\.\(claude\|agents\)/\([^/]*\).*|\2|p' \
      | sort -u | grep -v '^skills$')" ]; then
    fail "release archives contain only bundle content"
    printf '%s\n' "$listing" \
      | sed -n 's|^codex-claude-skills/\.\(claude\|agents\)/\([^/]*\).*|\2|p' \
      | sort -u | grep -v '^skills$' >&2
  else
    pass "release archives contain only bundle content"
  fi
}

test_install_is_inactive
test_install_stamps_the_bundle_release
test_check_reports_a_current_install
test_check_detects_missing_and_drifted_content
test_check_detects_an_older_bundle_release
test_check_detects_another_build_of_the_same_release
test_bundle_is_not_an_install_target
test_bundle_guard_survives_a_symlinked_invocation
test_doctor_distinguishes_no_install_from_foreign_skills
test_required_paths_cover_every_digest_input
test_hollow_bundle_is_refused
test_review_hooks_installer_refuses_an_incomplete_module
test_incomplete_bundle_is_a_requirement_error
test_syntax_check_still_fails_on_a_missing_named_script
test_install_and_doctor_share_cache_exclusions
test_runtime_digest_matches_the_review_hooks_installer
test_check_writes_nothing
test_subagent_routing_policy_is_bounded
test_subagent_ledger_requires_canonical_root
test_subagent_ledger_baselines_historical_agents
test_subagent_ledger_rejects_baseline_spawn_settlement
test_subagent_ledger_reconciles_pending_spawn
test_subagent_ledger_rejects_multiple_pending_spawns
test_subagent_ledger_closes_charged_failed_spawn
test_subagent_ledger_rejects_prebaseline_schema
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
test_collab_config_resolution
test_repo_policy_only_tightens
test_session_governor_advises_without_blocking
test_collab_config_stays_synced
test_release_archives_contain_no_tool_caches
test_release_archives_contain_only_bundle_content

if [ "$failures" -gt 0 ]; then
  echo "$failures of $tests tests failed" >&2
  exit 1
fi

echo "all $tests tests passed"
