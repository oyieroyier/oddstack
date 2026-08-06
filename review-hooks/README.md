# Collaboration review hooks

This optional module provides two Git hook adapters backed by one versioned profile:

```text
pre-commit → deterministic staged-change checks
pre-push   → configurable commands → verify one cached review decision
```

The hooks are thin adapters. Every review decision lives in the `review_gate` Python module
behind one executable, `.review-hooks/bin/review-gate`. It owns target resolution, policy
validation, prompt construction, process supervision, result parsing, evidence, caching, and
acknowledgements.

Installing the skills does not activate these hooks. Activation requires a separate, explicit
`review-hooks/install.sh` invocation.

The implementation requires Bash 4 or newer and, for AI review, Python 3 and `sha256sum`; these
are common on GNU/Linux but may need installation on other platforms.

## Install

From the bundle root:

```bash
review-hooks/install.sh \
  --repo /path/to/repository \
  --profile generic
```

The installer copies runtime files into `.review-hooks/`, hook adapters into
`.collaboration-hooks/`, and the selected profile into `.review-hooks.conf`. It then sets the local
repository's `core.hooksPath` to `.collaboration-hooks`.

Use `--dry-run` to inspect the decision first. Use `--force` only to update an installation whose
existing files you have reviewed.

## Existing hook systems

Git supports one `core.hooksPath`. The installer therefore refuses to replace Husky, Lefthook, a
committed `.githooks` directory, or any other configured hook path by default.

Choose one of these approaches:

1. Install without activation:

   ```bash
   review-hooks/install.sh \
     --repo /path/to/repository \
     --profile generic \
     --no-activate
   ```

   Then invoke the relevant deep implementation from the existing hook:

   ```bash
   .review-hooks/scripts/check-staged-change.sh
   .review-hooks/scripts/check-commit-message.sh "$1"   # from a commit-msg hook
   .review-hooks/scripts/run-pre-push-gate.sh
   ```

2. Explicitly replace the current hook path:

   ```bash
   review-hooks/install.sh \
     --repo /path/to/repository \
     --profile generic \
     --replace-hooks-path
   ```

   The installer records the previous path and restores it on deactivation.

Never chain two tools that each expect to consume pre-push standard input without explicitly
capturing and replaying that input.

## Profile interface

`.review-hooks.conf` is trusted repository policy sourced by Bash. Review changes to it as
executable code.

Required version:

```bash
REVIEW_HOOKS_PROFILE_VERSION=2
```

Deterministic controls:

```bash
PRE_COMMIT_SECRET_SCAN=1
PRE_COMMIT_COMMANDS=''
COMMIT_MSG_COMMANDS=''
PRE_PUSH_COMMANDS=''
```

Commands are newline-separated Bash commands executed from the repository root. Pre-commit
commands receive `REVIEW_HOOKS_STAGED_FILES_FILE`, a temporary newline-delimited list of staged
paths. Commit-msg commands receive `REVIEW_HOOKS_COMMIT_MSG_FILE`, the absolute path of the
commit-message file; an empty `COMMIT_MSG_COMMANDS` makes the hook a no-op. A command's exit code
blocks the commit, so a warn-only checker must exit zero itself or carry a trailing `|| true`.
Pre-push commands receive `REVIEW_HOOKS_PUSH_UPDATES_FILE`, which contains Git's pre-push
standard-input records.

AI-review controls (version 2):

```bash
AI_REVIEW_ENABLED=0
AI_REVIEW_PRODUCT_NAME='this repository'
AI_REVIEW_DEFAULT_BASE='origin/main'
AI_REVIEW_BACKEND_PATH_REGEX='^(api/|backend/|server/|db/|migrations/|sql/)'
AI_REVIEW_SENSITIVE_PATH_REGEX='...'
AI_REVIEW_SENSITIVE_PATH_ALLOW_REGEX='\.example$'
AI_REVIEW_PUSH_MODE=verify
AI_REVIEW_TOTAL_TIMEOUT=600
AI_REVIEW_KILL_GRACE=5
AI_REVIEW_MAX_ATTEMPTS=1
AI_REVIEW_RETRYABLE_FAILURES=''
AI_REVIEW_MIN_RETRY_TIME=30
AI_REVIEW_MAX_DIFF_LINES=3000
AI_REVIEW_MAX_BACKEND_DIFF_LINES=1200
AI_REVIEW_MAX_PROMPT_TOKENS=32000
AI_REVIEW_MAX_PRIOR_REPORT_BYTES=12000
AI_REVIEW_MAX_OUTPUT_BYTES=30000
AI_REVIEW_MAX_BUDGET_USD=2.00
AI_REVIEW_MODEL='claude-sonnet-5'
AI_REVIEW_MERGE_WITH_FIXES_COMMAND=''
AI_REVIEW_ROLLING_SPEND_LIMIT_USD=10.00
AI_REVIEW_ROLLING_SPEND_WINDOW_HOURS=24
```

