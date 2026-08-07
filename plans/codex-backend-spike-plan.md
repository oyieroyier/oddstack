<!--
Author: Codex (gpt-5.6-sol, effort high), session 019fdcc3-ef63-7112-872f-a4bbb51473bb, round 2 of
the deliberation recorded in plans/model-deliberations/cross-reviewer-routing-and-rate-limits.md.
Saved verbatim by the Claude initiator session on 2026-08-07.
-->

# Codex backend spike and Claude envelope hardening plan

## Objective

Complete the two experiments that gate the selectable Codex backend:

1. Harden Claude JSON-envelope handling so error envelopes can never be interpreted as successful reviews.
2. Prove that `codex exec` can satisfy the gate’s budget, accounting, containment, and isolation invariants.

The work preserves fail-closed behavior: an unavailable, malformed, or unbounded reviewer produces `INCONCLUSIVE`, never a pass. These experiments implement the adopted decision in `plans/model-deliberations/cross-reviewer-routing-and-rate-limits.md:172-193`.

## Non-goals

- No provenance routing, commit-trailer routing, or `cross-review-required` mode. Provenance routing is dropped.
- No adapter registry or selectable Codex backend yet.
- No automatic reviewer fallback yet.
- No cross-review resume or transfer of partial coverage.
- No conversion of an unavailable reviewer into a successful decision.
- No production ledger migration during E2; E2 records the required semantics for step 3.
- No uncontrolled quota exhaustion. All paid captures use disposable credentials and an operator-approved aggregate spend ceiling.

## E1 — Claude envelope hardening

### Files

Modify:

- `review-hooks/review_gate/adapter.py`
- `review-hooks/review_gate/core.py`
- `review-hooks/tests/gate_test_util.py`
- `review-hooks/tests/test_gate_flow.py`
- `tests/run.sh`
- `review-hooks/README.md`

Add:

- `review-hooks/tests/fixtures/claude-cli/success.json`
- `review-hooks/tests/fixtures/claude-cli/rate-limited.json`
- `review-hooks/tests/fixtures/claude-cli/budget-exhausted.json`
- `review-hooks/tests/fixtures/claude-cli/partial-result.json`
- `review-hooks/tests/spikes/capture_claude_envelopes.py`

Raw captures remain outside the repository under a mode-`0700` temporary directory. Only sanitized fixtures and hashes are committed.

### E1.1 Capture the installed CLI contract

Use the installed Claude CLI with the same non-stream flags currently constructed by the adapter:

```text
claude \
  --tools "" \
  --max-turns 1 \
  --max-budget-usd <CAP> \
  --output-format json \
  --model <EXPLICIT_MODEL> \
  -p
```

This mirrors `review-hooks/review_gate/adapter.py:29-50`.

For every invocation, capture:

- `claude --version`
- exact redacted argv
- UTC start/end and monotonic duration
- process exit code and terminating signal
- stdout and stderr byte counts
- raw stdout and stderr hashes
- parsed top-level field names and types
- supervisor timeout, overflow, and cleanup fields
- credential scope, without credential identifiers

Capture these cases:

1. **Success baseline:** valid structured review result.
2. **429:** use an already rate-limited disposable test credential or an Anthropic-supported rate-limit test facility. A locally fabricated JSON envelope does not qualify. If neither is available, record E1 as blocked.
3. **Budget exhaustion:** choose a small operator-approved `--max-budget-usd` and a prompt expected to exceed it.
4. **Partial result:** run the real CLI through a controlled transport interruption after the request begins. Record whether non-stream mode emits an error envelope, truncated JSON, partial result text, or no stdout.

Run at most two captures per case. Do not deliberately exhaust a production account.

Sanitize session IDs, request IDs, account data, timestamps, prompt contents, and provider prose. Preserve the actual field names, types, exit code, subtype, `is_error`, status code, result presence, and cost presence.

### E1.2 Define the parser contract

Replace the current tuple-only interpretation in `ClaudeAdapter.parse_envelope`, which presently validates only JSON shape, `result`, and `total_cost_usd` (`review-hooks/review_gate/adapter.py:53-76`), with a structured parse result containing:

- `outcome`
- `result_text`
- `actual_usd`
- `provider_status`
- `subtype`

Allowed semantic outcomes:

