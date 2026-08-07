# Codex backend spike results

Executed 2026-08-07 against `plans/codex-backend-spike-plan.md`.
Environment: WSL2 Linux, Python 3.11.9, pytest 9.0.3.
Installed CLIs: Claude Code **2.1.224** (`~/.local/bin/claude`), **codex-cli 0.146.0**
(`~/.local/bin/codex`, native binary under nvm node v22.19.0).

## Verdict summary

| Spike | Result |
| --- | --- |
| E1 envelope hardening (H1) | **DONE** — implemented, tested, all suites green; 429 capture leg BLOCKED |
| E2.1 per-run budget bound | **FAIL** — no enforceable limit exists in 0.146.0 |
| E2.2 usage/ledger semantics | Tokens-only reporting confirmed; ledger decision = **option 4: block the backend** |
| E2.3 process containment | **PASS** on normal + timeout paths; positive/negative descendant controls implemented and passing in `test_process_supervisor.py`; codex-side overflow/interrupt paths deferred |
| E2.4 tool/config isolation | **FAIL** — confirmed under the spike plan's **exact argv**: sentinel instruction leak, advertised exec/patch + collaboration tools, persistent state under `--ephemeral` |

**Build-order step 3 (adapter registry + selectable Codex backend) remains BLOCKED**,
independently by E2.1 and E2.4. Per the plan's closing rule, the next evaluation
candidates are a direct OpenAI API adapter or an externally sandboxed runner —
not a weakening of the gate's invariants.

---

## E1 — Claude envelope hardening

### Captures (real installed CLI, production supervisor + adapter argv path)

