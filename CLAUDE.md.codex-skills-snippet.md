# CLAUDE.md snippet: Codex collaboration skills

Add this section to the repository's `CLAUDE.md` after any project-specific build/test instructions.

```markdown
## Codex collaboration

This repository includes project-local Claude Code skills under `.claude/skills/` for delegating work to the local Codex CLI. Codex can return a bounded frontend slice through `.agents/skills/delegate-frontend-to-claude/` when that skill is installed.

Use these skills when appropriate:

- `codex-implementation`: delegate implementation, debugging, refactoring, or repository investigation to Codex via a self-contained `codex exec` prompt.
- `codex-review`: run an adversarial read-only review of a diff, plan, branch, commit, or Codex-generated patch. Reviews must prioritize concrete correctness, security, reliability, data, and compatibility issues over reassurance.
- `codex-computer-use`: prepare tightly scoped GUI, browser, screenshot, simulator, desktop-app, or visual QA tasks for Codex Computer Use, Browser use, Chrome, image input, or safe local browser automation.
- `ui-nitpicker`: exacting design-engineer review and plan-first implementation of UIs. Use for design critiques of screenshots or frontend code, design-spec enforcement (spec deviations always block), user-journey and next-action review, and authoring architecture + implementation plans before building UI features.

General rules:

1. Do not guess or invoke skill names that are not installed.
2. If a Codex skill is unavailable, fall back to direct Bash usage of Codex with a self-contained prompt.
3. Use `codex exec -s read-only` for investigation, planning, and review.
4. Use `codex exec -s workspace-write` only when Codex should edit files inside the repository.
5. Do not use `danger-full-access`, `--yolo`, or approval-disabling flags unless the user explicitly requested an isolated runner and the environment is actually isolated.
6. After any Codex implementation, Claude must inspect `git status`, `git diff`, and relevant tests before presenting the result.
7. Before accepting non-trivial changes, run an adversarial review using `codex-review` or the equivalent direct read-only Codex prompt.
8. When working from a `plans/agent-handoffs/` backlog, update its queues, evidence, status, next owner, and transition log before yielding. Never mark it complete while any model or operator queue remains open.

If the optional collaboration review hooks are activated:

1. Keep pre-commit checks deterministic; do not add model calls at commit scope.
2. Run one bounded aggregate AI review at pre-push or pull-request scope.
3. Never consume personal model quota implicitly.
4. Treat `INCONCLUSIVE` as an infrastructure or coverage failure, not a clean review.
5. Require a recorded human reason before skipping review or overriding blockers.
6. Do not replace an existing hook system without explicit operator approval.
```
