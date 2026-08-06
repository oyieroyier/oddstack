# Review execution harness implementation plan

Status: Ready for implementation  
Depends on: [Review execution harness architecture](review-execution-architecture.md)

## Scope

This plan changes the optional aggregate review runtime, its installer, doctor checks,
documentation, tests, and release archives. It does not change the delegation or peer
deliberation skills.

Do not copy the LMM emergency script over the bundle. Use it only as a regression source for
shared-deadline and process-group tests.

## Phase 1: freeze the current contract

1. Add fixtures for the version 1 profile and three-line result markers.
2. Record the current exit codes for safe, blocking, sensitive, personal-quota, multi-ref, and
   malformed-result cases.
3. Add a fixture that proves the old timeout applies per attempt. Mark it as a legacy behavior
   test to remove in phase 4.
4. Add a fixture for a reviewer that starts a nested child, ignores `SIGTERM`, and holds output
   open.
5. Add a fixture that proves an output flood is retried today (`SIGPIPE` from the byte cap ends
   the pipeline with 141, which the loop retries). Mark it as a legacy behavior test; version 2
   must end such a run after one attempt.

Verification:

```bash
review-hooks/tests/run.sh
git diff --check
```

STOP if a documented version 1 behavior differs from the fixture. Record the difference before
changing runtime code.

## Phase 2: build the deep module test first

Create `review-hooks/review_gate/` with no third-party dependencies. Start with the public command
and fake reviewer adapter.

Write tests for:

- push update parsing and exact target resolution;
- version 2 policy validation;
- cache-key inputs;
- refusal to cache an unknown model identity;
- structured result parsing;
- completed, blocking, and inconclusive evidence;
- human acknowledgement binding;
- retry classification and spend allocation;
- rolling cross-run spend ledger refusal and disable switch;
- refusal to start a paid attempt without a named model, and the model flag on every launch;
- prior-finding size and full-prompt size checks.

The test adapter must record invocations, arguments, assigned budget, process id, and supplied
prompt digest. Tests call the public command, not internal functions.

Verification:

```bash
python3 -m unittest discover -s review-hooks/tests -p 'test_*.py'
review-hooks/tests/run.sh
```

STOP if a needed policy cannot be expressed without adding repository-specific behavior to the
module. Put that behavior in the profile adapter instead.

## Phase 3: add the process supervisor

Add the Claude adapter and process supervisor with `start_new_session=True`, a monotonic deadline,
selector-owned bounded output capture, `SIGTERM`, `SIGKILL`, wait, and process-group verification.

Add deterministic tests for:

1. safe completion;
2. known fast startup transport failure followed by one successful retry;
3. timeout with maximum attempts set to two but one actual call;
4. direct child ignoring `SIGTERM`;
5. nested child ignoring `SIGTERM`;
6. child exit while a descendant holds output open;
7. output flood;
8. missing executable;
9. forced-cleanup failure;
10. interruption during an attempt.

Each timeout test uses an outer test timeout. After the command returns, check every recorded pid
until it exits or the short assertion deadline ends.

Verification:

```bash
python3 -m unittest review-hooks.tests.test_process_supervisor
python3 -m unittest discover -s review-hooks/tests -p 'test_*.py'
```

STOP if the implementation cannot prove process-group cleanup on the supported platform. Do not
label the run bounded based only on the direct child's exit. Do not claim containment for a
reviewer adapter that can move work into another session.

## Phase 4: add profile version 2 and adapters

1. Add version 2 defaults to `generic.conf` and `lmm.example.conf`.
2. Add the `review-gate` executable.
3. Reduce `run-ai-review-gate.sh` to a compatibility adapter.
4. Change `run-pre-push-gate.sh` to pass its captured updates file to `check-push`.
5. Default version 2 local push mode to `verify`.
6. Keep version 1 loading for one release and print a migration warning.
7. Add the explicit preflight command to `review-hooks/README.md`.

Run one integration test with a fake `claude` executable and the same environment boundary used
by an installed repository.

Verification:

```bash
bash -n review-hooks/install.sh
bash -n review-hooks/hooks/*
bash -n review-hooks/scripts/*.sh
python3 -m unittest discover -s review-hooks/tests -p 'test_*.py'
review-hooks/tests/run.sh
```