| Outcome | Structural evidence | Future availability fallback |
|---|---|---:|
| `completed` | Observed success `type`/`subtype`, `is_error` false, string result | No |
| `rate_limited` | Numeric HTTP 429 or an observed, stable rate-limit discriminator | Candidate |
| `budget_exhausted` | Observed maximum-budget subtype/discriminator | No |
| `authentication_failed` | Numeric 401/403 or stable authenticated discriminator | No |
| `provider_unavailable` | Stable overload/transient-provider discriminator | Candidate |
| `provider_error` | `is_error` true or recognized error subtype not mapped above | No |
| `invalid_envelope` | Invalid JSON, contradictory fields, missing required success fields, or truncated JSON | No |

Rules:

- Check `is_error`, subtype, and provider status before reading `result`.
- Any `is_error: true` or error-subtype envelope is rejected even if it contains a syntactically valid `SAFE` result.
- Only the observed success envelope shape may produce `result_text`.
- Unknown error forms remain `provider_error`; do not infer capacity from stderr prose.
- `total_cost_usd` is retained only when it is numeric, finite, non-boolean, and non-negative.
- A rejected envelope may still provide trustworthy actual cost for settlement.
- The parser must not expose partial error-envelope text to the review-result parser.

### E1.3 Feed semantic outcomes into the gate

Update the attempt loop at `review-hooks/review_gate/core.py:627-684` so that:

- `completed` alone reaches structured review-result parsing.
- All other envelope outcomes terminate the attempt with their semantic reason code.
- Both exit-zero and nonzero error envelopes receive the same semantic classification.
- Existing process-level failures from `classify_failure` remain authoritative when no trustworthy envelope exists (`review-hooks/review_gate/adapter.py:122-150`).
- No new retry behavior is introduced.
- A terminal semantic error follows the existing `result is None` path and exits `INCONCLUSIVE`/2 (`review-hooks/review_gate/core.py:699-703`).
- Cost settlement retains the existing conservative assigned-cap fallback (`review-hooks/review_gate/core.py:686-697`).

### E1.4 Fixtures and tests

Update the success helper at `review-hooks/tests/gate_test_util.py:66-73` to reproduce every success discriminator observed in the real capture.

Add tests proving:

- A successful real fixture remains accepted.
- `is_error: true` plus an embedded valid `SAFE` result exits 2.
- Every observed error subtype exits 2 and creates no cache entry.
- Exit-zero and nonzero 429 envelopes both become `rate_limited`.
- Budget exhaustion becomes `budget_exhausted`, not `rate_limited`.
- Partial/truncated JSON becomes `invalid_envelope`.
- Unknown error subtype becomes `provider_error`.
- Conflicting success/error fields fail closed.
- No error-envelope result reaches the structured-result parser.
- Trustworthy cost on an error envelope settles the reservation.
- Missing or invalid cost leaves the assigned reservation standing.
- Existing invalid-result behavior remains intact (`review-hooks/tests/test_gate_flow.py:476-511`).
- The direct parser assertions in `tests/run.sh:722-735` use the captured success contract and cover H1.

### E1 acceptance criteria

- Real installed-CLI captures exist for success, 429, budget exhaustion, and partial-result behavior, or E1 is explicitly blocked.
- Sanitized fixtures preserve the observed envelope structure and exit behavior.
- Raw captures and credentials are not committed.
- A pre-H1 regression test demonstrates that a valid embedded result in an error envelope would have been accepted.
- After H1, only `completed` envelopes can produce review decisions.
- Every error case exits 2, creates no positive cache entry, and cannot silently pass.
- Semantic reason codes appear in run evidence.
- All `review-hooks` Python tests and `tests/run.sh` pass.

## E2 — Codex backend spikes

### Spike files

Add:

- `review-hooks/tests/spikes/probe_codex_backend.py`
- `review-hooks/tests/spikes/helpers/ordinary_descendant.py`
- `review-hooks/tests/spikes/helpers/setsid_escape.py`
- `review-hooks/tests/fixtures/codex-cli/success.jsonl`
- `review-hooks/tests/fixtures/codex-cli/budget-exhausted.jsonl`
- `review-hooks/tests/fixtures/codex-cli/isolated.jsonl`
- `plans/codex-backend-spike-results.md`

Extend `review-hooks/tests/test_process_supervisor.py` only for reusable containment assertions. Do not add a production Codex adapter during E2.

Record the installed `codex --version`, feature list, help output hashes, model, authentication mode, and exact argv in the results document.

### E2.1 Per-run budget bound

