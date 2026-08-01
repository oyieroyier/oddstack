# Codex subagent routing architecture

Status: Accepted
Date: 2026-08-01
Owner: collaboration harness maintainers

## Decision

Keep the primary Codex thread as the orchestrator and final decision owner. Put all internal
subagent selection behind one role-based delegation policy. Workflows request a role and provide a
bounded task packet; they do not choose a model, reasoning effort, context fork, or number of
workers themselves.

Use GPT-5.6 Sol for orchestration, ambiguous planning, consequential judgment, and final
reconciliation. Use GPT-5.6 Terra for bounded exploration and implementation under an explicit
contract. Do not treat Terra as a cheaper autonomous Sol. Luna remains an opt-in adapter for clear,
repeatable work when the active Codex surface exposes it and the operator has enabled it.

Start with at most two subagents, allow at most three open child threads, and authorize at most three
child creations and four delegated child turns for one user task. Closing a thread does not restore
either cumulative budget. Persist the counters by stable task identity so resumption cannot reset
them. Subagents may not spawn descendants, and the primary reconciles the observed agent tree rather
than trusting that instruction. An unauthorized descendant cannot be prevented by this prompt-level
policy after a child has tool access; detection charges it, invalidates the workflow, and stops
further delegation. A failed worker is escalated through the policy, not multiplied into more
workers.

## Context

Codex spawn interfaces do not all expose the same relationship between context forks and model
overrides. Some allow an explicit child model with full history; others require full-history
children to inherit the primary model and allow overrides only on bounded forks. Full-history forks
also repeat conversation context that a bounded worker may not need. The policy must follow the
active tool contract instead of inferring the model from the context choice.

Early field reports about GPT-5.6 Terra point in two directions that the architecture must preserve:

- Terra Medium and High are often preferred for practical implementation because they finish
  bounded work with less overengineering than Sol.
- Terra can optimize for a green build while missing semantic requirements, especially in broad
  refactors or ambiguous debugging, and may confidently report incomplete work as done.

The architecture therefore routes by role and risk rather than applying one cheaper model to every
child. It also makes acceptance evidence part of the worker contract instead of trusting the
worker's completion summary.

## Goals

The routing policy must:

1. prevent accidental Sol fan-out;
2. keep model economics and model-specific behavior out of individual skills;
3. use bounded context packets for Terra workers;
4. cap initial and total fan-out;
5. prevent recursive delegation;
6. reserve Sol for work that benefits from its ambiguity handling and judgment;
7. require evidence for every assigned acceptance criterion;
8. make escalation explicit and avoid silent model fallback;
9. keep deterministic checks in the primary thread rather than buying an agent call for them; and
10. let operator-specific model availability and spending policy vary without rewriting workflows.

## Non-goals

This decision does not:

- claim that Terra is always cheaper per completed task;
- replace repository tests, linters, or direct diff inspection with a model review;
- require delegation for work the primary thread can complete efficiently;
- authorize parallel writes to overlapping paths;
- make Luna a required dependency;
- infer subscription quota usage from API token prices; or
- allow a model downgrade for security, money movement, destructive operations, or other
  consequential decisions without an explicit policy rule.

## Module and seam

The **delegation policy** is the deep module, implemented by the installable
`route-codex-subagents` skill. Its interface accepts one task packet and returns one execution
decision:

```text
workflow or skill
      │
      │ task packet
      ▼
delegation policy ──> LOCAL
      │
      ├─────────────> TERRA_EXPLORER
      ├─────────────> TERRA_IMPLEMENTER
      └─────────────> SOL_REVIEWER
```

The interface contains only facts the caller already owns:

- objective and deliverable;
- acceptance criteria;
- exact read and write scope;
- risk class;
- whether the work is independent of other pending work;
- relevant repository evidence and a small recent-turn context window; and
- required verification and return format.

The module implementation owns:

- whether delegation is justified;
- role, model, and reasoning effort;
- context fork size;
- initial and total fan-out;
- cumulative delegated turns;
- durable task identity and ledger resumption;
- observed-tree reconciliation and descendant violations;
- write-conflict prevention;
- escalation; and
- completion-ledger validation.

