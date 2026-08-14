---
name: collab-config
description: View or change every collaboration-bundle setting - peer models, effort, billing mode, budgets, per-skill overrides, model pricing, and the peer-audit policy. Use when the user asks what model or budget a bundled skill will use, wants to re-point a skill at a different model, needs to price an unknown model for cost reporting, wants to check session cost, or asks why a repository policy tightened a setting.
---

# Collaboration Config

One file owns every setting: `~/.config/codex-claude-skills/preferences.json`
(start from `preferences.example.json` in the bundle). Skills read resolved
values from it and never name a model, provider, or budget directly, so
changing what a skill uses is a configuration edit, not a code edit.

## Inspect what a skill will actually use

Run [scripts/resolve_config.py](scripts/resolve_config.py):

```bash
resolver=.claude/skills/collab-config/scripts/resolve_config.py
python3 "$resolver" --skill codex-review
python3 "$resolver" --skill deliberate-with-peer --provider codex
python3 "$resolver" --policy peerAudit
python3 "$resolver" --show
```

Resolution walks `skills.<name>` → provider (`claude` / `codex`) and stops. A
field absent at every level stays absent, so an unconfigured model falls
through to whatever the CLI itself defaults to — the bundle never invents one.
An explicit `null` means unset: it falls through to the next level and cannot
dodge a repository cap. Explicit runner flags always outrank the file.

## Change which model does what

`claude` and `codex` set provider defaults; `skills` overrides per skill:

```json
{
  "claude": { "model": "claude-fable-5", "effort": "xhigh" },
  "codex":  { "model": "gpt-5.6-sol", "effort": "high" },
  "skills": {
    "codex-review": { "model": "gpt-5.6-terra", "effort": "medium" }
  }
}
```

No model list is validated anywhere. New models, renamed models, and
provider-specific identifiers all work by putting the string in the config.

## Price a model for cost reporting

The bundle ships no built-in price table — prices change faster than
releases. Cost reporting reads `modelRates` (USD per million tokens); a model
without an entry reports tokens only rather than guessing:

```json
{
  "modelRates": {
    "claude-fable-5": { "input": 5.00, "output": 25.00 }
  }
}
```

Cache pricing defaults to the standard multipliers (read 0.1×, 5m write
1.25×, 1h write 2× of input) and each may be overridden per entry with
`cacheRead`, `cacheWrite5m`, or `cacheWrite1h`. A malformed entry is dropped
with a warning rather than half-applied.

## Repository tightening

A repository may ship `.codex-claude-skills.json` at its root to tighten
policy. Two classes, with opposite winners:

- Spend-authorizing (`claude.maxBudgetUsd`, `codex.maxBudgetUsd`,
  `deliberation.maxRounds`): a repository may lower a value, never raise it.
- Process policy (`peerAudit.policy`): a repository may require stricter than
  the operator's preference (`required` > `offer` > `off`) — or, when the
  operator never set the key, stricter than the documented default — never
  weaker. A repository budget cap — even one equal to the operator's value —
  bounds any per-skill `maxBudgetUsd` override.

Anything else in that file — a model, an effort, a billing mode — is refused
loudly. An attempt to widen a spend control is an error naming both values,
not a silent clamp. Nothing checked into a repository can authorize spending
against a personal account.

## Session cost governor

Long sessions get expensive invisibly: every request re-sends the whole
conversation, so cost rises with roughly the square of session length.
Measure the current session with
[scripts/session_governor.py](scripts/session_governor.py):

```bash
governor=.claude/skills/collab-config/scripts/session_governor.py
python3 "$governor" --transcript ~/.claude/projects/<slug>/<session-id>.jsonl \
  --billing plan
```

It reports turns, cache rebuilds, peak context, cache traffic, cost, the
marginal cost of one more turn, and file drift. It recommends `/session-handoff`
only when the session is both expensive and drifted off the files it started
on — expensive alone is the prompt cache working correctly. Billing is
declared with `--billing plan|api`, never inferred; on a plan the dollar
figure is an inert API-equivalent. `--json` emits the totals machine-readably,
and `--expensive-usd`, `--expensive-cache-read-tokens`, and `--drift-threshold`
tune when the handoff recommendation fires.

To run it automatically after each turn, add a `Stop` hook to Claude Code
settings (it reads the hook payload on stdin, surfaces advice as a
`systemMessage`, and always exits zero, so it can never block a turn):

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command",
      "command": "python3 <path-to>/session_governor.py --hook" }] }]
  }
}
```

## Rules

- Report the resolved value and its source (`skills.<name>`, provider, or
  `repo`) when the user asks why a setting applies.
- Edit `preferences.json` for the operator only when asked; show the diff.
- Never write `.codex-claude-skills.json` into a repository unprompted, and
  never weaken one that exists — surface the loud error instead.
- If the resolver exits with a policy error, quote it verbatim; it names both
  conflicting values by design.
