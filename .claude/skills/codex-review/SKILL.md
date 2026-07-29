---
name: codex-review
description: Run a deliberately adversarial Codex review of code, diffs, plans, or implementations. Use before committing, opening a PR, accepting a Codex-generated patch, or whenever the user asks for a strict review, audit, second opinion, bug hunt, or risk assessment. Defaults to read-only and must prioritize finding correctness, security, reliability, and maintainability defects over reassurance.
---

# Codex Review

## Purpose

Use this skill to get an independent Codex review that is adversarial by default. The reviewer's job is to try to break the change, not to validate the author's intent. A clean review must be earned through concrete inspection, not granted because the diff looks plausible.

This skill may use `codex review` when the installed Codex CLI exposes an appropriate review command. When command syntax is uncertain or the target review needs custom instructions, use `codex exec -s read-only` with the adversarial prompt templates in this skill.

## Non-negotiable review stance

Treat every proposed change as guilty until proven safe.

- Assume there is at least one meaningful flaw and search for it.
- Prefer concrete failure modes over general style feedback.
- Do not praise the implementation before findings.
- Do not say "LGTM" unless you can also say what you checked and what remains unchecked.
- Do not accept tests at face value; check whether they would fail on the old behavior.
- Do not ignore small-looking diffs; small changes can break contracts, migrations, permissions, cache keys, retries, and edge cases.
- Do not let Codex fix issues during a review run unless the user explicitly requested review-and-fix. Review is read-only by default.

## When to use

Use this skill for:

- Reviewing uncommitted changes.
- Reviewing staged changes before commit.
- Reviewing a branch against a base branch.
- Reviewing a single commit or PR patch.
- Reviewing a Codex-generated implementation before Claude accepts it.
- Reviewing a proposed plan for hidden risks before implementation.
- Security, reliability, migration, API, or concurrency audits.

Do not use this skill for simple copy edits or when there is no code, design, plan, diff, or behavior to examine.

## Review targets

Choose the target explicitly:

1. Uncommitted working tree: staged, unstaged, and untracked files.
2. Staged-only diff: what would be committed now.
3. Branch diff: `merge-base(base, HEAD)..HEAD`.
4. Commit diff: a specific SHA or range.
5. Plan review: no code changes yet; review a written plan for likely failure modes.
6. Full area audit: no diff; inspect a subsystem for likely bugs.

If the user did not specify, default to uncommitted working tree when changes exist; otherwise review the current branch against its upstream or `main`/`master` if obvious.

## Standard workflow

### 1. Preflight

```bash
git status --short
git diff --stat
git diff --name-only
git branch --show-current
git remote -v | sed -n '1,4p'
rg -n "[review-target symbol or term]" [likely paths]
```

Identify applicable project guidance:

```bash
rg --files -g 'CLAUDE.md' -g 'AGENTS.md' -g 'README.md' | sed -n '1,50p'
```

Use the diff and targeted search to bound the review. Read only the guidance relevant to the touched paths and domain before composing the review prompt.

### 2. Prefer verified command syntax

If you intend to use `codex review`, first inspect local help because Codex CLI versions may differ:

```bash
codex review --help || true
codex exec --help | sed -n '1,180p'
```

Use `codex review` only if the help output confirms the command supports the needed target and custom instructions. Otherwise use the `codex exec -s read-only` fallback below.

### 3. Fallback: adversarial review via read-only exec

For a custom review, pipe a complete prompt into Codex:

```bash
cat <<'PROMPT' | codex exec -s read-only --cd "$PWD" -
[write an adversarial review prompt]
PROMPT
```

If reviewing uncommitted changes, include this instruction in the prompt:

```markdown
Review the current working tree, including staged, unstaged, and untracked files. Use git commands to inspect the diff and relevant surrounding code. Do not modify files.
```

If reviewing staged changes only, use the read-only exec fallback rather than `codex review --uncommitted`, and include:

```markdown
Review only the staged changes shown by `git diff --cached`. Exclude unstaged and untracked changes from the review target, though you may inspect unchanged surrounding code for context. Do not modify files.
```

If reviewing a branch, include:

```markdown
Review the diff from merge-base with [BASE] to HEAD. Inspect surrounding code and tests, not just the patch. Do not modify files.
```

### 4. Require adversarial output format

Codex must return findings in this format:

```markdown
## Verdict

BLOCK | CAUTION | PASS

## Findings

### P0/P1/P2/P3: [short title]

- Evidence: `path:line` or command/diff reference
- Failure mode: [what breaks, leaks, corrupts, regresses, or becomes ambiguous]
- Trigger/reproduction: [specific input, state, request, race, migration path, browser size, etc.]
- Why existing tests miss it: [or say covered by X]
- Recommended fix: [minimal fix direction]

## Checks performed

- [commands, files, call sites, tests, schemas, docs inspected]

## Coverage gaps

- [what was not reviewed and why]
```

Severity rubric is in `references/severity-rubric.md`.

### 5. Claude adjudication

After Codex returns findings:

- Verify each finding against the diff and code.
- Reject false positives explicitly and explain why.
- Do not suppress valid findings because they are inconvenient.
- If a finding is plausible but unconfirmed, classify it as a risk with the missing evidence.
- Decide whether to fix directly, ask Codex for a narrow fix, or report to the user.

## Adversarial checklist

Codex must actively look for these classes of defects when relevant:

### Correctness

- Off-by-one, null/undefined, empty collection, duplicate, malformed, very large, and unexpected enum inputs.
- Changed default behavior.
- Incorrect fallback paths.
- Partial failure handling.
- Silent data loss or swallowed errors.
- Tests that assert implementation details instead of behavior.

### Integration contracts

- Public API breaks.
- Route, query parameter, event, or CLI flag changes.
- Serialization/deserialization incompatibility.
- Database schema or migration order issues.
- Cache key or invalidation changes.
- Backward/forward compatibility with existing data.

### Security and privacy

- Authentication versus authorization mistakes.
- Tenant isolation failures.
- Injection, path traversal, unsafe shell execution, unsafe deserialization, SSRF-like fetch behavior, and template injection.
- Sensitive data in logs, errors, telemetry, URLs, or generated files.
- Permission widening.
- Trusting client-provided identifiers, roles, prices, flags, paths, or ownership claims.

### Reliability and concurrency

- Races, retries, idempotency, duplicate submissions, locking, transaction boundaries, stale reads, and timeouts.
- Incomplete rollback on failure.
- Non-deterministic tests.
- Environment-specific assumptions.
- Resource leaks and unbounded memory/CPU use.

### Frontend and UX

- Broken loading, empty, error, disabled, mobile, keyboard, screen-reader, and high-latency states.
- Focus traps, inaccessible labels, lost form state, and hydration mismatches.
- Visual regressions hidden by happy-path screenshots.

### Maintainability

- Broad rewrites where a narrow fix was requested.
- Duplicate logic.
- Dead code.
- Comments that disagree with code.
- New dependencies without clear necessity.
- Overly permissive types or casts that hide errors.

## Review prompt templates

Use:

- `references/review-prompt-template.md`
- `references/adversarial-review-guide.md`
- `references/severity-rubric.md`

## Final response to the user

Report the review result as Claude, not as a raw Codex transcript:

- Verdict: Block, Caution, or Pass.
- Confirmed findings with severity.
- Findings rejected as false positives, if any.
- Checks run.
- Coverage gaps.
- Recommended next step.

A pass is acceptable only when you can state the evidence behind it and the limits of the review.