This seam provides locality: a change in model behavior or pricing changes the policy and agent
adapters once, not every skill prompt. It provides leverage because implementation, review,
investigation, and collaboration workflows use the same controls.

## Role adapters

Explicit spawn settings are the primary adapters at the model-execution seam. Optional custom Codex
agents can give the same roles stable project or personal names. The adapters are:

| Role | Model and effort | Scope | Use |
| --- | --- | --- | --- |
| `terra_explorer` | Terra low | Read-only | Search, code-path mapping, logs, documentation, test triage |
| `terra_implementer` | Terra medium | One bounded write scope | Implement an approved plan with explicit acceptance criteria |
| `sol_reviewer` | Sol medium | Read-only | Review consequential diffs, resolve ambiguity, adjudicate a failed worker |

Terra High is an escalation for a bounded implementation that needs deeper reasoning. It is not the
default response to an ambiguous task; ambiguity returns to the Sol orchestrator first. Sol High or
higher requires a consequential task or explicit operator request.

When Luna is available, a repository may add a `luna_operator` adapter for precise extraction,
classification, transformation, and other high-volume tasks. The policy must not silently replace
an unavailable Terra adapter with Sol or an unavailable Luna adapter with Terra.

## Configuration

The safe unnamed-child default is Terra, but named role profiles take precedence:

```toml
[agents]
enabled = true
max_concurrent_threads_per_session = 3
default_subagent_model = "gpt-5.6-terra"
default_subagent_reasoning_effort = "medium"
```

This config is operator-owned. Keep it in `~/.codex/config.toml` for a personal default or in a
trusted repository's `.codex/config.toml` when the repository intentionally standardizes routing.
Do not add personal quota limits or credentials to project configuration.

Example implementer adapter:

```toml
name = "terra_implementer"
description = "Implement one bounded slice from an approved plan and return acceptance evidence."
model = "gpt-5.6-terra"
model_reasoning_effort = "medium"
developer_instructions = """
Work only inside the assigned paths and acceptance criteria.
Do not redesign the plan, expand scope, or spawn subagents.
Return one ledger row per acceptance criterion with status, file or symbol evidence,
verification performed, and remaining risk.
Never report complete while any criterion is unsatisfied or uncertain.
"""
```

Prefer a bounded fork (`fork_turns = "none"` or a small recent-turn count) with a self-contained task
packet. Use a full-history fork when complete thread fidelity is necessary. Select Terra explicitly
whenever the active spawn interface permits it; if that interface requires full-history children to
inherit the parent model, record the tradeoff instead of claiming the fork itself selected Sol or
Terra.

## Routing rules

Apply these rules in order:

1. **Use tools locally.** Search, formatting, compilation, tests, and other deterministic work do
   not justify a child by themselves.
2. **Keep coupled work local.** If the primary must immediately consume every intermediate result,
   delegation adds coordination without useful isolation.
3. **Use one Terra explorer** for noisy, read-heavy investigation that can return a distilled map.
4. **Use one Terra implementer** only after the primary has resolved the contract and bounded the
   write scope.
5. **Use two workers initially** only when their tasks are independent and their write scopes are
   disjoint; otherwise run them sequentially.
6. **Use Sol review** for high-risk diffs, unresolved semantic questions, or a Terra result whose
   ledger contains uncertainty. Ordinary verification stays with the primary Sol thread.
7. **Enforce cumulative budgets.** Allow at most three `spawn_agent` calls and four delegated child
   turns for the user task. Retries, replacements, and reviewers consume the same ledger; closing a
   thread restores nothing. Reserve budget before every call and persist it under
   `plans/agent-runs/<task-slug>.json`.
8. **Resume, never reset.** A resumed workflow must load the same ledger and task identity. Missing
   or untrustworthy history disables further delegation.
9. **Reconcile the tree.** Inspect the complete root agent tree before and after each child turn,
   charge every unseen agent, and mark any descendant spawn as a policy violation.
