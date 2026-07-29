# Delegation backlog template

Create one file at `plans/agent-handoffs/<task-slug>.md`. Replace every bracketed value. Keep product
detail in the linked source artifacts; this file owns delegation state.

```markdown
# Delegation backlog: [task title]

Last updated: [ISO timestamp]

Status: [READY_FOR_CODEX | READY_FOR_CLAUDE | IN_PROGRESS_CODEX | IN_PROGRESS_CLAUDE |
BLOCKED_CLAUDE_CAPACITY | BLOCKED_CODEX_CAPACITY | BLOCKED_EXECUTION | NEEDS_OPERATOR |
READY_FOR_INTEGRATION | COMPLETE]

Next owner: [Codex | Claude | Operator | None]

## Source of truth

- User outcome: [one sentence]
- Plan or architecture: [repo paths or issue URLs]
- Starting HEAD: [SHA]
- Task branch or worktree: [value]

## Ownership and working tree

- Codex-owned paths: [exact paths or bounded globs]
- Claude-owned paths: [exact paths or bounded globs]
- Shared backlog path: [this file]
- Pre-existing unrelated changes: [exact paths; never edit, stage, or revert]
- Commit/push authority: [operator unless explicitly granted]

## Contract checkpoint

- Backend review base: [SHA or not ready]
- Endpoint and method: [value or not ready]
- Auth and scope: [value or not ready]
- Request: [value or not ready]
- Success response: [value or not ready]
- Errors: [value or not ready]
- Shared contract paths: [paths or not ready]
- Backend checks: [commands and outcomes or not ready]

## Codex queue

- [ ] `C-001` [bounded backend, contract, integration, or review task]

## Claude queue

- [ ] `UI-001` [bounded frontend or adversarial-review task]

## Codex return queue

None.

When Claude adds an item, use:

- [ ] `C-RET-001` [finding, evidence, required fix, acceptance criteria]

## Operator queue

None.

## Evidence

| Owner   | Task ids | Changed paths | Checks and outcome    |
| ------- | -------- | ------------- | --------------------- |
| [owner] | [ids]    | [paths]       | [commands and result] |

## Blockers and decisions

| Time   | Owner   | Type                  | Evidence | Resolution or next move |
| ------ | ------- | --------------------- | -------- | ----------------------- |
| [time] | [owner] | [blocker or decision] | [fact]   | [action]                |

## Resume instructions

### Claude

Read this file and every source-of-truth link. Work only open Claude queue items whose dependencies
are complete. Update status to `IN_PROGRESS_CLAUDE` before editing. Adversarially review the backend
checkpoint before consuming it.

If backend work is needed, add a `C-RET-*` item with evidence and acceptance criteria. When
`codex-implementation` is installed and the task is authorized, invoke it with this backlog path and
the exact return ids. Review its diff and checks, update the checkpoint and evidence, then resume
unblocked UI tasks. Otherwise set `Next owner: Codex` and leave the exact Codex resume prompt below.

Before yielding, update every task status, evidence row, blocker, `Status`, `Next owner`, and the
transition log. Never mark `COMPLETE` with an open Codex, Claude, or operator item.

### Codex

Read this file and every source-of-truth link. Work only open Codex queue and Codex return queue
items. Update status to `IN_PROGRESS_CODEX` before editing. Preserve Claude-owned and unrelated
paths.

When the backend checkpoint is safe, update it, set `Status: READY_FOR_CLAUDE`, set
`Next owner: Claude`, and run or request `delegate-frontend-to-claude` with this backlog path.
After Claude finishes, inspect its whole diff, adjudicate findings, run combined checks, and update
the backlog.

### Exact next prompt

[One copy-paste prompt for the next owner. It must name this backlog path and the open task ids.]

## Transition log

| Time   | From    | To      | Reason   | Open task ids |
| ------ | ------- | ------- | -------- | ------------- |
| [time] | [owner] | [owner] | [reason] | [ids]         |
```
