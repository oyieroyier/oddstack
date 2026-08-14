---
name: collab-config
description: View or change every collaboration-bundle setting - peer models, effort, billing mode, budgets, per-skill overrides, model pricing, and the peer-audit policy. Use when the user asks what model or budget a bundled skill will use, wants to re-point a skill at a different model, needs to price an unknown model for cost reporting, or asks why a repository policy tightened a setting.
---

# Collaboration Config

One file owns every setting: `~/.config/codex-claude-skills/preferences.json`
(start from `preferences.example.json` in the bundle). Skills read resolved
values from it and never name a model, provider, or budget directly, so
changing what a skill uses is a configuration edit, not a code edit.

## Inspect what a skill will actually use

Run [scripts/resolve_config.py](scripts/resolve_config.py):

```bash
resolver=.agents/skills/collab-config/scripts/resolve_config.py
python3 "$resolver" --skill delegate-frontend-to-claude
python3 "$resolver" --skill deliberate-with-peer --provider claude
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

The Claude-side copy of this skill additionally ships a session cost governor
for Claude Code transcripts; Codex sessions have no equivalent transcript
contract, so that script lives only under `.claude/skills/collab-config/`.

## Rules

- Report the resolved value and its source (`skills.<name>`, provider, or
  `repo`) when the user asks why a setting applies.
- Edit `preferences.json` for the operator only when asked; show the diff.
- Never write `.codex-claude-skills.json` into a repository unprompted, and
  never weaken one that exists — surface the loud error instead.
- If the resolver exits with a policy error, quote it verbatim; it names both
  conflicting values by design.
