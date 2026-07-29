# Architecture & Implementation Plan Template

Mandatory before implementing any non-trivial UI feature (Mode B). The plan is where radical decisions get made and justified — cheaper to move a paradigm on paper than in code. Skip only for genuinely trivial changes (copy edit, token swap, single-prop fix).

Keep the plan dense and skimmable. Every section earns its length; a plan nobody reads protects nobody.
Store the completed plan under `docs/` or `plans/`; chat should summarize and link it rather than becoming the system of record.

```markdown
# [Feature] — Design & Implementation Plan

## 1. The job

One sentence: who uses this and what they accomplish. (Goal, not mechanism — "merchants see which products stall" not "add a table".)

## 2. Paradigm decision

- Presentation chosen (chart/table/sheet/wizard/inline/...) and why the data shape + task demand it.
- Alternatives rejected and the one-line reason each.
- If this restructures existing UI: what moves, what dies, why the disruption pays for itself.

## 3. Journey

- Entry points (where users come from).
- Happy path as numbered steps — each step names what the user SEES and DOES (show-don't-tell applies to plans too).
- Next-action anticipation: what users do after success, and how the design routes them there (preconditions checked, follow-on surfaced).
- Exhaustive states: loading, empty (first-run vs. filtered-to-zero), error, partial data, overflow/long-content, offline if relevant.

## 4. Design-spec compliance

- Spec/token sources consulted (files/paths).
- Tokens, primitives, and patterns this feature consumes.
- Any tension with the spec → resolved in the spec's favor, or escalated to the user BEFORE implementation. Never silently deviated.

## 5. Architecture

- Component tree (indented list), one job per component, server/client boundary marked.
- State table: each piece of state → its rung on the state ladder (URL / local / form / server cache / store) → owner component.
- Data flow: reads (route loader/query keys), writes (actions/mutations), optimistic updates, invalidation.
- File layout: paths for new/changed files. No file gains a second responsibility.

## 6. Implementation order

Numbered steps, each independently verifiable, states-first where possible (skeleton/empty/error scaffolded before happy path). Note per step what "done" looks like.

## 7. Copy inventory

Every user-facing string in the feature, final wording, written here once. (Forces copy economy; prevents lorem-ipsum-then-forget.)

## 8. Self-review gate

Before handoff: run the Mode A sweep (design-review-rubric.md) on the result. List the checks performed and states exercised.
```

## Rules of engagement

- **Whitelist discipline**: implement exactly the features agreed with the user. The plan may _propose_ adjacent improvements (anticipation findings often surface them) — clearly marked as proposals, not silently built.
- **Spec conflicts stop the line**: if the feature as requested violates the design spec, raise it at plan time with options. Do not build a violation, and do not quietly "fix" the request either.
- **The plan is the contract**: deviations discovered mid-implementation (API shape wrong, primitive missing) get a one-line plan amendment in the handoff, not a silent detour.
- **Present the plan, then end cheap**: if the only open item is a choice between enumerated options, end with "1, 2, 3 or 4?" — nothing else.
