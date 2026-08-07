# Model deliberation: cross-reviewer routing and rate-limit behavior in review-hooks

Status: CONVERGED
Next owner: None (execution of the spike plan is ordinary work, not deliberation)
Decision owner: Operator (Bob Oyier)
Artifact owner: Codex (spike plan, per `deliberation.architectureAuthor=codex`); Claude owns this
record
Artifact paths:
- plans/model-deliberations/cross-reviewer-routing-and-rate-limits.md (record)
- plans/codex-backend-spike-plan.md (Codex-authored, round 2, saved verbatim)

## Task

- Question: Should the review gate route by commit provenance (Codex-authored code reviewed by
  Claude and vice versa, with the other model as a rate-limit fallback)? And what does the gate
  actually do today when Claude is rate limited — before a review and mid-review?
- Desired outcome: Confirmed factual baseline of current behavior; adjudicated position on whether
  provenance-based cross-review routing and reviewer fallback are worth designing, and what a
  mid-review rate-limit actually produces.
- Non-goals: Implementing a Codex backend now; changing hook behavior in this deliberation;
  re-opening settled items in AUDIT-BACKLOG.md "Deliberate decisions".
- Governing repository guidance: AUDIT-BACKLOG.md "Direction options" (option 1: Codex reviewer
  backend; option 2: claude-review mirror skill); review-hooks/README.md.
- Relevant source paths:
  - review-hooks/review_gate/policy.py (backend validation, retry policy)
  - review-hooks/review_gate/adapter.py (ClaudeAdapter, failure classification, "no fallback"
    contract)
  - review-hooks/review_gate/core.py (decision flow, skip semantics, incremental state binding)
  - review-hooks/review_gate/supervisor.py (attempt containment)
  - review-hooks/hooks/pre-push, review-hooks/scripts/run-pre-push-gate.sh

## Configuration

- Codex requested model/effort: gpt-5.6-sol / high (from ~/.config/codex-claude-skills/preferences.json)
- Claude requested model/effort: n/a (initiator session; `claude.*` prefs do not apply)
- Initiator actual model: Fable 5 (set via /model for this session)
- Session policy: resume-within-task
- Maximum rounds: 2
- Codex session id: 019fdcc3-ef63-7112-872f-a4bbb51473bb
- Claude session id: this session
- Calls completed: 2 (round limit reached: round 1 grounded position, round 2 artifact authorship)

## Initial position

Grounded in source, four factual findings and one design position.

**F1 — All reviews are performed by Claude, including Claude-authored code. CONFIRMED.**
`policy.py:133-135`: `AI_REVIEW_BACKEND` accepts exactly one value, `"claude"`; anything else is a
`PolicyError` (exit 2). `adapter.py:1-6` states the contract: "No fallback to another model or
provider is automatic." There is no Codex adapter anywhere in `review_gate/`. Nothing in the flow
inspects commit authorship or the generating tool — provenance is invisible to the gate. So
"Claude reviews Claude's own code" is the only possible configuration today. The gap is already
recorded as Direction option 1 in `AUDIT-BACKLOG.md:252-257`, with three named spikes (codex
budget cap, cost reporting, daemonization).

**F2 — Reviews are NOT silently skipped when Claude is rate limited. The push blocks.**
The operator's belief is inverted. A rate-limited/failed reviewer attempt is classified by
`adapter.classify_failure` (`adapter.py:122-150`); a rate-limit error surfaces as
`unknown_infrastructure` (or `invalid_result` if the CLI still emits a non-result envelope) —
never retryable, never a pass. `core.py:699-703` then returns `EXIT_INCONCLUSIVE` (2), the
pre-push hook exits nonzero, and git aborts the push. Protocol echo: "Never convert an
unavailable reviewer into a pass." A skip requires the operator to explicitly set
`SKIP_AI_REVIEW=<commit-sha-prefix>` plus `AI_REVIEW_HUMAN_ACK` (`core.py:376-425`), and it is
evidence-recorded as `SKIPPED/unreviewed`.

