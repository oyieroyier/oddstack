---
name: codex-implementation
description: Delegate repository implementation, debugging, refactoring, test-writing, and investigation work to the local Codex CLI. Use when the user asks Claude Code to have Codex implement or analyze code, when an independent coding agent should produce a patch, or when a complex change benefits from a self-contained Codex execution prompt.
---

# Codex Implementation

## Purpose

Use this skill to turn a user request into a self-contained Codex CLI implementation run, then verify and integrate the result. The skill is a wrapper pattern around direct `codex exec` usage; it does not assume any other custom skills are installed.

You are still responsible for the final outcome. Codex is a collaborating implementation agent, not an authority. Do not blindly trust Codex's summary, tests, or claim that a change is complete.

## When to use

Use this skill when the task is primarily about changing or deeply investigating a codebase, including:

- Implementing a feature or bug fix.
- Refactoring code while preserving behavior.
- Adding or repairing tests.
- Investigating an issue where a repository-aware second pass would help.
- Producing a candidate patch for Claude to inspect and finalize.
- Running a bounded spike where Codex can search, edit, and validate locally.

Do not use this skill for trivial edits that Claude can make directly faster and more safely. Do not use it for tasks where the prompt would need to include secrets, private tokens, credentials, production keys, or data the user has not explicitly allowed to be shared with Codex.

## Operating principles

1. Preserve user intent and project rules.
   - Read relevant `CLAUDE.md`, `AGENTS.md`, README, contribution docs, and nearby code before composing the Codex prompt.
   - Include the user's exact goal, non-goals, constraints, and acceptance criteria.
   - If instructions conflict, explicitly tell Codex which instruction has priority.

2. Start with the least privilege that can complete the task.
   - Use read-only mode for investigation, planning, and risk assessment.
   - Use workspace-write mode only when Codex should edit files.
   - Do not use `danger-full-access`, `--yolo`, or approval-disabling flags unless the user explicitly requires an isolated runner and the environment is actually isolated.

3. Make the Codex prompt self-contained.
   - Assume Codex has no memory of this Claude conversation.
   - State the repository root, task, relevant files, constraints, test commands, and expected final response format.
   - Tell Codex to inspect the repository rather than guessing APIs, schemas, or conventions.

4. Validate independently after Codex returns.
   - Inspect `git status`, `git diff`, and any generated files.
   - Run or at least reason through the relevant tests yourself.
   - Check for unrelated edits, formatter churn, hidden config changes, generated artifacts, and deleted code.
   - Decide what to accept, revise, or discard.

5. Keep the user informed.
   - Before a long Codex run, state the high-level delegation target.
   - After the run, summarize what changed, what was verified, and what remains uncertain.

## Standard workflow

### 1. Preflight

Run these checks before delegating:

```bash
git status --short
pwd
find . -maxdepth 3 \( -name CLAUDE.md -o -name AGENTS.md -o -name README.md \) -not -path '*/node_modules/*' | head -50
```

Read any project guidance that applies to the current directory. If the work touches package management, build tooling, migrations, deployment, authentication, authorization, payments, or data deletion, inspect the relevant docs and guardrails before asking Codex to edit.

### 2. Decide execution mode

Use this routing:

- Investigation only: `codex exec -s read-only`
- Implementation inside the repository: `codex exec -s workspace-write`
- Implementation plus external services or network: do not assume permission; constrain the prompt and use project-approved commands only.
- Destructive, production, credentialed, or cross-repo tasks: do not delegate without an explicit safe boundary.

Prefer piping a prompt via stdin so quoting is stable:

```bash
cat <<'PROMPT' | codex exec -s read-only --cd "$PWD" -
[write the self-contained prompt here]
PROMPT
```

For edit runs:

```bash
cat <<'PROMPT' | codex exec -s workspace-write --cd "$PWD" -
[write the self-contained implementation prompt here]
PROMPT
```

