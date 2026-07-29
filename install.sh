#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$PWD}"
bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_skill_src="$bundle_root/.claude/skills"
claude_skill_dst="$repo_root/.claude/skills"
codex_skill_src="$bundle_root/.agents/skills"
codex_skill_dst="$repo_root/.agents/skills"
review_hooks_src="$bundle_root/review-hooks"
review_hooks_dst="$repo_root/review-hooks"

if [[ ! -d "$claude_skill_src" || ! -d "$codex_skill_src" || ! -d "$review_hooks_src" ]]; then
  echo "Could not find bundled skills and review hooks under: $bundle_root" >&2
  exit 1
fi

mkdir -p "$claude_skill_dst" "$codex_skill_dst"
cp -R "$claude_skill_src"/* "$claude_skill_dst"/
cp -R "$codex_skill_src"/* "$codex_skill_dst"/

if [[ -e "$review_hooks_dst" ]]; then
  review_hooks_result="Preserved existing review-hooks/; update it explicitly after reviewing the diff."
else
  mkdir -p "$review_hooks_dst"
  cp -R "$review_hooks_src"/* "$review_hooks_dst"/
  review_hooks_result="Copied optional review-hooks/ without activating it."
fi

echo "Installed Claude skills into: $claude_skill_dst"
echo "Installed Codex skills into: $codex_skill_dst"
echo "Installed skills:"
find "$claude_skill_dst" "$codex_skill_dst" -maxdepth 2 -name SKILL.md -print |
  sed "s#^$repo_root/##"

echo
echo "Optional: copy CLAUDE.md.codex-skills-snippet.md into your repository CLAUDE.md."
echo "$review_hooks_result"
echo "Inspect review-hooks/README.md, then run review-hooks/install.sh explicitly."