**F3 — A mid-review rate limit (or budget exhaustion) kills the run; nothing resumes it.**
Attempts are one-shot: `--tools "" --max-turns 1 --max-budget-usd <cap>` (`adapter.py:29-44`).
There is no partial-progress artifact; a failed attempt yields a failure classification and an
INCONCLUSIVE exit. The only retry path is `startup_transport` (fast startup failure with zero
stdout, documented exit code, within `min_retry_time`), and only if the profile opts in with
`AI_REVIEW_MAX_ATTEMPTS=2` + `AI_REVIEW_RETRYABLE_FAILURES` (`policy.py:157-179`). A mid-stream
token/budget death does not qualify. Re-running re-reviews the whole range and re-pays.

**F4 — Even with a Codex backend, Codex could not "resume" Claude's partial or prior review.
This is deliberate.** Incremental coverage binds to `reviewer_identity`
(`core.py:530-546`): "a new reviewer never inherits an old one's coverage of earlier commits."
A reviewer switch forces a full-range re-review, and the decision cache keys on identity too
(`core.py:200-207`), so a Codex fallback would never satisfy a cache entry Claude created.
"Resume mid-review" is not a state the system can represent — the smallest unit is one complete
attempt.

**P1 — Design position (hypothesis for Codex to attack):** Provenance-based cross-review
("Codex wrote it, so Claude reviews it, and vice versa") is attractive but the weaker half of the
idea, because (a) commit provenance is not reliably recorded (trailers/Co-Authored-By are
convention, not enforced, and a mixed branch has mixed provenance per hunk), and (b) the
self-review concern is about model blind spots, which cross-review only probabilistically
addresses. The stronger, cheaper sequencing is the one AUDIT-BACKLOG option 1 already frames:
build the Codex *backend* first (adapter seam exists), which enables (1) explicit
operator-chosen reviewer diversity, and (2) a *fallback-on-capacity* policy — but fallback must
be an explicit profile opt-in (e.g. `AI_REVIEW_FALLBACK_BACKEND`) that creates a fresh
full-range review under the new identity, never a silent substitution (protocol: "never silently
substitute a model"), and never a resume. Provenance routing, if wanted later, becomes a small
policy layer on top (route by commit trailer at push time), and should degrade to "any available
reviewer that is not the author-majority tool" rather than hard-failing.

Known unknowns (the option-1 spikes, still unresolved): does `codex exec` expose a per-run budget
cap; does it report actual cost (SpendLedger depends on it); does it daemonize (process-group
containment must be re-proven).

## Peer position (Codex, gpt-5.6-sol/high, session 019fdcc3-ef63-7112-872f-a4bbb51473bb)

- Conclusion: Current behavior is fail-closed and single-backend, but Claude's position overstates
  (a) the precision of rate-limit classification and (b) the simplicity of adding
  fallback/provenance routing. Disposition: NEEDS_EXPERIMENT for a Codex backend/fallback; do not
  build provenance routing as a default feature.
- Evidence inspected: policy.py, adapter.py, core.py, supervisor.py, evidence.py, store.py,
  tests/test_gate_flow.py, README.md, AUDIT-BACKLOG.md, `git log --all` trailer census, installed
  codex-cli 0.146.0 flags, OpenAI Codex CLI docs, Anthropic Agent SDK changelog, Claude Code
  issue #57096.
- Accepted claims: F1 (with a nuance: the normal pre-push path is `verify` mode and never
  launches a reviewer at all — only preflight/`run-if-missing` pays; core.py:94,221); F2's
  fail-closed outcome; F3's gate-level statement; F4's operational result; P1's sequencing
  (spike, then backend, then explicit fallback), partly.
- Rejected/qualified claims:
  - F2 qualified: `classify_failure` never *recognizes* rate limits — an observed hard-429
    (nonzero exit) lands in `unknown_infrastructure`, fail-closed. But `parse_envelope`
    (adapter.py:53-76) ignores `is_error`/`subtype`/`api_error_status`: a zero-exit error
    envelope whose `result` string still parses as a valid review could be cached as a pass.
    "No error envelope can ever become a pass" is false at the code-contract level.
  - F3 qualified: `--max-turns 1` bounds agentic turns, not HTTP attempts — the Claude CLI
    retries transient API errors internally (`api_retry`), so a transient 429 can recover inside
    the one supervised attempt. Accurate statement: if Claude's own retries terminate in an
    error, the gate neither retries nor resumes, except configured startup_transport. Also
    "no partial state" should be "no *trusted resumable coverage* state" — bounded raw
    stdout/stderr evidence survives.
  - F4 qualified: identity binding governs completed cache/coverage; it is not what prevents
    mid-attempt resume (failed attempts never reach cache/state writes; core.py:756).
    "Impossible in principle" is too broad; "never trustworthy, so fresh full-range review is
    the correct design" is right.
  - P1 qualified: provenance routing is NOT necessarily a thin layer. The gate reviews one
    aggregate base..head diff with one reviewer identity, one cache key, one branch-state file.
    True per-commit cross-review needs commit partitioning, multiple identities/cache entries,
    per-reviewer state, and verify-mode lookup across allowable reviewers. A majority-author
    heuristic could be thin but would not deliver the operator's stated guarantee.
- Missing risks or alternatives:
  - Provenance is partially recoverable: 19/44 commits carry Claude `Co-Authored-By` trailers,
    zero carry Codex trailers; trailers prove participation, not hunk ownership. Prospective
    enforcement via the existing commit-msg surface (`AI-Assisted-By:` trailer) is possible as a
    routing hint, never a security boundary.
  - Self-review risk is unmeasured in this repository — reviewer diversity is plausible, not
    demonstrated.
  - Fallback and cross-review are *conflicting* policies: falling back to the authoring model
    restores capacity by violating independence. Needs distinct modes: `availability` vs
    `cross-review-required`.
  - Fallback must trigger only on structural, adapter-authenticated capacity signals — never on
    generic invalid output (else prompt injection / malformed output enables reviewer shopping
    and double spend).
  - SpendLedger entries carry no backend/model (store.py:245); `codex exec` reports tokens, not
    USD, and exposes no per-run USD cap — the USD-settled ledger semantics cannot carry over.
  - Separate provider authorization: one personal-quota opt-in must not authorize sending the
    diff to a second provider.
  - Fallback-cache semantics unresolved: should a Codex-fallback pass satisfy a later push after
    Claude recovers?
- Uncertainty: real 429 envelope shape on installed Claude Code (non-stream JSON) unverified;
  codex budget cap absent in codex-cli 0.146.0; codex cost reporting is tokens-only;
  daemonization not disproven (supervisor.py:8 acknowledges setsid escape); Codex tool/MCP/web
  isolation parity with `--tools ""` unproven.
- Recommendation: (1) harden the Claude envelope contract + 429/budget fixtures; (2) complete
  the Codex spikes plus tool-isolation; (3) adapter registry + semantic outcome taxonomy, ship
  explicit operator-selected reviewer first; (4) redesign evidence/cache/ledger/credentials for
  multi-provider; (5) capacity fallback only as explicit policy with fresh full-range review;
  (6) measure same-model vs cross-model review quality before automating provenance decisions.

## Disagreement ledger

| Id | Type | Positions | Evidence | Adjudication | State |
| --- | ---- | --------- | -------- | ------------ | ----- |
| D1 | factual | Claude: rate-limit failure always yields INCONCLUSIVE. Codex: fail-closed for observed shapes, but `parse_envelope` ignores `is_error` — an error envelope with parseable `result` could pass. | adapter.py:53-76 checks only `result` + `total_cost_usd`; core.py:636-656 parses any string result | Accepted (Claude). Practical exploitation needs an error envelope containing a syntactically valid review, but the contract gap is real. Becomes hardening item H1. | CLOSED |
| D2 | factual | Claude: mid-review rate limit kills the run. Codex: the CLI retries transient 429s internally; only *terminal* CLI failure reaches the gate. | Agent SDK changelog (`api_retry`) | Accepted (Claude). Refines F3's wording; gate-level behavior unchanged. | CLOSED |
| D3 | factual nuance | Claude: F4 rests on identity binding. Codex: failed attempts never write state at all; identity binding governs *completed* coverage only. | core.py:756-788 | Accepted (Claude). Rationale corrected; conclusion (fresh full-range review on reviewer switch) stands. | CLOSED |
| D4 | design/tradeoff | Claude: provenance routing could be a thin later layer. Codex: exact per-commit cross-review is a multi-review architecture; only a majority-author heuristic is thin. | README.md:259 (aggregate diff), single cache key/branch state | Accepted (Claude). P1 revised: provenance routing is either a weak heuristic or a large architecture change — reinforces "backend first, routing later if ever". | CLOSED |
| D5 | risk | Codex (new): fallback and cross-review conflict; fallback needs authenticated capacity signals, ledger/credential redesign. | store.py:245; codex docs (no USD cap, token-only reporting) | Accepted (Claude). Folded into the recommended build order as preconditions for any fallback policy. | CLOSED |

## Decision

- Outcome: CONVERGED. Operator decision (2026-08-07): adopt the six-step build order;
  operator-selected reviewer diversity + explicit capacity fallback is enough — provenance
  routing (`cross-review-required` mode) is NOT a goal and is dropped. The `AI-Assisted-By:`
  trailer suggestion is therefore not required (may still be adopted independently for audit
  value, but nothing in the plan depends on it).
- Rationale: Both models agree on current behavior (Claude-only reviewer, fail-closed on rate
  limits, no resume, no silent skip) and on sequencing (envelope hardening → Codex spikes →
  explicit selectable backend → fallback as explicit policy → provenance routing last, if ever).
- Accepted risks: none accepted yet; H1 (envelope error-field validation) is an open hardening
  gap until fixed.
- Preserved dissent: none material.
- Required experiment or operator action:
  - E1: capture real 429 / budget-exhaustion envelopes from the installed Claude CLI
    (non-stream `--output-format json`) and add fixtures; then implement H1 (reject
    `is_error`/error-subtype envelopes in `parse_envelope`).
  - E2: the three AUDIT-BACKLOG option-1 spikes + a fourth: Codex tool/MCP/web isolation parity
    with `--tools ""`.
  - O1: RESOLVED 2026-08-07 — build order adopted; provenance routing dropped;
    operator-selected reviewer diversity + explicit fallback is the end state. Scope for any
    fallback design is `availability` mode only; `cross-review-required` mode is out of scope.

## Round 2 (artifact authorship)

Codex authored `plans/codex-backend-spike-plan.md` (E1 envelope hardening + E2 Codex spikes,
with pass bars and exit criteria for build-order step 3). Saved verbatim.

Claude's adversarial review of the artifact (initiator, inline — round limit reached, so notes
recorded here rather than sent back):

