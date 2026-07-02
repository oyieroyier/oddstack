# Codex Claude Skills

This bundle contains three project-local Claude Code skills:

- `codex-implementation` — delegates implementation and investigation work to Codex CLI with self-contained prompts.
- `codex-review` — performs adversarial, read-only reviews of diffs, plans, branches, commits, and Codex-generated patches.
- `codex-computer-use` — prepares scoped GUI/browser/screenshot/desktop-app QA tasks for Codex Computer Use, Browser use, Chrome, image inputs, or safe local browser automation.

## Directory layout

```text
.claude/skills/
  codex-implementation/
    SKILL.md
    references/
      implementation-prompt-template.md
      validation-and-handoff.md
  codex-review/
    SKILL.md
    references/
      adversarial-review-guide.md
      review-prompt-template.md
      severity-rubric.md
  codex-computer-use/
    SKILL.md
    references/
      browser-ui-checklist.md
      computer-use-prompt-template.md
      safety-state-and-observation.md
CLAUDE.md.codex-skills-snippet.md
install.sh
```

## Install into a project

From the extracted bundle directory:

```bash
./install.sh /path/to/your/repo
```

Or copy manually:

```bash
mkdir -p /path/to/your/repo/.claude/skills
cp -R .claude/skills/* /path/to/your/repo/.claude/skills/
```

Then copy the contents of `CLAUDE.md.codex-skills-snippet.md` into the repo's `CLAUDE.md` if you want the repository instructions to reference these skills explicitly.

## Install globally for your user

```bash
mkdir -p ~/.claude/skills
cp -R .claude/skills/* ~/.claude/skills/
```

Project-local install is usually safer because the behavior is scoped to a repository and can be versioned with the project.

## Verify

```bash
find .claude/skills -maxdepth 2 -name SKILL.md -print
```

Expected:

```text
.claude/skills/codex-implementation/SKILL.md
.claude/skills/codex-review/SKILL.md
.claude/skills/codex-computer-use/SKILL.md
```

Also verify that Codex is available:

```bash
command -v codex
codex --version
codex exec --help | sed -n '1,80p'
```

## Usage examples

Ask Claude Code:

```text
Use codex-implementation to implement the narrowest fix for this bug, then inspect the diff yourself.
```

```text
Use codex-review adversarially on my uncommitted changes. Block on correctness, security, migration, or compatibility issues.
```

```text
Use codex-computer-use to prepare a scoped browser QA pass for the local checkout flow. Do not touch production or billing actions.
```

## Notes

These skills are prompt wrappers around the Codex CLI and Codex app/browser workflows. They do not install Codex, grant Codex permissions, or bypass Codex sandboxing. They are designed to make Claude's delegation prompts explicit, repeatable, and reviewable.
