---
name: integration-review
description: Run the decisive, root-owned acceptance gate for complex or plan-tracked implementation on an exact working tree. Use after implementation and domain audits, before claiming integrated completion or operator readiness, especially when work spans agents, Codex/Claude ownership, API/SQL/UI wiring, migrations, fallbacks, or runtime outcomes.
---

# Integration Review

Evaluate the aggregate result, not worker-local slices. Preserve the two independent `code-review`
axes—Standards and Spec—then add Integration/Runtime and a fail-closed acceptance matrix. The root
reviewer owns reconciliation and final claims.

Read `.agents/skills/integration-review/references/decisive-integration-review-gate.md` and the source plan or task contract before
reading worker reports. Read
[references/integration-review-artifact-template.json](references/integration-review-artifact-template.json)
before creating the durable artifact.

## Gate inputs

Refuse the gate until all of these are known:

- fixed base and source plan, PRD, issue, or task contract;
- explicit acceptance criteria, non-goals, bounded contexts, and ownership;
- complete model/backlog queues and deterministic-check results;
- exact changed and untracked paths; and
- reviewer identity independent of the primary implementation slice.

For numbered plans, treat the plan as authoritative. Treat worker reports and focused tests as
leads and evaluator evidence, never as acceptance by themselves.

## Freeze the exact tree

Create `plans/agent-reviews/<task-slug>.json` from the artifact template. The artifact and its
delegation backlog may be excluded as mutable review metadata; never exclude implementation,
tests, plans, or contracts.

Generate the fingerprint after implementation and queue reconciliation:

```bash
node .agents/skills/integration-review/scripts/check-integration-review-readiness.mjs fingerprint \
  --base <fixed-sha> \
  --source <plan-or-contract-path> \
  --policy .agents/skills/integration-review/references/decisive-integration-review-gate.md \
  --exclude-metadata plans/agent-reviews/<task-slug>.json \
  --exclude-metadata plans/agent-handoffs/<task-slug>.md
```

Copy the emitted `treeIdentity`, `sourceArtifacts`, and `policyArtifacts` into the artifact. Any
non-metadata tree, source, or policy change invalidates the result and returns the task to
`READY_FOR_INTEGRATION_REVIEW`.

## Review the aggregate outcome

Inspect the complete root agent tree, routing ledger, delegation backlog, final diff, staged diff,
and untracked paths. Reject worker returns that omit a required criterion or descendant
confirmation. Record actual model/role usage, child count, delegated-turn count, ledger state, and
descendant confirmation even when every count is zero or not applicable.

Run the Standards and Spec reviews against the fixed base and complete tree. Preserve their
separate findings. Then review Integration/Runtime, including:

- every named caller consumes the contract and every intended route mounts the behavior;
- flag-off/default configuration follows the intended core path;
- counts, pagination, indexed paths, candidate caps, and fallbacks hold at boundaries;
- migrations, canonical seeds, in-memory behavior, and PostgreSQL behavior remain in parity;
- validation failures map to reachable remediation and end-user outcomes;
- desktop/mobile behavior, loading skeletons, accessibility, and visual-audit state agree; and
- no open or capacity-blocked delegated slice is represented as completed behavior.

Static inference is `UNCERTAIN` when runtime, browser, or operator evidence is required. Never
convert uncertainty to satisfaction from an implementer assertion.

## Build the decisive matrix

Copy every source criterion into the artifact's `expectedCriteria`, then record one unaggregated row
per criterion using exactly:

```text
criterion | SATISFIED / UNSATISFIED / UNCERTAIN | file or symbol | verification | risk
```

Also record inspected and changed paths, commands and outcomes, assumptions, remaining risks,
findings and adjudication, model/role usage, queue state, ledger state, and descendant confirmation.
Keep deterministic checks, AI review, and operator visual/merge approval as distinct evidence.

Any missing, `UNSATISFIED`, or `UNCERTAIN` row blocks readiness. Any open model/work queue,
unadjudicated finding, incomplete required check, absent descendant confirmation, capacity failure,
or stale fingerprint also blocks. Operator-only queue items remain explicit gates at
`READY_FOR_OPERATOR`. Capacity or execution failure produces `INCONCLUSIVE_REVIEW`, never pass.

## Decide and validate

Use only the documented state machine:

```text
IMPLEMENTING -> READY_FOR_INTEGRATION_REVIEW -> INTEGRATION_REVIEW_IN_PROGRESS
-> BLOCKED_FINDINGS | INCONCLUSIVE_REVIEW | READY_FOR_OPERATOR
-> ACCEPTANCE_COMPLETE
```

Only the operator can set `ACCEPTANCE_COMPLETE`. An agent stops at `READY_FOR_OPERATOR`, with manual
visual review and merge approval still explicit operator gates. Never use legacy `COMPLETE`.

Validate before any readiness claim:

```bash
node .agents/skills/integration-review/scripts/check-integration-review-readiness.mjs check \
  --artifact plans/agent-reviews/<task-slug>.json
```

Use `--allow-blocked` only to validate the shape of a preserved blocked or inconclusive artifact;
it does not authorize readiness wording. After fixes, refresh the complete fingerprint and all
matrix rows. Cache or reuse a review only when the exact base/tree/source/policy identity matches.

The publication-time adversarial review remains separate. This gate neither spends operator/model
quota automatically nor replaces deterministic hooks, manual visual review, merge approval, or the
repository's recorded-skip mechanism.
