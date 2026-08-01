# Subagent task packet

Use this packet for each child. Fill every field and remove placeholder text.

```text
Role: [Explorer | Implementer | Reviewer]
Objective: [one bounded outcome]

Why delegation is justified:
- [independence, context isolation, or parallel latency benefit]

Scope:
- Read: [exact paths or bounded globs]
- Write: [exact disjoint paths, or NONE]
- Preserve: [known dirty or unrelated paths]

Inputs:
- [source plan, issue, symbols, commands, or compact facts]

Acceptance criteria:
1. [observable criterion]
2. [observable criterion]

Non-goals:
- [adjacent work not authorized]

Verification:
- [commands or observations]

Constraints:
- Do not spawn subagents.
- Do not expand scope or redesign the contract.
- Stop and return UNCERTAIN if the packet is insufficient.
- Preserve unrelated work.

Return:
- Changed or inspected paths.
- Concise findings or implementation summary.
- Commands run and exact outcomes.
- One row per criterion:
  criterion | SATISFIED / UNSATISFIED / UNCERTAIN | file or symbol | verification | risk
- Assumptions, uncertainty, and remaining risks.
- Confirm that you spawned no descendant agents.
```
