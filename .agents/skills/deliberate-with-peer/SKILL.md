---
name: deliberate-with-peer
description: Deliberate on a consequential idea, architecture, implementation plan, or engineering decision with Claude from Codex, reconcile grounded disagreements, and preserve a resumable decision record. Use when the user asks for a second-model opinion, wants Claude and Codex to debate or reach consensus, requests expensive up-front thinking, or needs an architecture or plan authored by Codex and reviewed by Claude.
---

# Deliberate with Peer

Run a bounded Codex–Claude deliberation. Treat Claude as a grounded critic, not an oracle, and keep
Codex responsible for checking Claude's claims against repository evidence.

This session is the initiator and runs at whatever model the Codex CLI is already configured with.
The `codex.*` preference fields never apply here—they configure Codex only when Claude calls it as
a peer; only `claude.*` governs the peer call below. If the current session model is weaker than
the user expects for deliberation-grade work, say so and let the user switch models before
grounding. Record the actual initiator model and effort in the deliberation record.

## Start the record

Read [references/protocol.md](references/protocol.md) and
[references/deliberation-template.md](references/deliberation-template.md). Create or resume:

`plans/model-deliberations/<task-slug>.md`

Use the record as the source of truth. Sessions improve continuity but never replace it.

Before calling Claude:

1. Inspect the smallest relevant repository guidance and source surface.
2. Record the question, decision owner, artifact owner, assumptions, non-goals, evidence, requested
   models and effort, and current Codex position.
3. Mark Claude's task as a grounded critique, alternative, or confirmation—not general agreement.

For architecture and implementation plans, default to Codex as author and final adjudicator when
the user's preferences say so. Write or update the durable Markdown artifact before requesting
Claude review.

## Call Claude

Use [scripts/run-claude-peer.sh](scripts/run-claude-peer.sh):

```bash
.agents/skills/deliberate-with-peer/scripts/run-claude-peer.sh \
  --repo "$PWD" \
  --prompt-file "$prompt_file" \
  --deliberation-file "plans/model-deliberations/<task-slug>.md"
```

The runner loads optional user preferences, starts a fresh named Claude session by default, and
prints its exact session id. For a focused rebuttal or confirmation, resume that id explicitly:

```bash
.agents/skills/deliberate-with-peer/scripts/run-claude-peer.sh \
  --repo "$PWD" \
  --prompt-file "$prompt_file" \
  --deliberation-file "plans/model-deliberations/<task-slug>.md" \
  --resume "<claude-session-id>"
```

Never use an implicit "most recent" session. Start a fresh peer session for an unrelated decision.

## Reconcile

Update the record with Claude's position and classify each material difference:

- factual disagreement → inspect code, docs, or fresh command evidence;
- different assumption → state and select the governing assumption;
- risk disagreement → compare likelihood, impact, reversibility, and detection;
- product or tradeoff disagreement → record the chosen preference and owner;
- missing information → define an experiment or operator question.

Codex adjudicates each finding. Accept, reject, or defer it with evidence. If a material blocker
remains, send one focused rebuttal containing only disputed points and new evidence. Do not restart
the whole task and do not exceed the configured round limit.

Finish as `CONVERGED`, `CONVERGED_WITH_DISSENT`, `NEEDS_EXPERIMENT`, `NEEDS_OPERATOR`, or a capacity
blocker. Consensus means no unadjudicated material objection; it does not require matching tastes.

## Capacity and session failures

On rate limit, authentication, or execution failure:

- preserve both positions and every open disagreement;
- record `BLOCKED_CLAUDE_CAPACITY` or `BLOCKED_EXECUTION`;
- retain the requested model and effort;
- leave the exact resume command and next prompt;
- never silently substitute a model unless the user configured a fallback.

If a saved session cannot resume, start a fresh session from the durable record and note the
substitution.
