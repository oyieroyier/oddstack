# Audit backlog

**Reference material, not a work queue.** Nothing here is scheduled, assigned, or in progress. It
is the residue of a nine-category audit of this repository (2026-08-06, against `fc3852b`) plus a
Claude–Codex peer deliberation over the changes that followed. Everything the audit found *and*
fixed is gone from this file — that work is in the code and its commit messages. What remains is
the part that would otherwise have to be re-derived: findings nobody has acted on, findings
deliberately rejected with reasoning, and decisions already adjudicated.

Two rules for using it:

- Line numbers and excerpts were accurate at `fc3852b`. Verify before acting; several files have
  changed since.
- Before re-auditing anything, read "Considered and rejected". Those were investigated and closed
  with evidence; re-finding them is wasted effort.

Shipped from this audit (do not re-plan): archive cache hygiene, a single verification entry point
plus CI, the hook-command stdin bypass, spend settlement for unlaunched attempts, the Bash 4.4
`mapfile` floor, the profile-override and evidence-mode hardening, packaging only the skills trees,
and passing parsed findings to the durable-intake updater.

---

## Next slice (scoped, unstarted)

### Mixed blocking results: `intake_pending` and the acknowledgement gate

A blocking `MERGE-WITH-FIXES` currently bypasses durable intake entirely, so its non-blocking
SHOULD-FIX findings are never preserved. The bypass is deliberate and safe as an interim state —
it stops a broken updater from destroying a fully paid decision and its bound-acknowledgement path
— but it leaves one real gap: the acknowledgement flow can accept a blocking decision whose
findings were never preserved.

Shape (from the deliberation, Codex's recommendation, endorsed):

1. For a blocking `MERGE-WITH-FIXES`, attempt intake.
2. On failure, still cache the decision — never re-pay for a review — but mark it `intake_pending`
   and retain the structured payload.
3. Retry intake when the cache entry is used.
4. Refuse acknowledgement-based acceptance while `intake_pending` is set.

Relevant code: the gate at `review-hooks/review_gate/core.py` (`result.verdict ==
"MERGE-WITH-FIXES" and not result.blocking`), the acknowledgement path in `_apply_cached`, and
`review-hooks/review_gate/durable.py`'s `build_payload`, which already produces what step 2 needs.

`DO-NOT-MERGE` also carries non-blocking findings and never invokes intake. That is deliberate —
it is rejection, not publish-with-follow-ups — but architecture requirement 11 should say so
explicitly rather than leaving it implied.

---

## Unimplemented findings

Ordered by leverage within each group. Effort in parentheses.

### Correctness

- **Prior findings dropped for size silently narrow the review.** `prompts.py`
  `_prior_findings_section` returns `("", 0)` when open findings exceed `max_prior_report_bytes`;
  the caller never widens `review_from`, so unresolved MUST-FIX findings vanish and an incremental
  SAFE is cached as full-range coverage. Fix: fall back to `review_from = target.base` and record
  `prior_findings_dropped` in evidence. (S, HIGH confidence.)
- **Durable-intake failure still discards a paid non-blocking decision** and the retry re-pays; a
  permanently broken updater is an unbounded money loop. Intake also inherits only whatever run
  deadline remains. Needs a design decision first: reserve minimum time for intake, use the
  `intake_pending` flag above, or accept the re-pay.
- **`BranchState.path` digests the already-sanitized branch name**, so `feature/x` and `feature-x`
  share one state file — the code comment claims the opposite. Hash `target.local_ref`. (S)
- **`gitwork.py` decodes git output with the ambient locale codec** (`text=True`, no `encoding=`).
  Under `LC_ALL=C` any non-ASCII byte in a diff crashes the hook. Add `encoding="utf-8",
  errors="replace"` via one shared helper. (S)
- **Changed filenames are passed to `git diff` as pathspecs** without `--literal-pathspecs`; names
  containing glob characters misroute the general/backend scope split. (S)
- **Cache and state loaders type-check some fields but not `report_path`**; a `null` in hand-edited
  JSON raises `TypeError` instead of the documented ignore-and-re-review. (S)
- **`AttemptOutcome.failure_summary` has no branch for `overflow`/`interrupted`** and renders
  `"exited None"` for signal deaths. (S)
- **`subagent_ledger.py init` refuses a re-run** when `--baseline-agent` includes the root agent:
  the stored set is stripped of it, the compared set is not. Normalize both sides; also compare
  caps on re-init. (S)

### Shell / installers

- **Hooks resolve the runtime through the checked-out working tree** (`$repo_root/.review-hooks/`).
  Checking out a pre-install branch silently runs *no* hooks; a partial state hard-fails with exit
  127. (M)
- **Installer copies are purely additive** — files removed from a newer bundle are never pruned, so
  upgrades drift-refuse forever. (M)
- **`review-hooks/install.sh` copies non-atomically with no cleanup trap**; an interrupted install
  leaves executable hooks over a partial runtime and refuses re-runs without `--force`. (M)
- **`doctor.sh` decides "AI review enabled" by regex** while the runtime decides by sourcing;
  quoted values invert the safety signal. Source in a subshell as `review-hooks/install.sh`
  already does. (S)
- **`pipefail` + `grep -q` SIGPIPE races** in four test assertions — see "Known flake" below. (S)
- **The NUL-safe staged-file list is flattened to newlines** before consumers read it, so a path
  containing a newline splits into two bogus entries. Interface change; document `xargs -0`. (S)
- **doctor's page-approval guard greps the wrong tree** (the source copy, not the installed
  runtime) and PASSes on every failure mode. (S)
