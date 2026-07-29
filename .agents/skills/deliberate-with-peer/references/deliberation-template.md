# Deliberation record template

Create `plans/model-deliberations/<task-slug>.md`:

```markdown
# Model deliberation: [decision]

Status: [IN_PROGRESS | CONVERGED | CONVERGED_WITH_DISSENT | NEEDS_EXPERIMENT |
NEEDS_OPERATOR | BLOCKED_CLAUDE_CAPACITY | BLOCKED_CODEX_CAPACITY | BLOCKED_EXECUTION]
Next owner: [Codex | Claude | Operator | None]
Decision owner: [name or role]
Artifact owner: [Codex | Claude]
Artifact paths: [paths or none]

## Task

- Question:
- Desired outcome:
- Non-goals:
- Governing repository guidance:
- Relevant source paths:

## Configuration

- Codex requested model/effort:
- Claude requested model/effort:
- Session policy:
- Maximum rounds:
- Codex session id:
- Claude session id:
- Calls completed:

## Initial position

[Grounded position from the initiating model.]

## Peer position

- Conclusion:
- Evidence inspected:
- Accepted claims:
- Rejected claims:
- Missing risks or alternatives:
- Uncertainty:
- Recommendation:

## Disagreement ledger

| Id  | Type | Positions | Evidence | Adjudication | State |
| --- | ---- | --------- | -------- | ------------ | ----- |

## Decision

- Outcome:
- Rationale:
- Accepted risks:
- Preserved dissent:
- Required experiment or operator action:

## Resume

- Exact next prompt:
- Exact resume command:
```
