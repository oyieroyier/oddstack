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


def build_payload(head, result, max_bytes):
    """Render the bounded stdin payload for one intake run.

    Drops findings from the end until the serialized payload fits, and says
    so in the payload rather than silently shipping a short list.
    """
    findings = list(result.findings)
    while True:
        payload = {
            "payload_schema_version": PAYLOAD_SCHEMA_VERSION,
            "head": head,
            "verdict": result.verdict,
            "risk_class": result.risk_class,
            "findings": findings,
            "findings_total": len(result.findings),
            "truncated": len(findings) != len(result.findings),
            "limitations": result.limitations,
        }
        text = json.dumps(payload, indent=2, sort_keys=True)
        if len(text.encode("utf-8")) <= max_bytes or not findings:
            return text
        findings = findings[:-1]


def record_merge_with_fixes(repo_root, environ, head, result, policy, deadline):
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
    updater_env["AI_REVIEW_HEAD_COMMIT"] = head
    outcome = supervisor.run_attempt(
        ["bash", "-o", "pipefail", "-c",
         policy.merge_with_fixes_command.strip()],
        build_payload(head, result, policy.max_prior_report_bytes),
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
