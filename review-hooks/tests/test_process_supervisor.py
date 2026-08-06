"""Process-supervision tests through the public review-gate command.

Each test uses a fake reviewer executable with deliberate misbehavior and
proves the run stays inside its time, output, and process-group bounds.
"""

import json
import os
import signal
import subprocess
import time
import unittest

from gate_test_util import (
    GateTestCase,
    MERGE_WITH_FIXES_RESULT,
    REVIEW_GATE,
    SAFE_RESULT,
    cli_envelope,
    result_script,
)

_SLACK = 2.0


def _pid_dead(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def _wait_dead(pid, deadline_seconds=5.0):
    end = time.monotonic() + deadline_seconds
    while time.monotonic() < end:
        if _pid_dead(pid):
            return True
        time.sleep(0.05)
    return _pid_dead(pid)


class TestTimeoutBounds(GateTestCase):
    def test_timeout_gets_one_attempt_and_bounded_wall_time(self):
        script = (
            "#!/usr/bin/env bash\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            "cat >/dev/null\n"
            "sleep 60\n"
        )
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra=(
            "AI_REVIEW_TOTAL_TIMEOUT=2\n"
            "AI_REVIEW_KILL_GRACE=1\n"
            "AI_REVIEW_MAX_ATTEMPTS=2\n"
            "AI_REVIEW_RETRYABLE_FAILURES='startup_transport'\n"
            "AI_REVIEW_STARTUP_EXIT_CODES='7'\n"
        ))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        started = time.monotonic()
        result = self.run_gate("review", "--base", base, "--head", head)
        elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 2)
        self.assertLess(elapsed, 2 + 1 + _SLACK)
        self.assertEqual(self.call_count(), 1, "timeout must not retry")
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["reason_code"], "timeout")
        self.assertTrue(record["attempts"][0]["timed_out"])


class TestSigtermResistance(GateTestCase):
    def test_reviewer_and_nested_child_ignoring_sigterm_are_reaped(self):
        parent_pid_file = os.path.join(self.root, "parent.pid")
        child_pid_file = os.path.join(self.root, "child.pid")
        script = (
            "#!/usr/bin/env bash\n"
            "trap '' TERM\n"
            'echo "$$" > "%s"\n'
            "cat >/dev/null\n"
            "( trap '' TERM; echo \"$BASHPID\" > \"%s\"; sleep 120 ) &\n"
            "sleep 120\n"
        ) % (parent_pid_file, child_pid_file)
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra=(
            "AI_REVIEW_TOTAL_TIMEOUT=2\n"
            "AI_REVIEW_KILL_GRACE=1\n"
        ))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)

        for pid_file in (parent_pid_file, child_pid_file):
            self.assertTrue(os.path.exists(pid_file), pid_file)
            with open(pid_file, "r", encoding="utf-8") as handle:
                pid = int(handle.read().strip())
            self.assertTrue(
                _wait_dead(pid), "process %d survived the gate" % pid
            )
        record = self.latest_run_record()
        self.assertTrue(record["attempts"][0]["cleanup_verified"])

    def test_durable_updater_and_nested_child_are_reaped(self):
        parent_pid_file = os.path.join(self.root, "durable-parent.pid")
        child_pid_file = os.path.join(self.root, "durable-child.pid")
        updater = self.write_fake_bin(
            (
                "#!/usr/bin/env bash\n"
                "trap '' TERM\n"
                'echo "$$" > "%s"\n'
                "( trap '' TERM; echo \"$BASHPID\" > \"%s\"; sleep 120 ) &\n"
                "wait\n"
            ) % (parent_pid_file, child_pid_file),
            name="durable-updater",
        )
        fake = self.write_fake_bin(result_script(MERGE_WITH_FIXES_RESULT))
        self.write_profile(
            fake,
            extra=(
                "AI_REVIEW_TOTAL_TIMEOUT=2\n"
                "AI_REVIEW_KILL_GRACE=1\n"
                "AI_REVIEW_MERGE_WITH_FIXES_COMMAND='%s'\n" % updater
            ),
        )
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)

        self.assertEqual(result.returncode, 2)
        for pid_file in (parent_pid_file, child_pid_file):
            self.assertTrue(os.path.exists(pid_file), pid_file)
            with open(pid_file, "r", encoding="utf-8") as handle:
                pid = int(handle.read().strip())
            self.assertTrue(
                _wait_dead(pid), "durable updater process %d survived" % pid
            )
        record = self.latest_run_record()
        self.assertEqual(
            record["decision"]["reason_code"], "durable_intake_failed"
        )
        self.assertEqual(
            record["reviewer_decision"]["verdict"], "MERGE-WITH-FIXES"
        )
        latest_path = os.path.join(self.repo, "ai-reviews", "latest.md")
        with open(latest_path, "r", encoding="utf-8") as handle:
            self.assertIn("Decision: **INCONCLUSIVE**", handle.read())


class TestOutputFlood(GateTestCase):
    def test_output_flood_ends_the_run_without_a_second_attempt(self):
        script = (
            "#!/usr/bin/env bash\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            "cat >/dev/null\n"
            "while true; do printf 'flood%.0s' {1..8192}; done\n"
        )
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra=(
            "AI_REVIEW_MAX_OUTPUT_BYTES=20000\n"
            "AI_REVIEW_MAX_ATTEMPTS=2\n"
            "AI_REVIEW_RETRYABLE_FAILURES='startup_transport'\n"
            "AI_REVIEW_STARTUP_EXIT_CODES='7'\n"
        ))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.call_count(), 1, "a flood must not retry")
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["reason_code"], "output_overflow")
        self.assertTrue(record["attempts"][0]["overflow"])
        self.assertTrue(record["attempts"][0]["stdout_truncated"])


