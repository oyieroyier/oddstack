# Severity Rubric

Use severity to communicate merge risk, not personal preference.

## P0 - Critical blocker

Criteria:

- Direct path to severe data loss, irreversible corruption, credential exposure, broad tenant escape, remote code execution, or production outage.
- Exploit or failure is obvious or already reproducible.
- Requires immediate stop or rollback.

Action: Block immediately. Fix before any merge or deployment.

## P1 - Serious blocker

Criteria:

- Likely production bug affecting important user flows.
- Security/privacy authorization flaw with meaningful exposure.
- Migration/data integrity issue that can fail or corrupt real data.
- Major backward compatibility break.
- Reliability issue likely under normal load, retries, or concurrency.

Action: Block merge unless explicitly accepted by the user with mitigation.

## P2 - Real issue, bounded impact

Criteria:

- Concrete bug with limited scope or uncommon trigger.
- Maintainability problem likely to cause near-term mistakes.
- Missing test for meaningful behavior where implementation is otherwise plausible.
- UI/accessibility regression that affects a subset of users but is not catastrophic.

Action: Usually fix before merge; may defer with tracking if urgency is high and risk is understood.

## P3 - Minor or advisory

Criteria:

- Low-risk cleanup.
- Naming/readability issue.
- Minor test improvement.
- Edge case with uncertain impact.
- Documentation mismatch that does not affect runtime behavior.

Action: Do not block unless the user asked for polish or the issue compounds other risks.

## Not a finding

Do not report as a finding:

- Pure preference without project convention.
- Hypothetical issue with no trigger or impact.
- Request to rewrite working code solely for aesthetics.
- Missing tests for behavior unrelated to the change.
- "Could be better" comments without a concrete failure mode.
