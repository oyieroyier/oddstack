#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$PWD}"
skill_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.claude/skills"
skill_dst="$repo_root/.claude/skills"

if [[ ! -d "$skill_src" ]]; then
  echo "Could not find bundled skills at: $skill_src" >&2
  exit 1
fi

mkdir -p "$skill_dst"
cp -R "$skill_src"/* "$skill_dst"/

echo "Installed Codex Claude skills into: $skill_dst"
echo "Installed skills:"
find "$skill_dst" -maxdepth 2 -name SKILL.md -print | sed "s#^$repo_root/##"

echo
echo "Optional: copy CLAUDE.md.codex-skills-snippet.md into your repository CLAUDE.md."
