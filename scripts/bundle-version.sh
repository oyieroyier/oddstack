#!/usr/bin/env bash
# Shared bundle-version helpers for install.sh, doctor.sh, and the test suite.
#
# Per-tree diffs already detect that an installed copy differs from the bundle.
# What they cannot say is *why* it differs: a repository edited in place and a
# repository installed from an older release both read as "drift". The stamp
# records which release the installed files came from, so the two are
# distinguishable and a fleet of repositories can be swept for staleness.
#
# review-hooks/install.sh deliberately keeps its own copy of the digest idiom
# rather than sourcing this file: it is copied into target repositories and run
# from there, where scripts/ does not exist. Keep the two in sync by hand.

# Written at the target repository root by install.sh.
BUNDLE_STAMP_FILE=".codex-claude-skills-version"

# diff(1) flags excluding tool caches when comparing an installed tree to the
# bundle. install.sh and doctor.sh must agree on this: if they disagree, one
# reports a repository as current while the other reports the same repository
# as drifted.
BUNDLE_DIFF_EXCLUDES=(-x '__pycache__' -x '*.pyc' -x '.pytest_cache')

# The digests' inputs, held as DATA rather than written inline in the functions
# below. The completeness manifest is BUILT from these, so it cannot describe a
# narrower bundle than the digests actually read. Earlier versions restated the
# lists and drifted; a test that recovered them by parsing the function bodies
# then broke silently under an ordinary refactor.
BUNDLE_DIGEST_PATHS=(.claude/skills .agents/skills review-hooks VERSION)
RUNTIME_DIGEST_PATHS=(scripts hooks bin review_gate VERSION README.md)

# Bundle paths install.sh and doctor.sh execute or read outside the digests.
# Missing any of these makes those tools report a verdict about the TARGET when
# the fault is in the bundle doing the reporting.
BUNDLE_TOOL_PATHS=(
  scripts/bundle-version.sh
  scripts/manage-dependencies.py
  scripts/configure-claude-alert.py
  .claude/skills/collab-config/scripts/resolve_config.py
)

# Trees that must contain something, not merely exist. A bundle whose skills
# trees are present but empty installs nothing and still stamps itself current.
BUNDLE_NONEMPTY_TREES=(.claude/skills .agents/skills)

# Derived, never hand-written: digest inputs + runtime subtrees + tool paths.
BUNDLE_REQUIRED_PATHS=("${BUNDLE_DIGEST_PATHS[@]}" "${BUNDLE_TOOL_PATHS[@]}")
for _bundle_runtime_path in "${RUNTIME_DIGEST_PATHS[@]}"; do
  BUNDLE_REQUIRED_PATHS+=("review-hooks/$_bundle_runtime_path")
done
unset _bundle_runtime_path

# Print every reason the given bundle root is unusable, one per line. Empty
# output means the bundle is complete.
bundle_missing_paths() {
  local root="$1"
  local path

  for path in "${BUNDLE_REQUIRED_PATHS[@]}"; do
    [ -e "$root/$path" ] || printf '%s\n' "$path"
  done

  for path in "${BUNDLE_NONEMPTY_TREES[@]}"; do
    if [ -d "$root/$path" ] && [ -z "$(ls -A "$root/$path")" ]; then
      printf '%s (present but empty)\n' "$path"
    fi
  done
}

bundle_version() {
  cat "$1/VERSION"
}

# Digest every file under the given paths, relative to a root. Paths are
# NUL-delimited throughout so filenames containing spaces or newlines cannot
# split an entry, and sorted under LC_ALL=C so the result does not depend on
# filesystem ordering or locale. Tool caches are excluded to match the
# exclusions install.sh and doctor.sh use when diffing.
#
# Fails, rather than degrading, when sha256sum is missing: it is a required
# capability, and a silently unstamped install is the exact drift-blindness
# the stamp exists to remove.
tree_digest() {
  local root="$1"
  shift

  # Validate inputs before digesting. Without this, `find` fails on the missing
  # path, the digest comes back empty or partial, and callers report a broken
  # bundle as a stale target instead of as a broken bundle.
  local path
  for path in "$@"; do
    if [ ! -e "$root/$path" ]; then
      echo "[bundle] incomplete bundle, missing: $path" >&2
      return 1
    fi
  done

  (
    cd "$root" &&
      find "$@" \
        -type f \
        -not -path '*__pycache__*' \
        -not -name '*.pyc' \
        -not -path '*.pytest_cache*' \
        -print0 |
      LC_ALL=C sort -z |
      xargs -0 sha256sum |
      sha256sum |
      awk '{print $1}'
  )
}

# Everything install.sh copies, plus VERSION, so the stamp changes whenever
# installed content changes.
bundle_source_digest() {
  tree_digest "$1" "${BUNDLE_DIGEST_PATHS[@]}"
}

# The review runtime is versioned separately from the bundle release; this
# mirrors the digest review-hooks/install.sh stamps into .review-hooks/.
runtime_source_digest() {
  tree_digest "$1/review-hooks" "${RUNTIME_DIGEST_PATHS[@]}"
}

# Read one field from an installed stamp. Missing file or field yields "".
bundle_stamp_field() {
  local stamp_path="$1"
  local field="$2"

  [ -f "$stamp_path" ] || return 0
  sed -nE "s/^${field}: (.*)\$/\\1/p" "$stamp_path" | tail -n 1
}