STOP if `verify` mode can launch a reviewer or if `run-if-missing` can use personal credentials
without the one-run opt-in.

## Phase 5: add evidence and cache migration

1. Write the versioned JSON and Markdown evidence for every terminal result.
2. Use atomic writes for decision cache and branch state.
3. Add policy, prompt, and reviewer identity to the cache key.
4. Read legacy cache entries only through the compatibility adapter.
5. Never promote a legacy or new `INCONCLUSIVE` report into the decision cache.
6. Add the bound acknowledgement command.
7. Append every paid run to `ai-reviews/spend/ledger.jsonl` and refuse a paid launch that would
   pass the rolling limit.
8. Run an optional repository-owned durable-intake command for each fresh non-blocking
   `MERGE-WITH-FIXES` decision before finalizing evidence or writing cache or incremental state.
   Bind the command to the policy hash and fail inconclusive if it cannot finish inside the
   remaining run deadline.

Tests must cover damaged state, a moved report, a stale policy hash, a changed reviewer identity,
and a blocking report with an acknowledgement copied from another tree.
Also cover successful intake, updater failure without cache, SAFE bypass, blocking bypass,
exact-cache bypass, a noisy updater whose output volume must not fail intake, a version 1 profile
refusing the command, and enabling intake after an older cached decision.

Verification:

```bash
python3 -m unittest discover -s review-hooks/tests -p 'test_*.py'
review-hooks/tests/run.sh
```

STOP if an acknowledgement can survive any change to report digest, base, tree, risk class, or
policy hash.

## Phase 6: add install and doctor migration

1. Add the bundle version and source digest to installed runtime files.
2. Teach `doctor.sh` to report runtime drift and profile version.
3. Make `doctor.sh --strict` fail for profile version 1, stale runtime, stale archives, or missing
   Python 3.
4. Keep install refusal for unreviewed drift.
5. Add the two harness architecture documents to the release archive and its extracted-file test.
6. Document how a consumer moves a local emergency patch upstream, reinstalls, and deletes the
   private fork.
7. State the Python 3 requirement in the main and review-hooks READMEs, next to the existing
   Bash 4 requirement.

Test install, upgrade, refusal, forced update, deactivate, and archive extraction in temporary
repositories.

Verification:

```bash
tests/run.sh
review-hooks/tests/run.sh
./doctor.sh --repo "$PWD" --skip-archives
```

STOP if install can overwrite a locally changed review runner without `--force`.

## Phase 7: migrate LMM as the first consumer

Do this phase in the LMM repository after the bundle release.

1. Save the exact bundle release tag and digest in the LMM handoff.
2. Compare the released supervisor tests with the LMM regression from commit `8b82f3b6`.
3. Install the released runtime.
4. Move LMM path rules and deterministic commands into its version 2 profile.
5. Remove the private runner only after parity tests pass.
6. Run one fake timeout test, one local preflight review, and one cache-only push-hook test.
7. Record the review run id and exact outputs in the LMM recovery evidence.

STOP if the installed bundle loses any stricter LMM rule for sensitive paths, backend scope,
personal quota, security or money acknowledgement, or visual audit.

## Phase 8: review and release

Review the diff on two axes:

- Standards: module boundary, shell safety, Python process handling, docs, install behavior, and
  release contents.
- Spec: every goal and acceptance rule in the architecture.

Fix all process cleanup, spend-bound, credential, evidence, and cache-binding findings before
release. Treat review infrastructure failure as `INCONCLUSIVE`; it does not count as a pass.

Then rebuild and check release files:

```bash
./package.sh
./package.sh --check
bash -n install.sh
tests/run.sh
review-hooks/tests/run.sh
python3 -m unittest discover -s review-hooks/tests -p 'test_*.py'
git diff --check
```

Release done criteria:

- all architecture acceptance rules have a named passing test;
- version 2 migration text appears in the main and review-hooks READMEs;
- doctor reports profile and runtime versions;
- both archives match source and pass an extracted install test;
- the LMM consumer test proves preflight plus cache-only push;
- no task-created process, temporary worktree, or untracked evidence remains.
