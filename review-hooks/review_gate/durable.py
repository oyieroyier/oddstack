"""Repository-owned durable intake for completed non-blocking findings."""

from . import supervisor


class DurableIntakeError(Exception):
    """The configured intake updater could not record a decision."""


def record_merge_with_fixes(
    repo_root, environ, head, command, deadline, kill_grace
):
    """Run the profile-owned updater for one fresh MERGE-WITH-FIXES decision."""
    command = command.strip()
    if not command:
        return False

    updater_env = dict(environ)
    updater_env["CATALOG_COMMIT"] = head
    outcome = supervisor.run_attempt(
        ["bash", "-o", "pipefail", "-c", command],
        "",
        deadline,
        stdout_cap=4096,
        stderr_cap=4096,
        kill_grace=kill_grace,
        environ=updater_env,
        cwd=repo_root,
    )
    completed = (
        outcome.started
        and outcome.exit_code == 0
        and outcome.cleanup_verified
        and not outcome.overflow
        and not outcome.timed_out
        and not outcome.interrupted
    )
    if not completed:
        output = outcome.stderr_data or outcome.stdout_data
        detail = output.decode("utf-8", errors="replace").strip()
        if outcome.timed_out:
            reason = "updater timed out"
        elif not outcome.cleanup_verified:
            reason = "updater cleanup could not be verified"
        elif outcome.launch_error:
            reason = "updater launch failed: %s" % outcome.launch_error
        else:
            reason = "updater exited %s" % outcome.exit_code
        if detail:
            reason += ": %s" % detail[:1000]
        raise DurableIntakeError(reason)
    return True
