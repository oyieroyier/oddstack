# CLAUDE.md snippet: Codex collaboration skills

Add this section to the repository's `CLAUDE.md` after any project-specific build/test instructions.

```markdown
## Codex collaboration

This repository includes project-local Claude Code skills under `.claude/skills/` for delegating work to the local Codex CLI.

Use these skills when appropriate:

- `codex-implementation`: delegate implementation, debugging, refactoring, or repository investigation to Codex via a self-contained `codex exec` prompt.
- `codex-review`: run an adversarial read-only review of a diff, plan, branch, commit, or Codex-generated patch. Reviews must prioritize concrete correctness, security, reliability, data, and compatibility issues over reassurance.
- `codex-computer-use`: prepare tightly scoped GUI, browser, screenshot, simulator, desktop-app, or visual QA tasks for Codex Computer Use, Browser use, Chrome, image input, or safe local browser automation.

General rules:

1. Do not guess or invoke skill names that are not installed.
2. If a Codex skill is unavailable, fall back to direct Bash usage of Codex with a self-contained prompt.
3. Use `codex exec -s read-only` for investigation, planning, and review.
4. Use `codex exec -s workspace-write` only when Codex should edit files inside the repository.
5. Do not use `danger-full-access`, `--yolo`, or approval-disabling flags unless the user explicitly requested an isolated runner and the environment is actually isolated.
6. After any Codex implementation, Claude must inspect `git status`, `git diff`, and relevant tests before presenting the result.
7. Before accepting non-trivial changes, run an adversarial review using `codex-review` or the equivalent direct read-only Codex prompt.
```