`AI_REVIEW_TOTAL_TIMEOUT` covers the whole run: prompt creation, every attempt, parsing, and
cleanup. `AI_REVIEW_MAX_BUDGET_USD` is also run-wide; attempt caps sum to it. `AI_REVIEW_MODEL`
is required before a paid attempt starts — a run never inherits the operator's interactive CLI
default. The rolling limit bounds paid spend across runs inside the window; set `0` to disable.

The generic profile keeps AI review disabled. Enable it only after adapting repository naming, path
classification, sensitive-path rules, budgets, and credential ownership.

`AI_REVIEW_MERGE_WITH_FIXES_COMMAND` is an optional repository-owned intake command and requires a
version 2 profile. After a fresh non-blocking `MERGE-WITH-FIXES` review parses, the gate runs this
command from the repository root with `AI_REVIEW_HEAD_COMMIT` set to the reviewed head. The
command must finish successfully before evidence is finalized, the decision is cached, or branch
state advances. Failure or timeout makes the run inconclusive. SAFE decisions, blocking decisions,
and exact cache reuse do not invoke it. The updater and its descendants run in a bounded process
group; its output is captured for diagnostics (truncated past 4 KiB) but output volume never fails
it, and failure is recorded as the terminal outcome while retaining the reviewer decision as
context. Because the profile is trusted executable policy, changing the command invalidates
cached decisions. The generic profile leaves it empty; a consumer must own the destination,
reconciliation rules, secret handling, and generated-file commit flow.

### Upgrading to 2.2.0

Two behaviors changed for anyone on 2.1.x. Neither is a profile-version change; both take effect
as soon as the runtime is upgraded.

- `REVIEW_HOOKS_PROFILE` is gone. It let the caller's environment choose which file was sourced as
  trusted policy — the same class of hole that `AI_REVIEW_CLAUDE_BIN` is unset to close. Repository
  policy is now always `<repo>/.review-hooks.conf`. A set value that names any other path refuses
  the hook with migration guidance rather than being ignored, so nobody commits believing a policy
  file governed when it did not. Unset it and move the policy to the canonical path.
- Installation now appends `ai-reviews/` to the target repository's `.gitignore` instead of
  printing a reminder, and evidence files are created owner-only. If the repository deliberately
  versions review evidence, remove the entry after installing.

### Migrating from version 1

Version 1 profiles still load for one release, with a warning. Two meanings changed:

- `AI_REVIEW_TIMEOUT` applied to each attempt; it now maps to the run-wide deadline.
- The runner retried every non-zero exit; now only failures listed in
  `AI_REVIEW_RETRYABLE_FAILURES` retry (`startup_transport`, matched against
  `AI_REVIEW_STARTUP_EXIT_CODES`), and never after a timeout, output flood, or invalid result.

`scripts/run-ai-review-gate.sh` remains as a forwarding compatibility adapter. Move to a version
2 profile and call `bin/review-gate` directly; `doctor.sh --strict` fails on version 1.

`profiles/lmm.example.conf` is a reference adapter for Sokko/Lipa Mdogo Mdogo. It is intentionally
not a portable default.

## Manual page-review gates

Repositories can put a page-ledger checker in `PRE_PUSH_COMMANDS`. The LMM reference profile runs
`pnpm audit:pages`, which detects ledger errors and stale approvals before AI review.

Keep the operator-only action outside this module:

- Agents may run the advisory checker.
- Agents may demote a stale approval with the repository-prescribed command and a specific reason.
- Agents may register a new route as `PENDING` and add it to the manual walkthrough.
- Agents must report every `PENDING` or `REOPENED` route still awaiting review.
- Agents and automated hooks must never invoke the page-approval command.

