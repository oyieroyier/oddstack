# Claude Frontend Implementation Handoff

Fill every bracketed field or delete it when it does not apply. Save the completed prompt under `/tmp`, not in the repository.

````markdown
You are Claude Code acting as the frontend implementation owner in this repository. Implement the bounded frontend slice below, validate it, and return control to Codex for integration.

## Repository

- Root: [absolute repository path]
- Durable backlog: [repo-relative `plans/agent-handoffs/<task-slug>.md` path]
- Starting HEAD: [commit SHA]
- Backend review base: [commit SHA or other fixed point]
- Codex-authored backend/contract paths: [exact paths]
- Working-tree state: [clean, or exact pre-existing in-scope changed paths]

Read the durable backlog first. It is the source of truth for task ownership, queues, checkpoints,
blockers, evidence, and the next owner. Update it before editing and before every yield. This
temporary prompt does not replace it.

## Ownership boundary

- You own: `apps/web/` implementation, frontend tests named below, and the durable backlog.
- Codex owns: `apps/api/`, SQL, migrations, backend services, and shared backend contracts.
- Adversarially review the Codex-authored backend/contract diff against the stated contract before implementing dependent frontend work.
- Do not edit backend-owned files. Return findings with severity, file/symbol evidence, impact, and a concrete suggested fix for Codex to adjudicate.
- If a backend finding invalidates the contract, stop the dependent frontend slice and report the blocker.
- Escalate money/security MUST-FIX findings to the operator; never silently accept or downgrade them.
- Do not commit, push, merge, reset, stash, switch branches, add dependencies, or format unrelated files.
- Never mark the delegation complete while a Codex, Claude, or operator backlog item remains open.

## Required skill and repository guidance

Invoke the project-local `ui-nitpicker` skill for this implementation. Read `AGENTS.md`, `apps/web/DESIGN_SYSTEM.md`, and only the extra UI guidance that `AGENTS.md` requires for the touched surface. Follow the TanStack shell, design-system primitive, navigation, file-budget, and visual-audit rules.

## User outcome

[State the exact user-visible behavior and why it matters.]

## Backend contract already implemented by Codex

- Endpoint/method: [value]
- Auth and scope: [value]
- Request: [fields, validation, example]
- Success response: [exact shape, optional/null behavior, ordering]
- Errors: [status, code, user-readable message behavior]
- Shared contract/schema: [path and exported symbols]
- Fixtures or runtime assumptions: [value]
- Backend checks already run: [commands and outcomes]

Do not invent or broaden this contract. If the frontend cannot consume it safely, stop that part and report the mismatch.

Add each backend mismatch to the backlog's Codex return queue with evidence and acceptance criteria.
If `codex-implementation` is available and the backend work is authorized, invoke it with the
backlog path and exact return-task ids. Review the returned backend diff before resuming dependent
frontend work. Otherwise set the backlog's next owner to Codex and leave an exact resume prompt.

## Frontend scope

- Route/surface: [route]
- Likely files: [paths]
- Required states: [loading, empty, error, success, disabled, pending, etc.]
- Responsive behavior: [requirements]
- Accessibility: [keyboard, labels, focus, announcements]
- Copy constraints: [terms and prohibited wording]
- Analytics/telemetry: [events, or explicitly none]
- Tests: [required coverage]

## Non-goals

- [behavior/file/refactor that must stay out of scope]

## Acceptance criteria

1. [observable result]
2. [observable result]
3. [test or accessibility result]

## Verification

Run the narrowest relevant checks, then:

```bash
[targeted frontend test/typecheck command]
pnpm --filter @hob/web ds:check
pnpm audit:pages
```

If `audit:pages` reports stale approvals, demote only the affected routes with the command prescribed by `AGENTS.md`; never approve a page. If a command fails, capture the exact failure and distinguish a task regression from a pre-existing baseline.

## Required final response

Return:

1. Backend review verdict and evidence-backed findings, including whether the frontend contract is safe to consume.
2. Summary of frontend behavior implemented.
3. Files changed and why.
4. Commands run with pass/fail/baseline outcomes.
5. Remaining visual review, operator escalation, or risk.
6. Durable backlog status, next owner, and every open task id.
````
