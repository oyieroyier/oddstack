# Peer deliberation protocol

## Roles

- Initiator: owns the active conversation and coordinates the next call.
- Artifact owner: authors and revises the durable architecture, plan, or decision.
- Peer: grounds independently, attacks assumptions, and proposes alternatives.
- Decision owner: accepts the final tradeoff; default is the operator for consequential choices.

The initiator and artifact owner may differ. Architecture and implementation plans may name Codex
as artifact owner even when the request starts in Claude.

## Call sequence

1. Ground the task and record the initial position.
2. Start one fresh, task-specific peer session.
3. Require the peer to return:
   - independent conclusion after grounding;
   - accepted claims;
   - rejected claims with evidence;
   - missing risks or alternatives;
   - uncertainty and unresolved unknowns;
   - recommended decision.
4. Reconcile differences in the durable record.
5. Use at most one focused rebuttal or confirmation in the same peer session.
6. Finish with a convergence, experiment, operator, or blocker state.

Do not ask both models to repeat full essays. The second round contains only disputed points and new
evidence.

## Session policy

Default to `resume-within-task`:

- keep the initiating model in its current thread;
- create one fresh peer session per deliberation;
- resume that exact peer session for the bounded follow-up;
- never use an implicit most-recent session;
- create new sessions for unrelated decisions.

`fresh-each-round` trades continuity for stronger independence. `ephemeral` relies entirely on the
durable record. Record every substitution.

## Convergence

- `CONVERGED`: no material objection remains.
- `CONVERGED_WITH_DISSENT`: the decision owner selected a tradeoff and preserved dissent.
- `NEEDS_EXPERIMENT`: evidence can resolve the remaining disagreement.
- `NEEDS_OPERATOR`: a consequential preference, risk acceptance, or authority decision remains.
- `BLOCKED_CLAUDE_CAPACITY` / `BLOCKED_CODEX_CAPACITY`: preserve state and resume later.
- `BLOCKED_EXECUTION`: tooling, authentication, or environment prevented a grounded pass.

Never convert an unavailable reviewer into a pass.

## Preferences

Runners may read:

`~/.config/codex-claude-skills/preferences.json`

Supported shape:

```json
{
  "claude": {
    "model": "claude-fable-5",
    "effort": "xhigh",
    "maxBudgetUsd": null
  },
  "codex": {
    "model": "gpt-5.6-sol",
    "effort": "high"
  },
  "deliberation": {
    "maxRounds": 2,
    "sessionPolicy": "resume-within-task",
    "architectureAuthor": "codex",
    "architectureReviewer": "claude"
  },
  "peerAudit": {
    "policy": "offer"
  }
}
```

Explicit runner flags override the user file. Missing values preserve the CLI environment's
defaults. Never commit personal spending preferences or credentials to a project.

The model and effort fields configure peer calls only: `codex.*` when Claude initiates and calls
Codex, `claude.*` when Codex initiates and calls Claude. The initiating session keeps its own
environment's current model and effort—no runner can change it. Record the initiator's actual
model instead of assuming a preference applied.

Deliberation is a capability-sensitive workload, so the example pins Claude peer calls at
`xhigh` effort per Anthropic's effort guidance. This preference only affects the peer
runners; other skills keep the CLI environment's default effort.
