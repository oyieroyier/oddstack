# Adversarial Review Guide

This guide defines the behavior expected from a strict review.

## What adversarial means

Adversarial does not mean rude. It means the reviewer is optimized for finding defects that the author missed.

The reviewer should:

- Challenge assumptions.
- Follow data and control flow across files.
- Search for callers and downstream effects.
- Test edge cases mentally or with read-only commands.
- Prefer one confirmed serious finding over ten style comments.
- State uncertainty precisely.

The reviewer should not:

- Rubber-stamp a patch.
- Praise the author before investigating.
- Suggest broad rewrites without evidence.
- Report speculative issues as facts.
- Ignore evidence that disproves a suspected issue.

## Null-result discipline

A "PASS" must include real review work. It should say what was checked, for example:

- Diff inspected with context.
- Relevant call sites searched.
- Tests inspected for old-behavior failure.
- Migration or schema compatibility checked.
- Auth/permission boundary checked.
- UI states or accessibility states checked.

A pass with large coverage gaps should usually be `CAUTION`, not `PASS`.

## Finding quality bar

A finding is worth reporting when it includes:

1. Evidence: file, line, diff hunk, command output, or concrete plan step.
2. Failure mode: what goes wrong.
3. Trigger: how a user, request, state, race, environment, or data shape causes it.
4. Impact: who or what is affected.
5. Fix direction: the smallest credible fix or mitigation.

Weak finding:

> This may have edge cases.

Strong finding:

> `src/billing/applyCoupon.ts:88` trusts `req.body.accountId` instead of deriving the account from the session. A user can submit another account ID and apply their coupon to a different tenant. Existing tests only cover the happy path with matching IDs. Derive account ID from the authenticated session and add a cross-tenant rejection test.

## Review tactics

Use targeted searches:

```bash
rg "functionName|ClassName|routeName" .
rg "TODO|FIXME|deprecated|unsafe|admin|tenant|permission|auth" relevant/path
rg "process\.env|localStorage|sessionStorage|eval\(|exec\(|spawn\(" .
```

For changed APIs, search all call sites. For changed data, inspect migrations, serializers, deserializers, seed data, fixtures, and tests. For UI changes, inspect component states and CSS boundaries.

## Common false confidence traps

- A test passes because it mocks away the broken integration.
- A type compiles because a cast suppresses the error.
- A retry loop duplicates side effects.
- A migration works on empty dev data but fails on real nullable or duplicate rows.
- A UI screenshot covers only desktop happy path.
- A security check validates authentication but not authorization.
- A cache fix updates writes but not invalidation.
- A refactor preserves unit tests but changes public semantics.
- A fallback path handles errors by hiding them.

## Final adjudication by Claude

Claude must verify Codex's review findings before presenting them. Classify each as:

- Confirmed: evidence supports it.
- Likely: strong evidence, but reproduction not complete.
- Needs investigation: plausible but missing key evidence.
- Rejected: false positive; explain why.

Do not pass through raw Codex output unexamined.
