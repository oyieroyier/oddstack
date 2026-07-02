# Codex Implementation Prompt Template

Copy this template into a heredoc or `.codex-runs/<id>.prompt.md` file. Fill every bracketed section or delete it if it truly does not apply.

```markdown
You are Codex running inside this repository as an implementation agent. Your job is to produce a minimal, correct patch for the task below, then validate it.

## Task
[State the exact user request and desired outcome.]

## Repository root
[Absolute or relative path, usually the current working directory.]

## Relevant context discovered by Claude
- [Project architecture notes.]
- [Relevant files/classes/functions/routes.]
- [Important conventions from CLAUDE.md, AGENTS.md, README, or nearby code.]
- [Known failing behavior, logs, stack traces, or reproduction steps.]

## Hard constraints
- Preserve existing public APIs unless the task explicitly requires changing them.
- Keep the patch minimal and focused on the task.
- Do not make unrelated formatting-only changes.
- Do not add dependencies unless clearly necessary; explain any dependency addition.
- Do not touch secrets, credentials, production config, or generated artifacts unless explicitly required.
- Do not mask errors by swallowing exceptions, weakening tests, or deleting assertions.
- Do not claim completion unless verification supports it.

## Non-goals
- [List features, refactors, files, or behaviors that must remain out of scope.]

## Acceptance criteria
- [Concrete behavior 1.]
- [Concrete behavior 2.]
- [Tests or docs expectation.]

## Suggested approach
[Optional. Give a plan if Claude has one. Codex may choose a better approach, but must explain deviations.]

## Verification commands
Run the most relevant commands available in this repo, such as:

```bash
[command 1]
[command 2]
```

If a command cannot be run, state the exact reason and what inspection replaced it.

## Required final response
Return a concise report with:
1. Summary of the implemented change.
2. Files changed.
3. Verification commands run and their results.
4. Any known risks, skipped tests, or follow-up recommendations.
```
```

## Stronger variants

### Bug reproduction first

Add this when fixing a bug:

```markdown
Before editing, try to reproduce or localize the bug. If a small failing test can be added, add it first and confirm it fails for the expected reason. Then implement the fix and confirm the test passes. Do not keep a test that passes for the wrong reason.
```

### Refactor only

Add this when behavior must not change:

```markdown
This is a behavior-preserving refactor. Do not change external behavior, schemas, public exports, CLI flags, HTTP contracts, accessibility labels, error semantics, or test expectations. If you discover behavior that appears wrong, report it separately instead of changing it.
```

### Test-focused patch

Add this when only tests should change:

```markdown
Change tests only unless you find a confirmed test harness bug. Do not modify production code to make tests pass. If production behavior appears wrong, report it rather than fixing it in this run.
```