Approval is evidence that a person physically inspected the rendered page. Automating it would
erase the meaning of the release gate. Production deployment should enforce the repository's
blocking page-audit mode separately.

## Review workflow

Run the paid review before pushing, while no remote connection is open:

```bash
AI_REVIEW_ALLOW_PERSONAL_QUOTA=1 .review-hooks/bin/review-gate review
```

Pass the opt-in per invocation, as above. Do not export it from a shell profile: an exported
value authorizes every later paid run in that shell. The rolling spend ledger bounds the damage
of a standing opt-in; it does not remove it.

`review` resolves one exact base/tree pair (upstream by default; `--base`/`--head` to pin it),
runs the bounded review, writes evidence, and caches the decision. The pre-push hook then runs
`review-gate check-push` in `verify` mode: it accepts only a matching completed decision and
never starts a reviewer while `git push` holds a connection. A network retry of the push can
never buy a second review.

CI that owns credentials and budget may set `AI_REVIEW_PUSH_MODE=run-if-missing` with
`AI_REVIEW_CREDENTIAL_SCOPE=ci` to run a missing review inside the gate.

When enabled, the gate:

- reviews one pushed branch at a time;
- reviews the aggregate remote-to-local diff rather than every commit;
- separates backend-owner paths from the general scope;
- refuses configured sensitive paths;
- runs the reviewer in its own process group and reaps the whole group on every exit path;
- bounds the run with one deadline and one spend cap, plus a rolling cross-run spend ledger;
- refuses implicit use of personal model quota and unnamed reviewer models;
- caches decisions by base, tree, policy hash, prompt template fingerprint, and reviewer
  identity, so editing the prompt template voids every cached verdict;
- carries structured open findings into an incremental follow-up, size-capped;
- runs the optional repository-owned durable intake command before caching a fresh
  non-blocking `MERGE-WITH-FIXES` decision;
- writes `ai-reviews/runs/<run-id>/` evidence for every decision, including `INCONCLUSIVE`;
- exits 0 (accepted), 1 (blocking findings), or 2 (no trustworthy decision).

### Changes the gate refuses to review

The prompt embeds the diff inside reserved data tags and a result sentinel. A diff whose content
contains those tokens — including any change to `review_gate/prompts.py` itself — could forge the
data boundary or the verdict, so the gate fails closed instead of building the prompt. The same
applies to a diff over the configured size budgets. Review such a change with another tool
(a read-only Codex or Claude review, or a human), then use the skip flow below; the skip writes
its own evidence run.

### Acknowledging a blocking review

A blocking decision is overridden only by an acknowledgement bound to the exact report, base,
tree, risk class, and policy:

```bash
.review-hooks/bin/review-gate acknowledge \
  --report ai-reviews/runs/<run-id>/report.md \
  --reason "TICKET-123"
```

The gate prints this command with the exact report path when it blocks. A free-text environment
variable no longer overrides blocking findings; an exported variable cannot silently disable the
gate.

### Skipping a review

Skipping binds to the exact pushed commit, so a stale exported value cannot skip the next push:

```bash
SKIP_AI_REVIEW=<first 12+ characters of the pushed commit sha> \
AI_REVIEW_HUMAN_ACK="<ticket or reason>" \
git push
```

The skip writes its own evidence run.

Review reports, evidence, cache, and the spend ledger are written to `ai-reviews/`. Add that
directory to the target repository's ignore rules unless the repository deliberately versions
review evidence. Installation appends `ai-reviews/` to the target repository's `.gitignore`
automatically, and evidence files (the run directory and each attempt's stdout/stderr) are
created owner-only.

## Deactivate

```bash
review-hooks/install.sh \
  --repo /path/to/repository \
  --deactivate
```

Deactivation restores the previous `core.hooksPath` when one was replaced. Installed files remain
so their removal can be reviewed and committed normally.

## Verify

Run from the bundle root; this single command covers syntax checks, both test suites (including
the Python `unittest discover` run), and the archive check:

```bash
bash tests/run-all.sh
```

The hooks suite alone (including its Python `unittest discover` run) can still be run in
isolation:

```bash
bash review-hooks/tests/run.sh
```