Probe both installed experimental budget mechanisms under `--strict-config`:

```text
--enable rollout_budget
-c 'features.rollout_budget.enabled=true'
-c 'features.rollout_budget.limit_tokens=<N>'
```

```text
--enable token_budget
-c 'features.token_budget.enabled=true'
-c 'features.token_budget.limit_tokens=<N>'
```

Test each accepted configuration with:

- a limit below the prompt size;
- a limit reached during the first response;
- a limit reached between two model turns;
- a normal run below the limit.

Capture JSONL events, request count, terminal event, reported usage, and any overshoot.

**Pass bar**

A mechanism passes only if it provides:

- an enforced per-run numeric limit;
- a machine-readable terminal budget outcome;
- no additional model request after exhaustion;
- a documented or empirically fixed maximum overshoot that can be included in the reservation;
- actual usage or a conservative assigned limit in the same unit.

A warning, reminder, context-compaction threshold, or unbounded overshoot fails.

**Bounding decision**

- Do not convert tokens to USD for enforcement.
- Do not record a fictional `assigned_usd` when no USD cap was enforced.
- If a hard token cap passes, use a future unit-aware ledger with `unit="tokens"`, an assigned token reservation, and actual-token settlement.
- A token-to-USD estimate may appear as advisory evidence only, pinned to provider, model, pricing version, and timestamp.
- If neither an enforceable USD cap nor an enforceable token cap exists, the Codex backend remains blocked. An assigned-cap-only USD entry is not an acceptable substitute.

The current gate reserves an enforced USD cap before launch (`review-hooks/review_gate/core.py:572-600`) and the ledger assumes `assigned_usd`/`actual_usd` (`review-hooks/review_gate/store.py:179-257`); E2 must not weaken that invariant.

### E2.2 Usage and ledger semantics

Run successful, budget-failed, provider-failed, and supervisor-terminated Codex executions with `--json`.

Record whether terminal JSONL includes:

- input tokens;
- cached input tokens;
- output tokens;
- reasoning tokens;
- total tokens;
- provider/model identity;
- actual USD;
- usage on failed or interrupted runs.

Make one of these decisions in `plans/codex-backend-spike-results.md`:

1. **Enforced USD cap plus actual USD:** retain a USD ledger, adding backend/provider/model identity.
2. **Hard token cap plus actual token usage:** migrate to unit-aware reservations and settlements. USD and token windows remain separate.
3. **Hard token cap but missing terminal usage:** settle to the assigned token cap.
4. **No hard cap:** block the backend.

Do not sum unlike units in one rolling window. Future evidence must replace the USD-only attempt fields at `review-hooks/review_gate/evidence.py:45-70` with explicit unit, assigned amount, actual amount, backend, provider, and model fields.

**Pass bar**

- Every launched run has a conservative reservation before launch.
- Every settlement uses the enforced unit.
- Missing actual usage retains the full assigned reservation.
- Concurrent runs cannot independently consume the same remaining allowance.
- No pricing estimate can lower the enforcement charge.
- Ledger migration and backward-reading semantics are fully specified before step 3.

### E2.3 Process-group containment

The current supervisor explicitly cannot contain descendants that call `setsid()` (`review-hooks/review_gate/supervisor.py:1-9`). Re-prove containment with the real Codex CLI.

Run `codex exec` through `run_attempt` under:

- normal completion;
- gate timeout;
- output overflow;
- external interruption;
- an ordinary child that ignores `SIGTERM`;
- startup with tools and MCP disabled.

Observe `/proc` process ancestry, PIDs, PGIDs, SIDs, and survivors. Where available, add bounded tracing of `clone`, `fork`, `vfork`, `execve`, `setpgid`, and `setsid`.

Use two controls:

- `ordinary_descendant.py` remains in the Codex process group and must be reaped.
- `setsid_escape.py` deliberately escapes and validates that the detector reports containment failure. Reap this negative-control PID explicitly after the assertion.

The negative control validates the test; it does not establish that Codex itself daemonizes.

**Pass bar**

- No actual Codex process or normal descendant calls `setsid()` or escapes the supervised group.
- All real descendants are gone within the configured kill grace on every termination path.
- `cleanup_verified` is true for real Codex runs.
- The negative control is detected as a failure.
- No PID survives the test harness.
- Any unobservable descendant, detached Codex process, or survivor fails the spike.

Existing nested-child tests at `review-hooks/tests/test_process_supervisor.py:76-107` remain the baseline.

