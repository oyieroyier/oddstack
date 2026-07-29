---
name: setup-collaboration-hooks
description: Safely install, adapt, verify, or deactivate the optional deterministic pre-commit and bounded AI pre-push review hooks bundled under review-hooks/. Use when a user asks to add the collaboration hooks, configure aggregate AI review, compose with an existing hook system, or remove this bundle's hook activation.
---

# Set up collaboration hooks

Install the optional hook module without silently replacing repository policy.

## Rules

1. Read the target repository's agent guidance and `review-hooks/README.md`.
2. Inspect `git status --short`, `git diff --stat`, `git diff --name-only`, and the local
   `core.hooksPath`.
3. Treat `.review-hooks.conf` as executable repository policy.
4. Never activate hooks merely because this skill or the skill bundle was installed.
5. Require an explicit user request before changing `core.hooksPath`.
6. Refuse unrelated dirty work and preserve existing hook systems by default.
7. Prefer `--no-activate` plus explicit composition when Husky, Lefthook, or another hook path
   already exists.
8. Never enable AI review until repository naming, path classification, sensitive paths, credential
   ownership, and budgets have been reviewed.
9. Never consume personal model quota implicitly.
10. Verify hook syntax and run the bundled fixture tests before reporting completion.

## Install or update

Start with a dry run:

```bash
review-hooks/install.sh \
  --repo "$PWD" \
  --profile generic \
  --dry-run
```

If the repository has no hook conflict and the user authorized activation:

```bash
review-hooks/install.sh \
  --repo "$PWD" \
  --profile generic
```

Use `--force` only after inspecting an existing installation. Use `--replace-hooks-path` only when
the user explicitly chose replacement after seeing the exact current path.

Adapt `.review-hooks.conf`, then validate:

```bash
bash -n .review-hooks.conf
bash -n .collaboration-hooks/*
bash -n .review-hooks/scripts/*.sh
git config --local --get core.hooksPath
```

## Compose

When another hook system exists, install with `--no-activate`. Add calls to the deep scripts from
the existing hook adapter. Preserve and replay pre-push standard input when more than one consumer
needs it.

## Deactivate

Use the bundled deactivation interface. It restores the path recorded during installation and
preserves installed files:

```bash
review-hooks/install.sh --repo "$PWD" --deactivate
```

Report the active hook path, installed or retained files, selected profile, checks run, and whether
AI review is enabled.
