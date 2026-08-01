---
name: route-codex-subagents
description: Route explicitly requested Codex subagent or parallel-agent work through bounded, cost-aware roles. Use when the user asks Codex to spawn, delegate to, or run subagents; when an applicable AGENTS.md or skill requires internal Codex delegation; or when resuming an existing multi-agent workflow. Keeps Sol as orchestrator and reviewer, sends bounded exploration and implementation to Terra when available, limits fan-out, prevents recursive delegation, and requires acceptance evidence.
---

# Route Codex Subagents

Treat delegation as an execution choice, not a default. Keep the primary thread responsible for
intent, task contracts, integration, and final claims.

## Gate delegation

Delegate only when the user or applicable repository/skill instructions request subagents or
parallel agent work. Use local tools for deterministic searches, formatting, compilation, and tests.
Keep tightly coupled work in the primary thread.

Before spawning:

1. Check active agents.
2. Set `ledger_tool` to this skill's `scripts/subagent_ledger.py` and choose a stable task slug under
   `plans/agent-runs/<task-slug>.json`. For a new workflow, initialize it once:

   ```bash
   python3 "$ledger_tool" --ledger "$ledger_path" init --task-id "$task_id"
   ```

   For a resumed workflow, require the existing path and run `resume`, never `init`:

   ```bash
   python3 "$ledger_tool" --ledger "$ledger_path" resume --task-id "$task_id"
   ```

   If the ledger or trustworthy task identity is unavailable, refuse further delegation and
   continue locally. Never reset, replace, or delete a ledger to regain budget.
3. Start no more than two children initially and keep no more than three children open.
4. Allow at most one follow-up turn per child and four delegated child turns across the task.
5. Prove the tasks are independent. Serialize overlapping write scopes.
6. Read [references/task-packet.md](references/task-packet.md) and give each worker a self-contained
   packet.

The durable ledger enforces three primary-authorized child creations and detects unauthorized
descendants after they become observable. Before every `spawn_agent` call, reserve a spawn; a failed
call remains charged because it may already have consumed work:

```bash
reservation="$(python3 "$ledger_tool" --ledger "$ledger_path" reserve-spawn \
  --role "$role" --model "$model")"
```

After a successful spawn, settle the reservation with the returned canonical agent id. Before every
`followup_task`, reserve a turn with `reserve-turn`. A refused reservation means the primary must
continue locally.

## Route by role

| Role | Model | Effort | Use |
| --- | --- | --- | --- |
| Explorer | `gpt-5.6-terra` | `low` | Read-only code mapping, logs, documentation, test triage |
| Implementer | `gpt-5.6-terra` | `medium` | One bounded write slice from an approved contract |
| Reviewer | Parent Sol or `gpt-5.6-sol` | `medium` | Consequential review, ambiguity, failed-worker adjudication |

Choose context fidelity independently from the worker role. Prefer `fork_turns = "none"` with a
self-contained packet, or a small positive recent-turn count, to avoid copying irrelevant context.
Use a full-history fork when the task genuinely depends on the complete thread.

Apply the explicit Terra model and effort override whenever the active spawn interface permits it.
Some Codex interfaces accept that override with a full-history fork; others require full-history
children to inherit the parent model and accept overrides only for bounded forks. Follow the active
tool contract. If it forbids Terra plus full history, choose explicitly between a bounded Terra
packet and a full-history inherited-model child; never assume the fork alone selected either model.

Use Terra High only for one bounded task that remains difficult after the primary narrows it. Return
ambiguous contracts to the Sol primary instead of asking Terra to infer them. Use a Sol child only
when an independent consequential review materially improves the result; ordinary synthesis stays
in the primary Sol thread.

Use Luna only when the active spawn interface exposes it and the operator explicitly enabled it.
Do not silently substitute Sol when Terra is unavailable. Keep the work local or report the
capacity blocker.

## Constrain every worker

Every spawn prompt must state:

- the worker must not spawn descendants;
- exact read and write scope;
- acceptance criteria and non-goals;
- commands or observations required for verification;
- whether it may edit or is read-only; and
- the required return ledger.

For parallel writers, assign disjoint paths. Ask workers to preserve unrelated changes and stop if
their scope conflicts with another worker.

## Validate returns

Require this ledger row for every criterion:

```text
criterion | SATISFIED / UNSATISFIED / UNCERTAIN | file or symbol | verification | risk
```

Also require changed or inspected paths, commands and outcomes, assumptions, remaining risks, and a
declaration that no descendant was spawned. Treat that declaration as supplemental evidence only.

Before and after every child turn, inspect the complete root agent tree. For every canonical agent
id absent from the ledger, run `observe-agent` with its canonical parent id. This charges unexpected
children and descendants to both cumulative counters. Any descendant marks the ledger `VIOLATED`;
stop further delegation, reject the violating worker's result, and finish locally. If the active
surface cannot expose the complete tree, do not claim the cumulative guarantee and do not continue
delegating.

Reject `COMPLETE` when any criterion is absent, unsatisfied, or uncertain. Inspect the relevant
source and diff and run fresh checks in the primary thread before making completion claims.

## Escalate without multiplying cost

Within the cumulative spawn and delegated-turn budgets, choose one response to a failed or
uncertain return:

1. send one focused follow-up to the same worker;
2. narrow the packet and retry once at the same or one-higher Terra effort;
3. take the work back into the primary thread; or
4. invoke one Sol reviewer for consequential ambiguity.

Do not create multiple speculative replacements. Stop after the same failure mode repeats. Preserve
the concrete blocker and unfinished criteria.

Wait for requested workers, reconcile their evidence, and close or stop unneeded threads. Report
which roles and models ran, total child creations, total delegated turns, whether both budgets and
the concurrency cap held, ledger path and status, any observed descendants, and what the primary
independently verified.