- **Test fixtures symlink `$(command -v tool)` without checking the tool exists**, producing
  misleading failures on hosts without `rg` or `sha256sum`. (S)

### Security

- **`evidence.sanitize()` only neutralizes ``` fences.** Reviewer-controlled finding text can forge
  Markdown structure in `report.md` and `latest.md` — files later agents read — and pass raw ANSI
  to terminals. The architecture doc claims escaping that does not exist. One flattening escaper at
  every render site. (M)
- **The legacy v1 path still honors an `AI_REVIEW_HUMAN_ACK` environment override of a blocking
  verdict** (`core.py` `_apply_legacy_cached`) — the exact escape class v2 closed. Retiring the v1
  surface removes it; see below.
- **`evidence.py` chmods the shared `ai-reviews/` roots to `0700` on every finalize**, removing
  group/setgid access, potentially following a symlinked evidence store, and swallowing failures.
  Currently strictly tighter than before and no in-repo setup shares the directory, so it was
  accepted as a follow-up rather than a blocker. Prefer private per-run objects, or a configurable
  parent policy. (S)

### Tests

- **Known flake, now in CI.** During review the root suite reported `1 of 24 tests failed` on one
  run and passed on seven runs after it; the failing test was not captured and did not reproduce.
  Pre-existing, and consistent with the `pipefail` + `grep -q` SIGPIPE race above. Since CI now
  runs this suite on every push, fix that race and the supervisor timing asserts *before* making
  the workflow a required check or tightening its timeout.
- **`results.py`: 1 of ~12 reviewer-output rejection branches is tested.** This is the untrusted-LLM
  → cached-decision boundary. Table-driven unit tests on a pure parser. (S)
- **`parse_push_updates` is exercised by exactly one input shape**; deletes, tags, and malformed
  lines are untested. (S)
- **`policy_hash` invalidation is tested for 1 of 13 hashed fields.** Pin all 13, plus one
  deliberately-unhashed control to pin the exclusion in both directions. (S)
- **3 of 4 secret-scan patterns untested**, redaction untested, and the `unset AI_REVIEW_CLAUDE_BIN`
  boundary untested. (S)
- **SpendLedger flock contention and corrupt-ledger lines untested.** The scary one is a non-finite
  `actual_usd` poisoning the window sum and disabling the limit — the guard exists, nothing pins
  it. (M)
- **`configure-claude-alert.py` error and security paths untested** — symlink refusal, invalid
  JSON, non-dict root, `--status` exit codes, mode preservation. (S)
- **Supervisor suite asserts absolute wall-clock seconds** around real subprocesses. De-flake before
  tightening CI timeouts. (M)
- **Several root-suite tests grep docs or stdout prose instead of behavior** — fragile to rewording
  and blind to real regressions. (M, needs judgment about intended invariants.)

### Dependencies, DX, docs

- **`configure-claude-alert.py` needs Python 3.10** (`pathlib.Path | None` in a runtime-evaluated
  annotation, no `__future__` import). On 3.8/3.9 bootstrap dies mid-install and `doctor.sh`
  mislabels it as "notifications not enabled". One-line fix plus a documented floor. (S)
- **macOS dead end**: `sha256sum` is required, and the brew map lacks `coreutils`. (S)
- **`rg` is a blocking requirement no bundled code executes**; `tar` — which `package.sh` genuinely
  needs — is permanently inactive; `timeout` is mapped but never checked. (S)
- **Test fixtures need git ≥ 2.28** (`git init --initial-branch`), undocumented and unchecked. (S)
- **The claude CLI flag surface is hardcoded in three places** and fails closed as an opaque
  INCONCLUSIVE. Consider a memoized `--version` probe and an `incompatible_cli` reason code whose
  message names the evidence file. (M, MED confidence.)
- **No root `CLAUDE.md`/`AGENTS.md` for agents working on *this* repo.** The archive-rebuild rule
  and the two coexisting Python styles are undiscoverable; the latter already produced the 3.10 bug
  above. (S — high leverage for this repo's audience.)
- **shellcheck pragmas exist but no runner.** Add to CI non-blocking. (S)
- **`docs/harness/review-execution-implementation-plan.md` still says "Status: Ready for
  implementation"** for work shipped several releases ago — an agent-facing footgun in a repo built
  on plan documents. Retitle as an as-built record. (S)
- **`review-hooks/README.md` says two hooks; there are three.** The composition recipe inherits the
  omission, so followers silently skip `commit-msg`. (S)
- **README layout omits `review_gate/`, `bin/`, and `docs/`**; `sed -n '1,260p'` truncates the
  deactivate and verify sections. (S)
- **`CLAUDE.md.codex-skills-snippet.md` catalogs 6 of 9 installed skills**, hand-synced. Generate it
  or test it. (S)

### Architecture

- **Committed binary archives as the release mechanism.** ~350 KB of history per commit,
  unmergeable conflicts on every parallel branch, staleness only warned. Distribution-model
  decision. (M, decision first.)
- **`core.py` is 797 lines; `_run_paid_review` ~330 lines at depth 7.** The money and blocking path
  is only testable end-to-end. Extract preflight / attempt-loop / commit-decision seams with the
  existing flow tests as characterization. (L)
- **Config layering costs 6+ edit sites per knob**, with defaults duplicated in Bash and Python and
  nothing cross-checking them. Make `policy.py` the single source. (M)
- **Retire the version-1 compatibility surface.** ~200 lines across seven files serving a format
  the bundle stopped producing several releases ago, promised as "one release" of support. Includes
  the `AI_REVIEW_HUMAN_ACK` escape above. Needs a major-version decision. (M)
- **`deliberate-with-peer` is duplicated across `.claude/` and `.agents/`**; the parity test covers
  3 of 6 shared files, the two `SKILL.md`s carry ~70 hand-synced identical lines, and two ~230-line
  runner scripts are near-identical. (M)
- **Two Bash test harnesses reimplement the same ~35-line preamble.** Extract `tests/lib.sh`. (S)
- **Full diffs are materialized three times per paid run** and once per cache-hit push purely for
  emptiness and budget checks. Use `git diff --quiet` and derive counts from the scope diffs. (S)
- **~9 redundant git forks per push** across the hook chain. (S, modest.)
- **No retention for `ai-reviews/runs/`, `cache/`, or the spend ledger.** Growth-only today; any
  compaction must provably drop only out-of-window entries or it silently raises the spend limit.
  (M)

---

## Considered and rejected

Do not re-audit these without new evidence.

- **Sensitive-path egress via the incremental review range.** Rejected after derivation. Branch
  state only exists after a completed review whose own `base..state.head` range passed the same
  sensitive check, so for any sensitive path the content at `base` equals `state.head`; it
  therefore differs across `review_from..head` if and only if it differs across `base..head`, and
  the aggregate check covers both. Policy-hash binding rules out the regex-changed variant. Two
  independent audit passes reached the same conclusion.
- **`SpendLedger._window_total` taking the last matching line in file order.** Correct as written:
  `flock` serializes appends, so file order is chronological, and a backward clock jump resolves
  conservatively.
- **`manage-dependencies.py` post-install PATH re-check ignoring `--search-path`.** Real, but the
  flag is hidden and test-only. Sub-threshold.
- **`doctor.sh --fix` / self-repair.** Deliberately rejected. Read-only-ness is the tool's clearest
  property and every warning already prints its remediation command.
- **A dependency manifest / `pyproject.toml`.** Stdlib-only is a deliberate, honored constraint. The
  real risk is interpreter and shell floors, listed above.
- **Supervisor drain-loop latency.** Examined and found well built — selector-based, no busy-wait,
  failure-path sleeps only.
- **`package.sh` rebuild cost.** Sub-second at this size.
- **Restoring `REVIEW_HOOKS_PROFILE` for one release with a warning.** Rejected in deliberation: a
  compatibility shim retains the security hole it was removed to close. The loud refusal that
  shipped is the correct form of compatibility.

---

## Decisions already adjudicated

From the Claude–Codex deliberation over the 2.2.0 changes. Settled; reopen only with new evidence.

- **The `CATALOG_COMMIT` → `AI_REVIEW_HEAD_COMMIT` rename needed no compatibility shim.**
  `origin/main` was at `2.1.1`; `2.1.2`, which introduced the old name, was never pushed. The
  rename broke no released consumer.
- **`REVIEW_HOOKS_PROFILE` refuses loudly rather than being ignored.** Ignoring a set value would
  run policy the caller did not intend while they believed otherwise. A value naming the canonical
  path is accepted; anything else refuses, with no path normalization so aliases and symlinks fail
  conservatively.
- **Released as `2.2.0`, not `2.1.3`.** No SemVer contract is documented, but consumers upgrading
  from `2.1.1` gain a feature and lose profile-path selection, and the version should say so.
- **`RUNTIME_VERSION` is pinned to the bundle `VERSION`,** with a drift test. It labels every
  `run.json` and is not a schema constant — the schema versions beside it are separate.
- **The durable-intake payload is bounded parsed-result JSON on stdin.** Operator's decision. Raw
  reviewer prose is excluded: untrusted model output the harness does not copy. Changing the
  payload shape is a breaking change for intake generators and should move the minor version with
  an upgrade note.
- **`package.sh --check` cannot detect contamination present in both the archive and the working
  tree.** It compares a rebuild of the same tree against itself. Archive *shape* is asserted
  separately for that reason — this is why `test_release_archives_contain_only_bundle_content`
  exists and why it must not be replaced by a tree-equality check.

---

## Direction options

Maintainer decisions, not defects. Each cites repo evidence; effort is coarse.

1. **A Codex reviewer backend.** `AI_REVIEW_BACKEND` exists with exactly one legal value,
   `adapter.py` is already the seam, and the architecture doc plans for multiple adapters. This is
   the one place a "Codex ↔ Claude" harness only spends Claude quota. Spike three unknowns first:
   whether `codex exec` exposes a per-run budget cap, whether it reports actual cost (the ledger
   depends on it), and whether it daemonizes (the process-group containment claim must be
   re-proven). (L)
2. **A `claude-review` mirror skill.** The pairing table has four Claude→Codex skills against one
   narrow, stack-specific Codex→Claude skill. An adversarial-review mirror reusing the existing
   severity rubric is the cheapest way to make "supports both directions" true for repos that are
   not TanStack web apps. (M)
3. **A bundle version stamp and an uninstall path.** `review-hooks` already stamps
   `bundle-version` and has `--deactivate`; the skills installer and `bootstrap.sh` have neither, so
   evaluating this bundle is a one-way door. Stamp first, then a stamp-driven `--uninstall` that
   removes only what it installed and refuses on drift. (S–M, then M)
4. **Tooling for `plans/agent-handoffs/` and `plans/model-deliberations/`.** The resumable-state
   promise is enforced only by prose, while `subagent_ledger.py` proves the CLI pattern is accepted
   here. Start read-only: `list`, `status`, `resume`. (M)
