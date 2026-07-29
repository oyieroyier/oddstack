# Validation and Handoff Checklist

Use this after Codex returns from an implementation run.

## Evidence-before-claim gate

Before saying that work is fixed, complete, passing, or ready:

1. Identify the command or observation that proves the specific claim.
2. Run that check fresh against the current working tree.
3. Read the complete relevant output and exit status.
4. Compare the evidence with the claim; report the actual state when they disagree.
5. Only then state the result, naming the check that supports it.

Delegated-agent summaries, earlier runs, partial checks, and a clean-looking diff are leads, not
proof. Apply this gate before committing, pushing, opening a pull request, or returning control.

## Diff inspection

Run:

```bash
git status --short
git diff --stat
git diff --cached --stat
git diff --check
git diff --cached --check
git ls-files --others --exclude-standard
```

Then inspect the full staged and unstaged diffs and open every untracked file. Confirm:

- The changed files match the requested scope.
- No unrelated files, generated files, credentials, caches, or local-only configs were changed.
- The implementation is not just a superficial workaround.
- Error handling still preserves useful failures.
- Tests were added or updated where the risk justifies them.
- New comments are accurate and not aspirational.
- Lockfile changes correspond to intentional dependency changes.

## Behavior checks

Ask these questions before accepting the patch:

- Does the patch address the root cause, not only the observed symptom?
- What happens with empty input, malformed input, very large input, duplicate input, concurrent calls, and retries?
- Does the change affect auth, permissions, privacy, billing, migrations, or destructive operations?
- Are existing call sites still compatible?
- Are serialization formats, environment variables, route names, CLI flags, and public types still stable?
- Does a test fail on the old behavior and pass on the new behavior?

## Command validation

Prefer project-native commands. Examples:

```bash
npm test
npm run lint
npm run typecheck
pnpm test
pytest -q
ruff check .
cargo test
go test ./...
```

If the full suite is too expensive, run targeted tests and explain the limitation. If no tests exist, use direct execution, static inspection, or a small smoke test.

## Handoff summary format

Use this format in your final message:

```markdown
Implemented via Codex, then reviewed by Claude.

Changed:

- `path/to/file`: [what changed]
- `path/to/test`: [test coverage]

Verified:

- `command`: passed/failed/skipped with reason

Notes:

- [Remaining risk or limitation]
```

Never say "all tests pass" unless fresh, complete command output shows that.