class TestStderrFlood(GateTestCase):
    def test_stderr_flood_cannot_bypass_the_output_cap(self):
        script = (
            "#!/usr/bin/env bash\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            "cat >/dev/null\n"
            "while true; do printf 'flood%.0s' {1..8192} >&2; done\n"
        )
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra=(
            "AI_REVIEW_MAX_OUTPUT_BYTES=20000\n"
            "AI_REVIEW_TOTAL_TIMEOUT=20\n"
        ))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        started = time.monotonic()
        result = self.run_gate("review", "--base", base, "--head", head)
        elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 2)
        self.assertLess(elapsed, 15, "stderr flood must end early, not at timeout")
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["reason_code"], "output_overflow")


class TestStartupRetry(GateTestCase):
    def test_declared_startup_failure_retries_once_then_succeeds(self):
        marker = os.path.join(self.root, "first-call-done")
        script = (
            "#!/usr/bin/env bash\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            "if [ ! -e \"%s\" ]; then\n"
            "  touch \"%s\"\n"
            "  exit 7\n"
            "fi\n"
            "cat >/dev/null\n"
            "cat <<'ENVELOPE'\n"
            "%s\n"
            "ENVELOPE\n"
        ) % (marker, marker, cli_envelope(
            "REVIEW-RESULT-BEGIN\n%s\nREVIEW-RESULT-END"
            % json.dumps(SAFE_RESULT)
        ))
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra=(
            "AI_REVIEW_MAX_ATTEMPTS=2\n"
            "AI_REVIEW_RETRYABLE_FAILURES='startup_transport'\n"
            "AI_REVIEW_STARTUP_EXIT_CODES='7'\n"
            "AI_REVIEW_MIN_RETRY_TIME=5\n"
        ))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.call_count(), 2)
        record = self.latest_run_record()
        self.assertEqual(len(record["attempts"]), 2)
        self.assertEqual(
            record["attempts"][0]["reason_code"], "startup_transport"
        )
        self.assertEqual(record["attempts"][1]["reason_code"], "completed")

    def test_undeclared_exit_code_never_retries(self):
        script = (
            "#!/usr/bin/env bash\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            "exit 9\n"
        )
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra=(
            "AI_REVIEW_MAX_ATTEMPTS=2\n"
            "AI_REVIEW_RETRYABLE_FAILURES='startup_transport'\n"
            "AI_REVIEW_STARTUP_EXIT_CODES='7'\n"
        ))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.call_count(), 1)
        record = self.latest_run_record()
        self.assertEqual(
            record["decision"]["reason_code"], "unknown_infrastructure"
        )


class TestMissingExecutable(GateTestCase):
    def test_missing_cli_writes_evidence(self):
        self.write_profile(os.path.join(self.root, "does-not-exist"))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["reason_code"], "missing_cli")
        self.assertFalse(record["attempts"][0]["started"])


class TestLingeringDescendant(GateTestCase):
    def test_child_exit_with_descendant_holding_stdout_still_completes(self):
        script = (
            "#!/usr/bin/env bash\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            "cat >/dev/null\n"
            "(\n"
            "  sleep 1\n"
            "  cat <<'ENVELOPE'\n"
            "%s\n"
            "ENVELOPE\n"
            ") &\n"
            "exit 0\n"
        ) % cli_envelope(
            "REVIEW-RESULT-BEGIN\n%s\nREVIEW-RESULT-END"
            % json.dumps(SAFE_RESULT)
        )
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra="AI_REVIEW_TOTAL_TIMEOUT=10\n")
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["verdict"], "SAFE")


class TestCleanupFault(GateTestCase):
    def test_unproven_cleanup_is_inconclusive(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate(
            "review", "--base", base, "--head", head,
            env_extra={"REVIEW_GATE_TEST_CLEANUP_FAULT": "1"},
        )
        self.assertEqual(result.returncode, 2)
        record = self.latest_run_record()
        self.assertEqual(
            record["decision"]["reason_code"], "cleanup_unverified"
        )
        self.assertEqual(self.cache_entries(), [])


class TestInterruption(GateTestCase):
    def test_interrupt_reaps_the_reviewer_and_writes_evidence(self):
        started_marker = os.path.join(self.root, "reviewer-started")
        pid_file = os.path.join(self.root, "reviewer.pid")
        script = (
            "#!/usr/bin/env bash\n"
            'echo "$$" > "%s"\n'
            'touch "%s"\n'
            "cat >/dev/null\n"
            "sleep 120\n"
        ) % (pid_file, started_marker)
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra=(
            "AI_REVIEW_TOTAL_TIMEOUT=60\n"
            "AI_REVIEW_KILL_GRACE=1\n"
        ))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        env = dict(os.environ)
        env.update(self.base_env)
        proc = subprocess.Popen(
            [REVIEW_GATE, "review", "--base", base, "--head", head],
            cwd=self.repo,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 20
            while not os.path.exists(started_marker):
                self.assertLess(
                    time.monotonic(), deadline, "reviewer never started"
                )
                time.sleep(0.05)
            os.killpg(proc.pid, signal.SIGINT)
            proc.wait(timeout=30)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=10)
            proc.stdout.close()
            proc.stderr.close()

        self.assertEqual(proc.returncode, 2)
        with open(pid_file, "r", encoding="utf-8") as handle:
            reviewer_pid = int(handle.read().strip())
        self.assertTrue(_wait_dead(reviewer_pid))
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["reason_code"], "interrupted")


if __name__ == "__main__":
    unittest.main()