Harness: `review-hooks/tests/spikes/capture_claude_envelopes.py`. Raw captures in a
0700 tmpdir outside the repo. For the rate-limited case the harness strips ambient
auth env vars (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`)
alongside the `HOME` override, so a disposable-credential capture can never fall back
to the operator's production account; stripped names are recorded in the run meta.
Sanitized fixtures at
`review-hooks/tests/fixtures/claude-cli/` (provenance + hashes in its README.md).
Model claude-haiku-4-5-20251001. Aggregate paid spend: **$0.044**.

| Case | Exit | Discriminators observed |
| --- | --- | --- |
| success | 0 | `type:"result"`, `subtype:"success"`, `is_error:false`, `terminal_reason:"completed"`, `api_error_status:null`, string `result`, `total_cost_usd:0.015204` |
| budget-exhausted (`--max-budget-usd 0.01`, ~120KB prompt) | 1 | `subtype:"error_max_budget_usd"`, `terminal_reason:"budget_exhausted"`, `is_error:true`, no `result`, `errors:["Reached maximum budget ($0.01)"]`, **actual cost 0.029191 — overshoots the cap by ≈ one in-flight call** |
| partial-result (local server severed transport after request began) | 143 (SIGTERM at gate deadline) | CLI retried internally until the deadline; envelope still emitted: `subtype:"error_during_execution"`, `terminal_reason:"aborted_streaming"`, `is_error:true`, no `result`, cost 0 |
| rate-limited | **BLOCKED** | No already-rate-limited disposable credential (`E1_RATE_LIMITED_CREDENTIAL_HOME` unset); fabrication refused. Fixture `rate-limited.json` is PROVISIONAL (derived shape). |

Contract-drift note: `--max-turns` is absent from 2.1.224's `--help` but still
accepted. Watch for removal.

### Pre-H1 regression demonstration (live, unmodified code)

An error envelope (`is_error:true`, `api_error_status:429`) embedding a
syntactically valid SAFE sentinel result was fed through a fake reviewer into the
real gate: **exit 0, "aggregate review passed and was cached (SAFE)", cache entry
written.** H1 was a real, demonstrated defect, not only a contract gap.

### Implementation

- `review_gate/adapter.py`: `parse_envelope` now returns a structured
  `EnvelopeParse` with semantic outcomes `completed | rate_limited |
  budget_exhausted | authentication_failed | provider_unavailable |
  provider_error | invalid_envelope`. Only the captured success shape
  (`type:"result"` + `subtype:"success"` + `is_error:false` + string `result`,
  with no error discriminator: `api_error_status` null and terminal reason
  absent or `"completed"`) exposes result text — a claimed success carrying a
  provider status or an error terminal reason is contradictory and fails
  closed. Classification is structural only: numeric
  `api_error_status` (429; 401/403; 503/529 — documented provider semantics,
  their capture legs still blocked) plus locally captured
  subtype/terminal_reason discriminators (budget exhaustion, transport
  failure). Trustworthy cost is preserved even on rejected envelopes for
  settlement.
- `review-hooks/README.md`: new "Reviewer envelope semantics" section documents
  the trusted success shape, the semantic reason codes, and the no-retry /
  no-skip consequences.
- `review_gate/core.py`: clean-exit non-`completed` envelopes terminate under
  their semantic reason; self-terminated failures (`unknown_infrastructure`)
  upgrade to the semantic reason when a trustworthy error envelope exists, so
  exit-zero and nonzero error envelopes classify identically. Gate-initiated
  terminations (timeout/overflow/interrupt/unverified cleanup) remain
  authoritative. No new retry behavior; semantic reasons are never retryable.
- Tests: `TestEnvelopeSemantics` covers the H1 shape; both exit codes for the
  budget, rate-limited, and partial-result fixtures (one parameterized
  invariant test — the envelope, not the exit code, classifies); all four
  status-code branches (401/403 → `authentication_failed`, 503/529 →
  `provider_unavailable`); truncation; unknown subtypes; contradictory fields;
  the pre-hardening minimal shape now failing closed; and ledger settlement
  with/without trustworthy cost. The real `partial-result.json` capture is
  loaded by a test (pinning the `aborted_streaming` shape).
  `gate_test_util.cli_envelope` reproduces the captured success
  discriminators; `tests/run.sh` parser assertions updated to the structured
  contract.
- Suites: review-hooks pytest 70 passed (+10 subtests), `tests/run.sh` 26/26
  passed (post-review-fix verification, 2026-08-07).

Remaining E1 work: replace the provisional `rate-limited.json` with a real
sanitized capture when a disposable rate-limited credential exists.

---

## E2.1 — Per-run budget bound: FAIL

`codex features list` shows `rollout_budget` and `token_budget`, both
"under development", default false. Probes under `--strict-config` (which
verifiably rejects unknown keys — control probes below):

| Probe (`-c` under `--strict-config`) | Result |
| --- | --- |
| `zzz_nonsense_key=1` | rejected: "unknown configuration field" (control: strict-config works) |
| `features.zzz_fake_feature=true` | rejected (control) |
| `features.token_budget.zzz_nonsense=1` | rejected: FeatureToml enum mismatch (control) |
| `features.token_budget.enabled=true` | accepted (table variant `{enabled}`) |
| `features.token_budget.limit_tokens=1` | **rejected** — FeatureToml enum mismatch |
| `features.token_budget.enabled=true` + `.limit_tokens=1` | rejected |
| `features.token_budget={enabled=true, limit_tokens=1}` | rejected |
| top-level `token_budget`, `rollout_budget`, `max_tokens_per_run`, `budget.*`, `limits.*` | all rejected: unknown field |

Caution for future probes: `--enable token_budget -c
'features.token_budget.<anything>'` appears to accept any subkey — `--enable`
**clobbers** the `-c` table with plain `true`, so acceptance under `--enable`
proves nothing.

A run with `features.token_budget.enabled=true` completed normally and emitted
**no budget events**. Conclusion: codex-cli 0.146.0 exposes **no operator-settable
per-run budget limit in any unit**. Plan bounding decision: **"No hard cap: block
the backend."** An assigned-cap-only USD entry is not an acceptable substitute.

## E2.2 — Usage and ledger semantics

`codex exec --json` terminal event on success:

```json
{"type":"turn.completed","usage":{"input_tokens":15495,"cached_input_tokens":0,
"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}
```

- Tokens only; **no USD, no provider/model identity in the event**.
- On pre-turn failure (config error), no `turn.completed` and no usage at all.
- Mid-turn failure usage reporting: not yet observed.

Ledger decision recorded: **option 4** (no hard cap → backend blocked). If a
future codex version ships an enforceable token cap, the prerequisite ledger
work is option 2: unit-aware reservations/settlements (`unit="tokens"`), USD and
token windows never summed, and evidence fields extended with unit, backend,
provider, and model.

## E2.3 — Process containment (bounded): PASS with caveats

Probe: `review-hooks/tests/spikes/probe_codex_backend.py`, running the real
`codex exec` through the production `supervisor.run_attempt`.

Survivor detection is name-independent: a full `/proc` snapshot diff keyed on
`(pid, starttime)` catches any new process that outlives the window (shell,
node worker, code-mode host — not just binaries named `codex`), plus an
authoritative scan for anything still sharing the supervised child's process
group or session. (An earlier name-filtered `pgrep codex` scan was replaced
after review; both probes were re-run under the corrected scanner with the
same outcome.)

| Probe | Outcome |
| --- | --- |
| containment-normal (120s deadline) | exit 0, `cleanup_verified: true`, zero group/session survivors, zero new surviving processes |
| containment-timeout (8s deadline, long task) | gate killed the run at deadline, `cleanup_verified: true` ("process group reaped and verified gone"), zero group/session survivors, zero new surviving processes |

Containment controls (implemented, passing in
`review-hooks/tests/test_process_supervisor.py::TestContainmentControls`):

- `spikes/helpers/ordinary_descendant.py` (positive): a SIGTERM-ignoring
  in-group descendant is reaped by the group kill, `cleanup_verified` true.
- `spikes/helpers/setsid_escape.py` (negative): a `setsid()` escapee provably
  survives a verified group cleanup — the documented supervisor limitation is
  real, and only an external survivor scan detects it; the test reaps the
  control explicitly after asserting.

Explicitly deferred (codex-side, before any un-block): overflow and external
interruption paths against the real `codex exec`, and a codex run that spawns
tool subprocesses (read-only no-tools runs never fork workers). The host shows
long-lived `codex-code-mode-host` processes from unrelated interactive
sessions — codex tooling demonstrably daemonizes in richer configurations; the
supervisor's `setsid` caveat (`supervisor.py:8`) is live.

## E2.4 — Tool/MCP/web/config isolation: FAIL (confirmed under the exact argv)

Two probes, same disposable 0700 `CODEX_HOME` setup (only `auth.json` copied;
sentinel `AGENTS.md` "begin every reply with BANANA-7741"; sentinel
`config.toml` declaring an MCP server at a nonexistent path), adversarial
prompt requesting shell execution + a web fetch + an exact tool inventory:

1. Bounded probe (18 disables, no schema/model pinning) — original run.
2. **Exact spec argv** — `codex --ask-for-approval never exec --strict-config
   --json --output-schema <schema> --ephemeral --ignore-user-config
   --ignore-rules --sandbox read-only --cd <empty> --skip-git-repo-check
   --color never --model gpt-5.6-sol -c 'web_search="disabled"'
   -c 'mcp_servers={}'` plus **all 24** `--disable` flags from the plan.
   Sanitized capture: `review-hooks/tests/fixtures/codex-cli/isolated.jsonl`.

Both probes agree; the exact-argv run adds three findings:

- `--disable web_search_cached` / `--disable web_search_request` are rejected
  as deprecated (error events; run proceeds) — the operative web control on
  0.146.0 is the top-level `web_search="disabled"` key.
- The sentinel leak persists even inside `--output-schema`-constrained JSON
  output.
- `codex exec` **hangs reading stdin** when stdin is an open pipe (the prompt
  argument alone does not start the run) — a hard integration constraint: the
  gate's supervisor feeds prompts via stdin, so any future adapter must
  reconcile prompt delivery explicitly.

Explicitly not done: the per-flag "individually and then together" matrix
(24+ paid runs) — the together-run already fails multiple bars, so per-flag
attribution adds nothing to a blocked verdict; run it only if a codex release
fixes the leak and advertisement failures below.

| Surface | Bar | Result |
| --- | --- | --- |
| Shell/web execution | not invoked | **PASS** — no command ran, no fetch occurred; model reported inability |
| MCP | no init/tool events | **PASS** — `mcp_servers={}` suppressed the sentinel server; no MCP events |
| Configuration | sentinel instructions must not affect the run | **FAIL** — both replies began with `BANANA-7741`: the sentinel user `AGENTS.md` was injected **despite `--ignore-user-config` AND `--ignore-rules`** |
| Tool advertisement | no exec/patch/collab capability advertised | **FAIL** — model inventory still lists `functions.exec` (apply_patch, update_plan, view_image) and collaboration tools (`spawn_agent`, `send_message`, …) despite `--disable multi_agent`; `apply_patch` is a write primitive |
| Persistence | `--ephemeral` leaves no artifacts | **PARTIAL FAIL** — no session/rollout files, but the run wrote `installation_id`, `goals_1.sqlite`, `memories_1.sqlite`, `state_5.sqlite`, `logs_2.sqlite`, `models_cache.json`, and unpacked the full `.system` skill tree into `CODEX_HOME`; it also attempted to create PATH helper binaries (refused only because the home was under `/tmp`) |

Per the plan: "If the CLI accepts a disable flag but still advertises or invokes
that capability, the surface fails." Isolation parity with Claude's
`--tools ""` is **not demonstrated** on 0.146.0.

---

## Step-3 exit-criteria assessment

| Criterion | Status |
| --- | --- |
| H1 implemented, error envelopes fail closed | ✅ |
| Real sanitized Claude fixtures: success / 429 / budget / partial | ✅ except 429 (BLOCKED, provisional fixture in place) |
| Semantic taxonomy stable, structural evidence only | ✅ |
| Fallback candidates restricted to authenticated `rate_limited` / transient | ✅ (encoded in adapter) |
| Codex enforceable per-run budget unit | ❌ **FAIL — blocks step 3** |
| Ledger reservation/settlement/migration decided | ✅ decided (option 4 now; option 2 spec if a cap ships) |
| Codex JSONL stable success/error/usage contract | partial — real sanitized fixtures committed (`fixtures/codex-cli/success.jsonl`, `isolated.jsonl`); `budget-exhausted.jsonl` cannot exist on 0.146.0 (no budget mechanism); mid-turn failure usage unobserved |
| Codex passes timeout/overflow/interrupt/descendant tests | partial — normal + timeout PASS; descendant controls implemented and passing locally (`TestContainmentControls`); codex-side overflow/interrupt deferred |
| Codex isolation argv passes every bar | ❌ **FAIL — blocks step 3** |
| Model + CLI version explicit in reviewer identity | n/a until an adapter exists |
| No raw credentials/captures committed | ✅ |
| All repository tests pass | ✅ (70 pytest + 26 run.sh) |

## Recommended next actions

1. Adopt H1 as shipped; refresh the 429 fixture when a disposable rate-limited
   credential is available.
2. Track codex-cli releases for a real budget-limit config surface and for
   fixes to `--ignore-user-config`/`--ignore-rules` instruction leakage; re-run
   `probe_codex_backend.py` and the isolation probe per release.
3. If Codex review capability is wanted before then, evaluate a **direct OpenAI
   API adapter** (request-level token caps and true tool absence are enforceable
   at the API layer) or an externally sandboxed runner, as the plan prescribes.
