# Decisive Integration Review Gate

Status: active

## Problem

The harness has good deterministic checks and a bounded push/PR review, but implementation skills
can currently describe a slice as verified before the complete integrated change has been evaluated
against its source plan. Exploration reports, contract reviews, typechecks, and domain audits are
useful evidence; none is the decisive acceptance review.

Plan 156 exposed the gap:

- read-only exploration happened before implementation;
- focused tests proved the behavior they encoded, not every acceptance criterion;
- the delegated frontend review stopped on capacity;
- an open `C-AUDIT-*` task did not mechanically prevent “backend completed and verified” wording;
- no final evaluator traced every Plan 156 criterion through the complete API, SQL, contracts, web,
  runtime behavior, and migration/seed parity.

## Decision

Add one repository-level `integration-review` skill and make it the final mandatory phase of every
complex implementation flow. It reuses the Standards and Spec axes from `code-review`, adds an
Integration/Runtime axis, and produces a blocking acceptance matrix over the exact current tree.

This is separate from the aggregate push/PR review:

- the integration gate answers **does this task satisfy its plan on this exact tree?**;
- the push/PR gate remains the bounded publication-time defense over the branch range;
- neither substitutes for operator review or manual visual approval.

## Completion states

Complex task artifacts and skill backlogs use these terminal states:

```text
IMPLEMENTING
  -> READY_FOR_INTEGRATION_REVIEW
  -> INTEGRATION_REVIEW_IN_PROGRESS
  -> BLOCKED_FINDINGS | INCONCLUSIVE_REVIEW | READY_FOR_OPERATOR
  -> ACCEPTANCE_COMPLETE (operator-owned integration only)
```

Rules:

1. Implementers, explorers, and delegated domain owners cannot set `READY_FOR_OPERATOR` or
   `ACCEPTANCE_COMPLETE`.
2. A reviewer capacity, execution, scope, or evidence failure is `INCONCLUSIVE_REVIEW`, never pass.
3. Any `UNSATISFIED` or `UNCERTAIN` acceptance row blocks the gate.
4. `READY_FOR_OPERATOR` requires all rows `SATISFIED`, no open model queue, and no unadjudicated
   finding.
5. When the user retains integration/review ownership, the agent stops at `READY_FOR_OPERATOR`.
   Only the operator may accept the handoff as `ACCEPTANCE_COMPLETE`.
6. “Implemented,” “verified,” and “complete” claims must name their scope. A slice may be
   `backend checks passed`; it is not `acceptance complete` before this gate.

## Exact-tree identity

The gate reviews a fixed base plus the complete working tree, including untracked files. Before the
review it writes a tree identity containing:

- base commit;
- `git diff --binary <base>` digest;
- staged diff digest;
- sorted untracked-path list and per-file digests;
- source-plan/contract digests;
- review-policy and prompt-version digests.

The result is valid only while that identity still matches. Any source or artifact change makes the
review stale and returns the task to `READY_FOR_INTEGRATION_REVIEW`.

This closes a current `code-review` limitation: a `base...HEAD` review does not include an
uncommitted integrated tree.

## Required inputs

The skill refuses to run without:

- a fixed base;
- the source plan, PRD, issue, or task contract;
- explicit acceptance criteria and non-goals;
- impacted bounded contexts and ownership;
- expected evaluator evidence for each criterion;
- the full model/backlog queue state;
- deterministic check results or an explicit reason each check is pending.

For a numbered plan, the plan is the default source of truth. Worker summaries are leads, never
acceptance evidence.

## Review axes

### Standards

Reuse the existing `code-review` standards axis: repository guidance, boundaries, file budgets,
design-system rules, and non-mechanical code smells.

### Spec

Read the source artifact before the diff. Trace every requirement and non-goal to the final change,
including required but absent wiring. “A component exists” does not satisfy “the route renders it.”

### Integration and runtime

Review interactions the other axes routinely miss:

- contracts are consumed by every named caller;
- feature flags and default configuration take the intended path;
- counts, pagination, limits, fallbacks, and large-fixture behavior are correct;
- migration, canonical seeds, memory mode, and PostgreSQL mode agree;
- remediation and UI guidance match the actual validation gate;
- browser-visible behavior is mounted, reachable, responsive, and accessible;
- visual-audit state is recorded without automatic approval;
- no open delegated slice is mistaken for integrated behavior.

The reviewer must inspect the final diff and run or request evaluator commands. Static inference is
reported as `UNCERTAIN` when runtime evidence is required.

## Acceptance matrix

The decisive artifact records one row per criterion:

```text
criterion | SATISFIED / UNSATISFIED / UNCERTAIN | file or symbol | verification | risk
```

Rows cannot be aggregated away. One missing row blocks the result. Cross-cutting criteria may have
subrows for API, SQL, memory seed, web consumer, and runtime proof.

