"""Repository-owned durable intake for completed non-blocking findings.

The updater receives the parsed result on stdin as JSON. Intake runs before
evidence is finalized, so the run's report does not exist yet and the
payload is the only thing a generator can preserve. Raw reviewer text never
enters it: the harness does not copy untrusted model prose, and every field
below is schema-validated by `results.py`.
"""

import json
import time

from . import supervisor

# Policy-level cap on one updater run, applied inside the run deadline:
# long enough for a local generator, short enough that intake cannot eat
# a retry budget.
INTAKE_TIMEOUT_SECONDS = 60

# Bounds captured diagnostics only; output volume never fails the updater.
_OUTPUT_CAP_BYTES = 4096

PAYLOAD_SCHEMA_VERSION = 1


class DurableIntakeError(Exception):
    """The configured intake updater could not record a decision."""


def build_payload(head, result, *, run_id, started_utc, base):
    """Render the complete validated result for one intake run.

    Reviewer stdout is already bounded by policy. Intake must not apply the
    unrelated prior-report limit and silently omit accepted findings.
    """
    payload = {
        "payload_schema_version": PAYLOAD_SCHEMA_VERSION,
        "run_id": run_id,
        "started_utc": started_utc,
        "base": base,
        "head": head,
        "verdict": result.verdict,
        "risk_class": result.risk_class,
        "findings": list(result.findings),
        "limitations": result.limitations,
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def record_merge_with_fixes(
    repo_root, environ, head, result, policy, deadline, *,
    run_id, started_utc, base
):
    """Run the profile-owned updater for one fresh MERGE-WITH-FIXES decision.

    Raises DurableIntakeError unless the updater completes cleanly inside
    both the intake cap and the remaining run deadline.
    """
    now = time.monotonic()
    if now >= deadline:
        raise DurableIntakeError(
            "the run deadline expired before durable intake"
        )

    updater_env = dict(environ)
    # CATALOG_COMMIT is the documented version-2 name. Keep exporting it
    # while newer consumers migrate to the more explicit variable.
    updater_env["CATALOG_COMMIT"] = head
    updater_env["AI_REVIEW_HEAD_COMMIT"] = head
    outcome = supervisor.run_attempt(
        ["bash", "-o", "pipefail", "-c",
         policy.merge_with_fixes_command.strip()],
        build_payload(
            head, result, run_id=run_id,
            started_utc=started_utc, base=base,
        ),
        min(deadline, now + INTAKE_TIMEOUT_SECONDS),
        stdout_cap=_OUTPUT_CAP_BYTES,
        stderr_cap=_OUTPUT_CAP_BYTES,
        kill_grace=policy.kill_grace,
        environ=updater_env,
        cwd=repo_root,
        stop_on_overflow=False,
    )
    if not outcome.completed_cleanly:
        reason = "updater %s" % outcome.failure_summary()
        output = outcome.stderr_data or outcome.stdout_data
        detail = output.decode("utf-8", errors="replace").strip()
        if detail:
            reason += ": %s" % detail[:1000]
        raise DurableIntakeError(reason)
