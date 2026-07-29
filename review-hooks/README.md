# Collaboration review hooks

This optional module provides two Git hook adapters backed by one versioned profile:

```text
pre-commit → deterministic staged-change checks
pre-push   → configurable commands → bounded aggregate AI review
```

Installing the skills does not activate these hooks. Activation requires a separate, explicit
`review-hooks/install.sh` invocation.

The implementation requires Bash 4 or newer. AI review also requires `timeout` and `sha256sum`;
these are common on GNU/Linux but may need GNU coreutils on other platforms.

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
REVIEW_HOOKS_PROFILE_VERSION=1
```

Deterministic controls:

```bash
PRE_COMMIT_SECRET_SCAN=1
PRE_COMMIT_COMMANDS=''
PRE_PUSH_COMMANDS=''
```

Commands are newline-separated Bash commands executed from the repository root. Pre-commit
commands receive `REVIEW_HOOKS_STAGED_FILES_FILE`, a temporary newline-delimited list of staged
paths. Pre-push commands receive `REVIEW_HOOKS_PUSH_UPDATES_FILE`, which contains Git's pre-push
standard-input records.

AI-review controls:

```bash
AI_REVIEW_ENABLED=0
AI_REVIEW_PRODUCT_NAME='this repository'
AI_REVIEW_DEFAULT_BASE='origin/main'
AI_REVIEW_BACKEND_PATH_REGEX='^(api/|backend/|server/|db/|migrations/|sql/)'
AI_REVIEW_SENSITIVE_PATH_REGEX='...'
AI_REVIEW_SENSITIVE_PATH_ALLOW_REGEX='\.example$'
AI_REVIEW_TIMEOUT=600
AI_REVIEW_MAX_ATTEMPTS=2
AI_REVIEW_MAX_DIFF_LINES=3000
AI_REVIEW_MAX_BACKEND_DIFF_LINES=1200
AI_REVIEW_MAX_PROMPT_TOKENS=32000
AI_REVIEW_MAX_OUTPUT_BYTES=30000
AI_REVIEW_MAX_BUDGET_USD=2.00
```

The generic profile keeps AI review disabled. Enable it only after adapting repository naming, path
classification, sensitive-path rules, budgets, and credential ownership.

`profiles/lmm.example.conf` is a reference adapter for Sokko/Lipa Mdogo Mdogo. It is intentionally
not a portable default.

## AI-review behavior

When enabled, the pre-push gate:

- reviews one pushed branch at a time;
- reviews the aggregate remote-to-local diff rather than every commit;
- separates backend-owner paths from the general scope;
- refuses configured sensitive paths;
- bounds attempts, time, input, output, and spend;
- refuses implicit use of personal model quota;
- caches results by base commit and tree;
- carries a previous report into an incremental follow-up;
- records explicit human acknowledgements;
- reports infrastructure failures as `INCONCLUSIVE`.

Local personal quota requires a one-invocation opt-in:

```bash
AI_REVIEW_ALLOW_PERSONAL_QUOTA=1 git push
```

CI should set:

```bash
AI_REVIEW_CREDENTIAL_SCOPE=ci
```

Skipping review requires a recorded reason:

```bash
SKIP_AI_REVIEW=1 \
AI_REVIEW_HUMAN_ACK="<ticket or reason>" \
git push
```

Review reports and cache state are written to `ai-reviews/`. Add that directory to the target
repository's ignore rules unless the repository deliberately versions review evidence.

## Deactivate

```bash
review-hooks/install.sh \
  --repo /path/to/repository \
  --deactivate
```

Deactivation restores the previous `core.hooksPath` when one was replaced. Installed files remain
so their removal can be reviewed and committed normally.

## Verify

```bash
bash -n review-hooks/install.sh
bash -n review-hooks/hooks/*
bash -n review-hooks/scripts/*.sh
review-hooks/tests/run.sh
```