### E2.4 Tool, MCP, web, and configuration isolation

Probe this base invocation from a fresh empty directory outside the repository:

```text
codex --ask-for-approval never exec \
  --json \
  --output-schema <REVIEW_SCHEMA> \
  --ephemeral \
  --ignore-user-config \
  --ignore-rules \
  --strict-config \
  --sandbox read-only \
  --cd <EMPTY_DIRECTORY> \
  --skip-git-repo-check \
  --color never \
  --model <EXPLICIT_MODEL>
```

Do not pass `--search`, `--profile`, `--add-dir`, or either dangerous bypass flag.

Probe these exact overrides individually and then together:

```text
-c 'web_search="disabled"'
-c 'mcp_servers={}'
--disable apps
--disable auth_elicitation
--disable browser_use
--disable browser_use_external
--disable browser_use_full_cdp_access
--disable code_mode_host
--disable computer_use
--disable hooks
--disable image_generation
--disable in_app_browser
--disable multi_agent
--disable plugin_sharing
--disable plugins
--disable remote_plugin
--disable shell_snapshot
--disable shell_tool
--disable skill_mcp_dependency_install
--disable skill_search
--disable standalone_web_search
--disable tool_call_mcp_elicitation
--disable tool_suggest
--disable unified_exec
--disable web_search_cached
--disable web_search_request
--disable workspace_dependencies
```

Use a disposable `CODEX_HOME` containing sentinel user configuration, MCP entries, hooks, plugins, and instructions while retaining authentication through the supported credential mechanism. Place separate sentinel project instructions and rules outside the selected empty working root.

Run adversarial prompts that explicitly request each capability.

| Surface | Pass bar |
|---|---|
| Shell/code execution | No command, code-cell, patch, or unified-exec capability is advertised or invoked |
| MCP/apps/plugins | No server initialization, tool inventory, elicitation, installation, or tool-call event |
| Web/browser/computer | No web-search, browser, computer-use, image, or unexpected network event |
| Configuration | No sentinel user/project instructions, rules, hooks, profile, or default model affect the run |
| Filesystem | Empty root remains unchanged; no additional writable root is granted |
| Persistence | `--ephemeral` creates no resumable session artifacts |
| Output | Exactly one terminal result conforming to `--output-schema`; all stdout records are valid JSONL |

Sandboxing alone does not pass tool isolation. If the CLI accepts a disable flag but still advertises or invokes that capability, the surface fails. If capability absence cannot be observed reliably, isolation fails.

## Ordering and dependencies

1. Capture all E1 real CLI cases before defining fixtures.
2. Add sanitized fixtures and failing H1 regression tests.
3. Implement the structured envelope parser and core outcome handling.
4. Run the complete E1 suite and freeze the semantic taxonomy.
5. Record Codex version, help, features, and baseline JSONL.
6. Run the budget and usage spikes.
7. Decide the enforced unit and ledger semantics.
8. Run process-containment fault injection.
9. Run isolation probes using the final candidate argv.
10. Record all commands, hashes, results, and decisions in `plans/codex-backend-spike-results.md`.
11. Do not begin the adapter registry until every exit criterion below is satisfied.

## Exit criteria for build-order step 3

Step 3—adapter registry plus selectable backend—is unblocked only when:

- H1 is implemented and all Claude error envelopes fail closed.
- Real, sanitized Claude fixtures cover success, 429, budget exhaustion, and partial-result behavior.
- The semantic taxonomy is stable and based on structured envelope evidence.
- Only authenticated `rate_limited` and explicitly proven transient-provider outcomes are candidates for later `availability` fallback.
- Codex has a proven enforceable per-run budget unit with a bounded maximum charge.
- Ledger reservation, settlement, migration, and mixed-backend semantics are decided.
- Codex JSONL provides a stable success/error/usage contract with sanitized fixtures.
- The real Codex CLI passes timeout, overflow, interruption, and descendant-cleanup tests.
- The exact Codex isolation argv passes every tool/MCP/web/configuration bar.
- The model and CLI version are explicit inputs to reviewer identity.
- No raw credentials, account identifiers, or unsanitized provider output are committed.
- All repository tests pass.

If any budget, containment, or isolation bar fails, step 3 remains blocked. Record the failed evidence and evaluate a direct API adapter or externally sandboxed runner instead of weakening the gate’s fail-closed, bounded-spend, or process-containment invariants.
