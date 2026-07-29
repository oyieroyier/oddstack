#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$PWD}"
bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_skill_src="$bundle_root/.claude/skills"
claude_skill_dst="$repo_root/.claude/skills"
codex_skill_src="$bundle_root/.agents/skills"
codex_skill_dst="$repo_root/.agents/skills"

if [[ ! -d "$claude_skill_src" || ! -d "$codex_skill_src" ]]; then
  echo "Could not find bundled Claude and Codex skills under: $bundle_root" >&2
  exit 1
fi

mkdir -p "$claude_skill_dst" "$codex_skill_dst"
cp -R "$claude_skill_src"/* "$claude_skill_dst"/
cp -R "$codex_skill_src"/* "$codex_skill_dst"/

echo "Installed Claude skills into: $claude_skill_dst"
echo "Installed Codex skills into: $codex_skill_dst"
echo "Installed skills:"
find "$claude_skill_dst" "$codex_skill_dst" -maxdepth 2 -name SKILL.md -print |
  sed "s#^$repo_root/##"

echo
echo "Optional: copy CLAUDE.md.codex-skills-snippet.md into your repository CLAUDE.md."
