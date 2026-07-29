---
name: delegate-frontend-to-claude
description: Keep backend implementation and integration under Codex ownership while delegating a bounded frontend slice to the local Claude Code CLI through a durable, bidirectional backlog. Use for full-stack work where Codex owns APIs, SQL, migrations, and backend contracts and Claude owns web UI; when a Codex-to-Claude or Claude-to-Codex session must survive token or execution outages; or when the user asks either model to resume a prior delegation.
---

# Delegate Frontend to Claude

Run a resumable two-model loop: Codex establishes and verifies the backend contract, Claude
implements the frontend slice, and Codex inspects and integrates the result. Persist every queue and
ownership transition in one repository-local backlog.

## Durable backlog

Before task implementation, read
[references/delegation-backlog-template.md](references/delegation-backlog-template.md) and create or
resume:

`plans/agent-handoffs/<task-slug>.md`

The backlog is the handoff source of truth. Temporary prompts point to it and do not replace it.
Keep detailed product requirements in their owning plan or architecture; the backlog records links,
model-owned queues, checkpoints, blockers, evidence, and the next owner.

Required rules:

- Record every Codex, Claude, and operator task before delegation.
- Give each task a stable id and checkbox.
- Create a `C-AUDIT-*` task for Codex's post-implementation frontend logic audit unless the user
  explicitly disabled peer audit; record any skip reason.
- Update status, next owner, exact changed paths, checks, and transition log before yielding.
- Let Claude edit `apps/web/`, its tests, and this backlog only.
- Put backend findings in the Codex return queue with evidence and acceptance criteria.
- When Claude can call Codex, invoke `codex-implementation` for authorized backend return tasks,
  then review the result and update the backlog before resuming frontend work.
- When either model cannot run, record `BLOCKED_CLAUDE_CAPACITY`, `BLOCKED_CODEX_CAPACITY`, or
  `BLOCKED_EXECUTION`, preserve its open queue, and leave an exact resume prompt in the backlog.
- Never mark the delegation complete while any model or operator queue contains an open task.

## Preserve ownership

- Keep `apps/api/`, SQL, migrations, and backend contracts under Codex ownership.
- Give Claude direct ownership of `apps/web/` implementation and frontend tests.
- Require Claude to adversarially review the Codex-authored backend and contract diff before accepting the frontend contract.
- Ask Claude to report backend findings for Codex to adjudicate. Do not authorize it to edit backend-owned paths.
- Send confirmed frontend defects back to Claude. Do not silently take over material frontend implementation in Codex.
- Keep the human as the commit, push, and merge gate unless the current request explicitly authorizes those actions.

## 1. Scope the task

Read the repository guidance required by `AGENTS.md`. Start with:

```bash
git status --short
git diff --stat
git diff --name-only
rg -n "<task symbol or route>" <likely paths>
```

Split work that crosses more than the repository's diff or bounded-context limits. Identify:

- backend-owned files and behavior;
- shared contract files that Codex owns;
- frontend-owned files and route surfaces;
- acceptance criteria and non-goals;
- targeted backend, frontend, design-system, and visual-audit checks.

Create or update the durable backlog now. Record the source plan, starting `HEAD`, exact pre-existing
dirty paths, ownership split, queues, and next owner before changing implementation files.

Do not launch Claude over unrelated dirty work. If the tree is dirty, either finish an authorized backend checkpoint first or prove every existing change belongs to this task and use the runner's explicit `--allow-dirty` mode. Never stash, reset, or discard user work to manufacture a clean tree.

## 2. Implement and verify the backend first

Implement the backend and shared-contract slice directly in Codex. Validate request/response shapes, auth, error semantics, persistence, and migrations with targeted tests.

Before delegation, record the exact contract Claude must consume:

- backend review base and exact Codex-authored changed paths;
- endpoint and method;
- auth/permission and tenant/seller scope;
- request fields and validation;
- success payload, nullable/optional fields, and ordering;
- error status/code/message behavior;
- shared type or schema path;
- seed/fixture assumptions;
- backend verification already completed.

Write these facts to the durable backlog. Check off completed Codex tasks and set the next owner to
Claude only when the frontend contract is safe to consume.

Prefer a clean, authorized checkpoint. If committing is not authorized, keep the changes uncommitted and record the starting `HEAD`, status, and changed paths in the handoff.

## 3. Compose the Claude handoff

Read [references/frontend-handoff-template.md](references/frontend-handoff-template.md) and create a
filled prompt in a temporary file outside the repository. Point it to the durable backlog. Claude
does not inherit this Codex conversation.

Require Claude to:

- invoke its project-local `ui-nitpicker` skill for non-trivial UI work;
- adversarially review the Codex backend/contract diff first and return an explicit verdict with evidence;
- stop dependent frontend implementation when a backend finding invalidates the contract;
- escalate money/security MUST-FIX findings to the operator instead of silently accepting them;
- read `AGENTS.md`, `apps/web/DESIGN_SYSTEM.md`, and only the additional UI guidance selected by `AGENTS.md`;
- implement only the named frontend behavior and tests;
- use the TanStack shell, design-system primitives, and project navigation APIs;
- cover loading, empty, error, success, disabled, responsive, keyboard, and dark-mode states when applicable;
- run targeted frontend checks plus `pnpm --filter @hob/web ds:check` and `pnpm audit:pages` after changes under `apps/web/src`;
- avoid commits, pushes, resets, stashes, branch changes, backend edits, dependency additions, and unrelated formatting;
- return a concise changed-files and verification report.

Put sensitive values, credentials, production data, and unrelated diffs outside the prompt.

## 4. Run Claude from Codex

Use the bundled runner so the prompt is evaluated inside Claude Code:

```bash
prompt_file="$(mktemp /tmp/claude-frontend-handoff.XXXXXX.md)"
# Fill the prompt file using the repository-approved editing mechanism.
.agents/skills/delegate-frontend-to-claude/scripts/run-claude-frontend.sh \
  --prompt-file "$prompt_file" \
  --backlog-file "plans/agent-handoffs/<task-slug>.md" \
  --repo "$PWD"
```

The runner requires a non-empty backlog under `plans/agent-handoffs/`, injects its path and update
rules into Claude's prompt, and allows that backlog itself to be dirty. When all other dirty files
are known in-scope task work and no clean checkpoint is authorized, add `--allow-dirty`. The runner
refuses other dirty files by default, verifies the CLI and repository, records before/after status,
and uses Claude's `acceptEdits` permission mode. It does not grant bypass permissions.

Tell the user before starting a potentially long Claude run. If Claude auth, capacity, or execution
fails, report the concrete failure and update the backlog before ending the Codex session. Preserve
Claude's open queue. Do not claim delegation occurred.

## 5. Inspect and integrate

After Claude returns, independently run:

```bash
git status --short
git diff --stat
git diff --check
git ls-files --others --exclude-standard
```

Inspect every frontend diff and untracked file. Confirm that Claude did not modify backend-owned paths, contracts, dependencies, generated files, or unrelated surfaces. Adjudicate every backend finding against the source and tests; money/security MUST-FIX findings require the repository's operator acknowledgement. Treat Claude's final report as a lead, not proof.

Complete the recorded `C-AUDIT-*` task before integration unless it was explicitly skipped. Return
`BLOCK | CAUTION | PASS` and inspect:

- state ownership and data flow;
- backend-contract and serialization usage;
- auth, tenant scope, permissions, and client-trust assumptions;
- loading, empty, error, retry, concurrency, and stale-data behavior;
- accessibility semantics and keyboard behavior;
- rendering cost, request count, bundle impact, and test sensitivity.

This is Codex's independent logic and integration audit of Claude-authored frontend code. Do not
substitute Codex's visual taste for Claude's design review, and never approve a manual page-audit
entry. If the audit is skipped, record who authorized it and why. If capacity or execution prevents
the audit, mark it `INCONCLUSIVE`, keep the task open, and leave an exact resume prompt.

Before claiming the integrated work is fixed, complete, passing, or ready:

1. Name the command or observation that proves that exact claim.
2. Run it fresh against the current tree.
3. Read its relevant output and exit status completely.
4. Compare the evidence with the claim and report any mismatch.
5. Only then make the claim and cite the proving check.

Run the targeted backend and frontend checks together. For any change under `apps/web/src`, enforce the repository's visual-audit rule. Never approve visual-audit entries on the user's behalf.

If a frontend defect remains, add it to Claude's backlog queue before creating a narrow follow-up
prompt. If a confirmed backend finding requires a change, add it to the Codex return queue. Codex
implements and verifies it directly, or Claude invokes `codex-implementation` and then reviews the
result. Update the contract checkpoint before Claude resumes dependent frontend work.

Stop after two failed delegation attempts with the same failure mode. Record the blocker, preserved
queue, next owner, and exact resume prompt instead of looping.

## 6. Report the result

State:

- what Codex implemented and verified on the backend;
- what Claude implemented on the frontend;
- Claude's backend review verdict and Codex's adjudication;
- Codex's frontend logic-audit verdict, findings, adjudication, or explicit skip/inconclusive state;
- whether ownership boundaries were preserved;
- the exact checks run and outcomes;
- remaining risks, baseline failures, or visual review still requiring a human;
- durable backlog path, status, next owner, and open queue ids;
- commit/push/merge status.

Do not say the integrated task is complete unless direct diff inspection and verification support it.
