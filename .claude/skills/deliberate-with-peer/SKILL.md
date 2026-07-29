---
name: deliberate-with-peer
description: Deliberate on a consequential idea, architecture, implementation plan, or engineering decision with Codex from Claude, reconcile grounded disagreements, and preserve a resumable decision record. Use when the user asks for a second-model opinion, wants Claude and Codex to debate or reach consensus, requests expensive up-front thinking, or needs an architecture or plan authored by Codex and reviewed by Claude.
---

# Deliberate with Peer

Run a bounded Claude–Codex deliberation. Treat the current Claude position as a hypothesis and
require Codex to inspect repository evidence before accepting or rejecting it.

## Start the record

Read [references/protocol.md](references/protocol.md) and
[references/deliberation-template.md](references/deliberation-template.md). Create or resume:

`plans/model-deliberations/<task-slug>.md`

Use the record as the source of truth. Sessions improve continuity but never replace it.

Before calling Codex:

1. Inspect the smallest relevant repository guidance and source surface.
2. Record the question, decision owner, artifact owner, assumptions, non-goals, evidence, requested
   models and effort, and current Claude position.
3. Ask Codex for a grounded position, critique, alternative, or adjudication—not general agreement.

For architecture and implementation plans, hand authorship to Codex first when the user's
preferences select Codex as author. Claude then reviews the durable artifact adversarially; Codex
adjudicates and revises it.

## Call Codex

Use [scripts/run-codex-peer.sh](scripts/run-codex-peer.sh):

```bash
.claude/skills/deliberate-with-peer/scripts/run-codex-peer.sh \
  --repo "$PWD" \
  --prompt-file "$prompt_file" \
  --deliberation-file "plans/model-deliberations/<task-slug>.md"
```

The runner loads optional user preferences and prints the exact Codex session id returned by the
CLI. For a focused rebuttal, revision, or confirmation, resume that id explicitly:

```bash
.claude/skills/deliberate-with-peer/scripts/run-codex-peer.sh \
  --repo "$PWD" \
  --prompt-file "$prompt_file" \
  --deliberation-file "plans/model-deliberations/<task-slug>.md" \
  --resume "<codex-session-id>"
```

Never use `--last`. Start a fresh peer session for an unrelated decision.

## Reconcile

Update the record with Codex's position and classify each material difference:

- factual disagreement → inspect code, docs, or fresh command evidence;
- different assumption → state and select the governing assumption;
- risk disagreement → compare likelihood, impact, reversibility, and detection;
- product or tradeoff disagreement → record the chosen preference and owner;
- missing information → define an experiment or operator question.

The artifact owner adjudicates each finding. Accept, reject, or defer it with evidence. If a
material blocker remains, send one focused rebuttal containing only disputed points and new
evidence. Do not restart the task and do not exceed the configured round limit.

Finish as `CONVERGED`, `CONVERGED_WITH_DISSENT`, `NEEDS_EXPERIMENT`, `NEEDS_OPERATOR`, or a capacity
blocker. Consensus means no unadjudicated material objection; it does not require matching tastes.

## Capacity and session failures

On rate limit, authentication, or execution failure:

- preserve both positions and every open disagreement;
- record `BLOCKED_CODEX_CAPACITY` or `BLOCKED_EXECUTION`;
- retain the requested model and effort;
- leave the exact resume command and next prompt;
- never silently substitute a model unless the user configured a fallback.

If a saved session cannot resume, start a fresh session from the durable record and note the
substitution.
