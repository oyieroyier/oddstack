# Adversarial Codex Review Prompt Template

Use this with `codex exec -s read-only --cd "$PWD" -` when `codex review` is unavailable, insufficient, or too generic.

````markdown
You are Codex acting as an adversarial code reviewer. Your task is to find concrete defects in the target below. Be skeptical, specific, and evidence-driven. Do not modify files.

## Review target

[Choose one: working tree / staged diff / branch diff / commit SHA / plan / subsystem audit.]

## Context from Claude

- User goal: [what the change is supposed to accomplish]
- Non-goals: [what should not change]
- Project guidance: [summaries from CLAUDE.md, AGENTS.md, README, etc.]
- Risk areas Claude wants extra scrutiny on: [auth, migrations, concurrency, UI, performance, etc.]

## Required review method

1. Inspect the diff or plan.
2. Inspect surrounding code, call sites, tests, schemas, docs, and configuration needed to validate the diff.
3. Assume the implementation has at least one hidden bug; try to find it.
4. Prefer high-impact correctness, security, reliability, data, and compatibility issues over style comments.
5. Do not report a finding unless you can describe a concrete failure mode.
6. Do not modify files.

## Commands to consider

Use appropriate read-only commands, such as:

```bash
git status --short
git diff --stat
git diff --cached --stat
git diff --no-ext-diff --unified=80
git diff --cached --no-ext-diff --unified=80
git log --oneline --decorate -20
rg "[relevant symbol]" .
```

## Output format

Return exactly this structure:

```markdown
## Verdict

BLOCK | CAUTION | PASS

## Findings

### P0/P1/P2/P3: [short title]

- Evidence: `path:line` or exact diff/code reference
- Failure mode: [what breaks, leaks, corrupts, regresses, or becomes ambiguous]
- Trigger/reproduction: [specific input, state, request, race, migration path, browser size, etc.]
- Why existing tests miss it: [or say covered by X]
- Recommended fix: [minimal direction]

If no findings survive scrutiny, write: "No confirmed findings." Do not invent issues.

## Checks performed

- [files, commands, call sites, tests, schemas, docs inspected]

## Coverage gaps

- [what was not reviewed, unavailable commands, large areas skipped]
```

## Severity guide

- P0: catastrophic exploit/data loss/outage; blocks immediately.
- P1: likely serious production bug, security/privacy issue, migration/data integrity issue, or major regression; blocks merge.
- P2: real bug or maintainability risk with bounded blast radius; should fix before or soon after merge depending on urgency.
- P3: minor issue, unclear edge case, or cleanup; not a blocker.
````

## Plan review variant

For a plan rather than a diff, replace the review target with:

```markdown
Review this implementation plan before code is written. Attack the plan for missing steps, risky assumptions, untested edge cases, unclear acceptance criteria, migration hazards, security gaps, and rollout issues. Do not propose a full alternate implementation unless the plan is fundamentally flawed. Return blockers first.

[Paste plan]
```

## Security-heavy variant

Add:

```markdown
Prioritize security and privacy. Explicitly check authorization boundaries, tenant isolation, sensitive data handling, input validation, filesystem/network trust boundaries, logging, error messages, dependency changes, and unsafe dynamic execution. Treat client-provided data as hostile.
```

## UI-heavy variant

Add:

```markdown
Prioritize rendered behavior. Check loading, empty, error, success, mobile, keyboard-only, screen-reader, high-latency, and long-content states. Look for regressions that unit tests may miss.
```