Findings use stable IDs and severities. Fixes do not delete findings; they add resolution evidence.
Dismissal requires a source-of-truth citation or operator decision, not implementer preference.

## Independence and routing

- The decisive reviewer must not be the author of the primary implementation slice.
- For a Codex-owned backend plus Claude-owned frontend, the early Claude backend review remains a
  contract checkpoint and the later Codex `C-AUDIT-*` remains a frontend domain audit. After both,
  `integration-review` evaluates the entire tree once.
- When subagents are explicitly authorized, `integration-review` routes bounded Standards and Spec
  evaluators through `route-codex-subagents`; the primary reconciles results but cannot convert an
  uncertain row to satisfied without evidence.
- When a peer model is unavailable, preserve the matrix and return `INCONCLUSIVE_REVIEW`. Do not
  silently substitute the implementation author as the independent reviewer.
- Review fan-out is bounded. Prefer one aggregate peer call plus deterministic evaluator commands;
  use disjoint subreviews only when the source plan exceeds one reviewer budget.

## Finding loop

1. Freeze the review identity.
2. Run deterministic prerequisites.
3. Produce the three-axis review and acceptance matrix.
4. Record findings in the owning backlog as stable fix tasks.
5. Return ownership to the correct implementation domain.
6. Run focused regression checks after fixes.
7. Re-review the changed delta plus every prior open finding.
8. Before `READY_FOR_OPERATOR`, refresh the full tree identity and run a final complete acceptance
   matrix pass.

The loop stops after two repeated infrastructure/capacity failures with the state preserved as
inconclusive.

## Skill wiring

| Skill or flow                 | Required change                                                                                                                                                                                                |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `implement`                   | Replace “done -> code-review -> commit” with “implementation checks -> integration-review -> READY_FOR_OPERATOR.” Never commit merely because focused checks pass.                                             |
| `code-review`                 | Keep it available for Standards/Spec review, but add working-tree/untracked support or let `integration-review` wrap its axes. Its current `base...HEAD` contract is insufficient for uncommitted integration. |
| `delegate-frontend-to-claude` | Keep backend contract review and `C-AUDIT-*`; after all queues close, require `integration-review`. Claude capacity failure leaves `INCONCLUSIVE_REVIEW`, not a partially verified handoff.                    |
| `route-codex-subagents`       | Clarify that explorer/implementer return validation is not final task review. Require a post-integration acceptance matrix before completion claims.                                                           |
| `tdd`                         | Treat tests as evaluator evidence for named criteria, not proof that unnamed criteria are satisfied.                                                                                                           |
| push/PR adversarial review    | Consume the latest integration-review artifact as context, but remain an independent publication gate. Reject a stale tree identity.                                                                           |

The repository implements this as the project-local `.agents/skills/integration-review` wrapper.
It preserves the installed `code-review` Standards/Spec contract without mutating the user's
home-level skill, adds the Integration/Runtime axis and exact-tree support here, and validates the
artifact with `.agents/skills/integration-review/scripts/check-integration-review-readiness.mjs`.

## Mechanical enforcement

The executable readiness check, `.agents/skills/integration-review/scripts/check-integration-review-readiness.mjs`, validates:

- complex/plan-tracked work has a review artifact;
- artifact tree identity matches the current tree or reviewed commit;
- every acceptance row is present and `SATISFIED`;
- no required check, worker queue, finding, or audit task remains open;
- capacity/execution failures are recorded as inconclusive;
- operator-owned work stops at `READY_FOR_OPERATOR`.

The check should be called by the skill runner and publication gate. It does not perform the AI
review; it validates that the review artifact and state machine cannot be bypassed accidentally.

## Plan 156 evaluator examples

The decisive gate would have required evidence such as:

- buyer facets are imported, mounted in desktop and mobile rails, and label chips consume the new
  contract;
- a fixture larger than both page size and candidate cap proves counts remain stable across pages;
- every publish-validation failure has a corresponding all-plan remediation issue, including
  incomplete required variant axes;
- a table-driven comparison proves SQL migration rules and in-memory seed rules agree on
  requirement, selection mode, value policy, custom-value policy, display group, display order, and
  facet order;
- browser evidence proves seller list/detail remediation is reachable before publish;
- flag-off runtime evidence proves the core facet path, rather than only a small happy-path response.

Those rows would have blocked Plan 156 before an integration-ready claim.

## Rollout

1. Create the `integration-review` skill and artifact schema.
2. Add exact-tree fingerprinting and readiness validation.
3. Wire `implement` and `delegate-frontend-to-claude` first; they own the largest completion gap.
4. Wire `route-codex-subagents` and the task-contract evaluator loop.
5. Add the integration artifact to the push/PR prompt and stale-review check.
6. Trial the gate on Plan 156 and one small single-domain change; tune reviewer budget without
   weakening fail-closed semantics.
7. Promote repeated finding classes into deterministic tests or CI contracts.