If the local Codex CLI does not support a flag used above, run `codex exec --help` and adapt to the installed version while preserving the same sandbox intent.

### 3. Compose the implementation prompt

Use the templates in:

- `references/implementation-prompt-template.md`
- `references/validation-and-handoff.md`

The prompt must include:

- Role: what Codex is being asked to do.
- Task: the exact user-facing change.
- Context: relevant repository paths and architecture notes discovered by Claude.
- Constraints: what must not change.
- Acceptance criteria: concrete behavior that must be true.
- Verification: specific commands to run, or a reason they cannot be run.
- Output contract: concise summary, files changed, tests run, risks, and follow-up questions.

### 4. Run Codex and capture output

For longer or high-risk runs, capture Codex's final message and logs:

```bash
mkdir -p .codex-runs
run_id="$(date +%Y%m%d-%H%M%S)"
cat > .codex-runs/${run_id}.prompt.md <<'PROMPT'
[write the self-contained implementation prompt here]
PROMPT
codex exec -s workspace-write --cd "$PWD" - < .codex-runs/${run_id}.prompt.md \
  | tee .codex-runs/${run_id}.output.txt
```

If the repository should not keep `.codex-runs/`, place the files under `/tmp` instead. Do not commit run logs unless the user asks and they contain no sensitive data.

### 5. Post-run inspection

Always inspect the result yourself:

```bash
git status --short
git diff --stat
git diff --check
git diff -- . ':(exclude)package-lock.json' ':(exclude)yarn.lock' ':(exclude)pnpm-lock.yaml' | sed -n '1,240p'
```

Then inspect full diffs for every changed file. Pay special attention to:

- Unrelated edits.
- Broad rewrites when a narrow patch was requested.
- Silent behavior changes.
- New dependencies.
- Missing tests.
- API, schema, or migration compatibility.
- Security regressions.
- Generated files and lockfile churn.
- Comments that describe behavior not enforced by code.

### 6. Validate

Run the narrowest useful checks first, then broader checks if they are cheap:

```bash
# Examples only; use project-specific commands.
npm test -- --runInBand
npm run lint
npm run typecheck
pytest -q
cargo test
```

If tests cannot be run, explain why and replace them with static inspection that is as concrete as possible. Do not say verification passed unless a command or direct inspection supports that statement.

### 7. Review loop

For meaningful edits, run an adversarial review before finalizing. Use the project-local `codex-review` skill if it is installed. If it is not installed, fall back to direct read-only Codex review with the same adversarial review prompt pattern.

A good implementation loop is:

1. Claude scopes and writes the implementation prompt.
2. Codex implements in `workspace-write`.
3. Claude inspects the patch.
4. Codex reviews the patch in read-only/adversarial mode.
5. Claude fixes or asks Codex to fix only confirmed issues.
6. Claude gives the user a grounded final summary.

## Prompt quality checklist

Before running Codex, check that the prompt answers:

- What exact user-visible behavior should change?
- Which files or areas are likely relevant?
- What behavior must remain unchanged?
- How should Codex prove the change works?
- What should Codex do if tests fail?
- What should Codex avoid touching?
- What output format will make Claude's review easy?

## Failure handling

If Codex produces a bad patch:

- Do not patch over it blindly.
- Save useful observations, then revert unrelated or harmful changes.
- Narrow the prompt and rerun only if the failure mode is understood.
- If repeated runs fail, switch to direct Claude implementation and mention what Codex could not resolve.

If Codex cannot run:

- Check `command -v codex` and `codex --version`.
- Check whether the repository is trusted by Codex if project config is expected.
- Fall back to direct implementation by Claude when appropriate.
- Do not claim Codex reviewed or implemented anything unless it actually ran.

## Final response to the user

Report:

- What Codex was asked to do.
- What files changed.
- What Claude independently checked.
- Which tests or commands passed or failed.
- Any remaining risks, skipped tests, or follow-ups.

Keep the final response grounded in observed files and command output, not Codex's self-report.
