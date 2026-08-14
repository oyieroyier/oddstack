---
name: session-handoff
description: Write a resumable handoff and end an expensive session cleanly. Use when the session cost governor recommends a handoff, when the user wants to continue work in a fresh session, when context has drifted far from the current task's files, or when handing the remaining work to the other model or a later session.
---

# Session Handoff

Write the durable state a fresh session needs, then stop. The handoff file is
the same artifact the delegation runner validates —
`plans/agent-handoffs/<task-slug>.md` — so a cost-driven handoff and a
model-to-model handoff are interchangeable, and either model or a future
session can resume from it.

## Write the handoff

1. Reuse the task's existing backlog file under `plans/agent-handoffs/` if one
   exists; never fork a second file for the same task.
2. If the repository ships the delegation backlog template at
   `.agents/skills/delegate-frontend-to-claude/references/delegation-backlog-template.md`,
   follow it. Otherwise cover, at minimum:
   - Status (one of the template's statuses, e.g. `IN_PROGRESS_CLAUDE`,
     `READY_FOR_CODEX`, `NEEDS_OPERATOR`) and the next owner.
   - User outcome in one sentence, plus links to the plan or issue.
   - Starting HEAD, current branch or worktree, and every changed path —
     staged, unstaged, and untracked — with which task each belongs to.
   - Verification evidence: commands run and their actual outcomes, not
     summaries of intent.
   - Open queues and blockers, each with a stable task ID.
   - An exact resume prompt a fresh session can execute verbatim.
3. Convert relative references ("the file from earlier", "that failing test")
   into absolute paths and exact names — the next session has no context.

## End the session cleanly

- Leave the working tree exactly as it stands; never commit, stash, reset, or
  reformat to make the handoff look tidy. Record the mess instead.
- State in the final reply where the handoff lives and what the resume prompt
  is, so the operator can start the next session by pointing at it.
- If any queue still contains open work, the handoff records it as open; a
  handoff never marks a delegation complete.

## When not to hand off

An expensive session that is still on one task is the prompt cache working
correctly — staying is cheaper than rebuilding context. Hand off when the
session is both expensive and drifted (the session governor in
`collab-config` measures this), or when the user asks.
