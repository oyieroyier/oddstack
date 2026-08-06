"""Repository-owned durable intake for completed non-blocking findings."""

import time

from . import supervisor

# Policy-level cap on one updater run, applied inside the run deadline:
# long enough for a local generator, short enough that intake cannot eat
# a retry budget.
INTAKE_TIMEOUT_SECONDS = 60

# Bounds captured diagnostics only; output volume never fails the updater.
_OUTPUT_CAP_BYTES = 4096


class DurableIntakeError(Exception):
    """The configured intake updater could not record a decision."""


def record_merge_with_fixes(repo_root, environ, head, policy, deadline):
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
        "",
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