10. **Escalate, do not fan out.** On failure, the primary narrows the task, raises Terra effort once,
   takes the work locally, or invokes one Sol reviewer within the remaining budget. It does not
   create multiple speculative retries.

## Execution lifecycle

```text
Sol primary resolves intent and contract
        │
        ├─ deterministic/local work ───────────────────────┐
        │                                                  │
        └─ bounded task packet → Terra worker              │
                                  │                        │
                                  ├─ ledger satisfied ─────┤
                                  │                        │
                                  └─ uncertain/failed      │
                                           │               │
                          narrow, retry once, or Sol review│
                                                           ▼
                                  primary inspects diff and runs checks
                                                           │
                                                           ▼
                                               Sol final reconciliation
```

The primary remains responsible for integrating results. A worker's tests and summary are evidence
leads, not proof.

The durable ledger is a versioned JSON record keyed by stable task id. It atomically reserves each
spawn and follow-up before the call, binds successful spawn reservations to canonical agent ids,
and records every agent later discovered in the root tree. Failed calls remain charged. A ledger in
`VIOLATED` state refuses new reservations.

## Worker return contract

Every worker returns:

1. changed or inspected paths;
2. concise findings or implementation summary;
3. commands run and their exact outcome;
4. one acceptance-ledger row per criterion;
5. assumptions and uncertainties;
6. remaining risks; and
7. a declaration that no descendant agent was spawned.

The declaration is not authoritative. The primary reconciles it against the observable root agent
tree and rejects the result if a descendant exists.

Each acceptance-ledger row has:

```text
criterion | SATISFIED / UNSATISFIED / UNCERTAIN | file or symbol | verification | risk
```

The primary rejects `COMPLETE` when a criterion is missing, `UNSATISFIED`, or `UNCERTAIN`. For broad
or consequential changes, it reads the relevant source and diff instead of accepting ledger claims
at face value.

## Failure and fallback

- **Terra unavailable:** keep the work local or report the capacity blocker. Do not silently spawn
  Sol children.
- **Context packet insufficient:** the worker returns `UNCERTAIN`; the primary sends one focused
  follow-up, uses a justified full-history fork within the remaining spawn budget, or takes over.
- **Worker leaves its write scope:** stop integration, inspect all changed files, and return control
  to the primary.
- **Two workers conflict:** stop parallel writes and serialize from the last verified state.
- **Repeated same failure:** stop after one narrowed retry and escalate to the primary or operator.
- **Missing resume ledger:** refuse further delegation and continue locally; never initialize a new
  ledger for the same task.
- **Unexpected descendant:** record it against both cumulative counters, mark the ledger violated,
  reject that worker result, and stop delegation.
- **Agent tree unavailable:** do not claim hard cumulative enforcement and continue locally.
- **Consequential ambiguity:** Sol or the operator decides; Terra does not infer permission.

## Adoption

1. Install the `route-codex-subagents` skill with the collaboration bundle.
2. Put the global thread cap and safe unnamed-child default in operator or trusted-project config
   when configuration ownership is clear.
3. Optionally add named agent adapters under `~/.codex/agents/` or `.codex/agents/`.
4. Change delegation-heavy `AGENTS.md` and skills to request roles, never raw models.
5. Remove instructions that spawn one agent per checklist item or allow recursive delegation.
6. Trial the policy on representative exploration, implementation, and review tasks.
7. Compare completed-task rate, retries, elapsed time, and operator corrections—not only tokens.

## Acceptance rules

The architecture is satisfied only when:

- the ledger refuses a fourth primary-authorized child creation or fifth delegated child turn and
  the configured three-thread concurrency cap remains in force;
- resuming the task cannot reset its counters or replace its durable ledger;
- every observable descendant is charged and moves the ledger to `VIOLATED`;
- role profiles select Terra for exploration and implementation and Sol only for review;
- context forks and model overrides are selected independently according to the active spawn
  contract;
- no worker prompt permits descendant spawning;
- a workflow cannot accept a result with a missing or uncertain criterion;
- overlapping write scopes cannot run in parallel;
- Terra failure does not trigger multiple speculative workers or silent Sol fallback; and
- the primary performs fresh verification before claiming completion.