- Verified cites against source read this session: adapter.py:29-44 (argv), adapter.py:53-76
  (parse_envelope), core.py:572-600 (reservation), core.py:627-684 (attempt loop),
  core.py:686-697 (settlement), core.py:699-703 (refuse) — all accurate. Test-file cites
  (gate_test_util.py:66-73, test_gate_flow.py:476-511, run.sh:722-735,
  test_process_supervisor.py:76-107) accepted on Codex's inspection.
- R1 (non-material): the codex-cli flag inventory in E2.4 (`--disable` list, `--ephemeral`,
  `--ignore-user-config`, `--strict-config`, feature keys in E2.1) is specific to codex-cli
  0.146.0 and must be re-validated against the installed version at spike time; the plan
  already requires recording version/help hashes, which covers this.
- R2 (non-material): E1.1 case 2 (real 429 capture) may block on credential availability; the
  plan handles it explicitly ("record E1 as blocked").
- No material objection. Artifact accepted as-is.

## Resume

- Deliberation closed (CONVERGED, round limit reached). No peer resume needed.
- Next action is execution, not deliberation: work `plans/codex-backend-spike-plan.md` starting
  with E1.1 captures. If a *new* material dispute arises during execution, open a fresh
  deliberation and a fresh Codex session; do not resume 019fdcc3-ef63-7112-872f-a4bbb51473bb.
