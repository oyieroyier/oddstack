"""Decision-flow tests through the public review-gate command."""

import json
import os
import re
import time
import unittest

from gate_test_util import (
    BLOCKING_RESULT,
    GateTestCase,
    INCONCLUSIVE_RESULT,
    SAFE_RESULT,
    result_script,
)


class TestSafeFlow(GateTestCase):
    def test_preflight_then_verify_push_makes_one_call(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        review = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(review.returncode, 0, review.stderr)
        self.assertEqual(self.call_count(), 1)
        self.assertEqual(len(self.cache_entries()), 1)

        verify = self.run_gate(
            "check-push",
            "--updates-file", self.updates_file(head, base),
            "--mode", "verify",
        )
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self.assertEqual(self.call_count(), 1, "verify must not call the reviewer")
        self.assertIn("cache hit", verify.stdout)

    def test_verify_mode_without_decision_refuses_and_never_calls(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake, extra="AI_REVIEW_PUSH_MODE=verify\n")
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        verify = self.run_gate(
            "check-push", "--updates-file", self.updates_file(head, base)
        )
        self.assertEqual(verify.returncode, 2)
        self.assertEqual(self.call_count(), 0)
        self.assertIn("review --base", verify.stderr)
        record = self.latest_run_record()
        self.assertEqual(
            record["decision"]["reason_code"], "verify_no_decision"
        )

    def test_safe_run_writes_evidence_and_report(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["verdict"], "SAFE")
        self.assertEqual(record["base"], base)
        self.assertEqual(record["head"], head)
        self.assertIn("reviewer_identity", record)
        self.assertIn("prompt_digest", record)
        self.assertTrue(record["attempts"])
        run_dir = os.path.join(
            self.repo, "ai-reviews", "runs", record["run_id"]
        )
        for name in ("report.md", "attempt-1.json", "attempt-1.stdout",
                     "attempt-1.stderr"):
            self.assertTrue(
                os.path.exists(os.path.join(run_dir, name)), name
            )
        self.assertTrue(
            os.path.exists(os.path.join(self.repo, "ai-reviews", "latest.md"))
        )


class TestBlockingFlow(GateTestCase):
    def test_blocking_review_caches_and_binds_acknowledgement(self):
        fake = self.write_fake_bin(result_script(BLOCKING_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        first = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(first.returncode, 1, first.stderr)
        self.assertEqual(self.call_count(), 1)

        # A repeated push must not buy the same blocking answer again.
        repeat = self.run_gate(
            "check-push", "--updates-file", self.updates_file(head, base)
        )
        self.assertEqual(repeat.returncode, 1)
        self.assertEqual(self.call_count(), 1)

        # The free-text environment override must not work in version 2.
        env_override = self.run_gate(
            "check-push",
            "--updates-file", self.updates_file(head, base),
            env_extra={"AI_REVIEW_HUMAN_ACK": "exported forever"},
        )
        self.assertEqual(env_override.returncode, 1)

        # The gate prints the exact report to acknowledge; follow it.
        match = re.search(r"--report (\S+)", repeat.stderr)
        self.assertIsNotNone(match, repeat.stderr)
        report_path = match.group(1)

        ack = self.run_gate(
            "acknowledge", "--report", report_path, "--reason", "TICKET-42"
        )
        self.assertEqual(ack.returncode, 0, ack.stderr)

        accepted = self.run_gate(
            "check-push", "--updates-file", self.updates_file(head, base)
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(self.call_count(), 1)

        # The acknowledgement binds to that exact tree; new work re-blocks.
        head2 = self.commit_change("second.txt", "more\n", "Second")
        blocked_again = self.run_gate(
            "check-push", "--updates-file", self.updates_file(head2, base)
        )
        self.assertEqual(blocked_again.returncode, 1, blocked_again.stderr)
        self.assertEqual(self.call_count(), 2)

    def test_acknowledge_refuses_altered_report(self):
        fake = self.write_fake_bin(result_script(BLOCKING_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()
        self.run_gate("review", "--base", base, "--head", head)

        run_id = self.run_dirs()[-1]
        report_path = os.path.join(
            self.repo, "ai-reviews", "runs", run_id, "report.md"
        )
        with open(report_path, "a", encoding="utf-8") as handle:
            handle.write("\nedited after the fact\n")

        ack = self.run_gate(
            "acknowledge", "--report", report_path, "--reason", "TICKET-43"
        )
        self.assertEqual(ack.returncode, 2)
        self.assertIn("altered", ack.stderr)


class TestInconclusiveAndInvalid(GateTestCase):
    def test_inconclusive_verdict_never_caches(self):
        fake = self.write_fake_bin(result_script(INCONCLUSIVE_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.cache_entries(), [])
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["verdict"], "INCONCLUSIVE")

    def test_invalid_result_json_cannot_enter_cache(self):
        script = (
            "#!/usr/bin/env bash\n"
            "cat >/dev/null\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            "echo REVIEW-RESULT-BEGIN\n"
            "echo '{\"schema_version\": 1, \"verdict\": \"SAFE\"'\n"
            "echo REVIEW-RESULT-END\n"
        )
        fake = self.write_fake_bin(script)
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.cache_entries(), [])
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["reason_code"], "invalid_result")


class TestCacheKeyInputs(GateTestCase):
    def test_policy_prompt_or_model_change_misses_cache(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        self.assertEqual(
            self.run_gate("review", "--base", base, "--head", head).returncode, 0
        )
        self.assertEqual(self.call_count(), 1)

        # Same source, same policy: cache hit.
        self.assertEqual(
            self.run_gate("review", "--base", base, "--head", head).returncode, 0
        )
        self.assertEqual(self.call_count(), 1)

        # A policy change must miss.
        self.write_profile(
            fake, extra="AI_REVIEW_PRODUCT_NAME='another product'\n"
        )
        self.assertEqual(
            self.run_gate("review", "--base", base, "--head", head).returncode, 0
        )
        self.assertEqual(self.call_count(), 2)

        # A reviewer identity change must miss.
        self.write_profile(
            fake,
            extra=(
                "AI_REVIEW_PRODUCT_NAME='another product'\n"
                "AI_REVIEW_MODEL='different-model'\n"
            ),
        )
        self.assertEqual(
            self.run_gate("review", "--base", base, "--head", head).returncode, 0
        )
        self.assertEqual(self.call_count(), 3)

    def test_unnamed_model_refuses_paid_attempt(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake, extra="AI_REVIEW_MODEL=''\n")
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.call_count(), 0)
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["reason_code"], "model_unnamed")

    def test_model_flag_reaches_every_launch(self):
        prompt_copy = os.path.join(self.root, "argv-check")
        script = (
            "#!/usr/bin/env bash\n"
            "cat >/dev/null\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            'printf "%%s\\n" "$@" > "%s"\n'
            "echo REVIEW-RESULT-BEGIN\n"
            "echo '%s'\n"
            "echo REVIEW-RESULT-END\n"
        ) % (prompt_copy, json.dumps(SAFE_RESULT))
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra=(
            "AI_REVIEW_MAX_ATTEMPTS=2\n"
            "AI_REVIEW_RETRYABLE_FAILURES='startup_transport'\n"
            "AI_REVIEW_STARTUP_EXIT_CODES='7'\n"
            "AI_REVIEW_MAX_BUDGET_USD=2.00\n"
        ))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(prompt_copy, "r", encoding="utf-8") as handle:
            argv = handle.read().splitlines()
        self.assertIn("--model", argv)
        self.assertIn("test-model", argv)
        self.assertIn("--max-budget-usd", argv)
        # Attempt caps split the run cap; two reserved attempts on a
        # 2.00 budget give each launch a 1.00 cap.
        cap = argv[argv.index("--max-budget-usd") + 1]
        self.assertEqual(cap, "1.0000")


class TestRefusals(GateTestCase):
    def test_personal_quota_requires_opt_in(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake, extra="AI_REVIEW_CREDENTIAL_SCOPE=personal\n")
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        refused = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(refused.returncode, 2)
        self.assertEqual(self.call_count(), 0)
        record = self.latest_run_record()
        self.assertEqual(
            record["decision"]["reason_code"], "personal_quota_refused"
        )

        allowed = self.run_gate(
            "review", "--base", base, "--head", head,
            env_extra={"AI_REVIEW_ALLOW_PERSONAL_QUOTA": "1"},
        )
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(self.call_count(), 1)

    def test_sensitive_paths_are_refused_before_any_call(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change(".env", "SECRET=1\n", "Sensitive")

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.call_count(), 0)
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["reason_code"], "sensitive_paths")

    def test_multi_branch_push_is_refused(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake)
        head = self.commit_change()
        updates = os.path.join(self.root, "multi.txt")
        self.write_file(updates, (
            "refs/heads/main %s refs/heads/main %s\n"
            "refs/heads/other %s refs/heads/other %s\n"
        ) % (head, "0" * 40, head, "0" * 40))

        result = self.run_gate("check-push", "--updates-file", updates)
        self.assertEqual(result.returncode, 2)
        self.assertIn("one branch", result.stderr)
        self.assertEqual(self.call_count(), 0)
        record = self.latest_run_record()
        self.assertEqual(
            record["decision"]["reason_code"], "invalid_push_updates"
        )


class TestSkipBinding(GateTestCase):
    def test_skip_binds_to_exact_head(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake, extra="AI_REVIEW_PUSH_MODE=verify\n")
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        legacy_style = self.run_gate(
            "check-push",
            "--updates-file", self.updates_file(head, base),
            env_extra={
                "SKIP_AI_REVIEW": "1",
                "AI_REVIEW_HUMAN_ACK": "emergency",
            },
        )
        self.assertEqual(legacy_style.returncode, 2)

        bound = self.run_gate(
            "check-push",
            "--updates-file", self.updates_file(head, base),
            env_extra={
                "SKIP_AI_REVIEW": head[:12],
                "AI_REVIEW_HUMAN_ACK": "emergency TICKET-9",
            },
        )
        self.assertEqual(bound.returncode, 0, bound.stderr)
        self.assertEqual(self.call_count(), 0)
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["verdict"], "SKIPPED")

        # The same exported value must not skip the next push.
        head2 = self.commit_change("more.txt", "more\n", "More")
        stale = self.run_gate(
            "check-push",
            "--updates-file", self.updates_file(head2, base),
            env_extra={
                "SKIP_AI_REVIEW": head[:12],
                "AI_REVIEW_HUMAN_ACK": "emergency TICKET-9",
            },
        )
        self.assertEqual(stale.returncode, 2)


class TestSpendLedger(GateTestCase):
    def test_rolling_limit_refuses_paid_launch(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(
            fake,
            extra=(
                "AI_REVIEW_ROLLING_SPEND_LIMIT_USD=3.00\n"
                "AI_REVIEW_MAX_BUDGET_USD=2.00\n"
            ),
        )
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        first = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.call_count(), 1)

        ledger_path = os.path.join(
            self.repo, "ai-reviews", "spend", "ledger.jsonl"
        )
        self.assertTrue(os.path.exists(ledger_path))

        # A second distinct tree wants 2.00 more; 2.00 + 2.00 > 3.00.
        head2 = self.commit_change("more.txt", "more\n", "More")
        second = self.run_gate("review", "--base", base, "--head", head2)
        self.assertEqual(second.returncode, 2)
        self.assertEqual(self.call_count(), 1)
        record = self.latest_run_record()
        self.assertEqual(record["decision"]["reason_code"], "spend_limit")

    def test_attempt_caps_floor_so_their_sum_stays_under_the_run_cap(self):
        prompt_copy = os.path.join(self.root, "argv-floor-check")
        script = (
            "#!/usr/bin/env bash\n"
            "cat >/dev/null\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            'printf "%%s\\n" "$@" > "%s"\n'
            "echo REVIEW-RESULT-BEGIN\n"
            "echo '%s'\n"
            "echo REVIEW-RESULT-END\n"
        ) % (prompt_copy, json.dumps(SAFE_RESULT))
        fake = self.write_fake_bin(script)
        self.write_profile(fake, extra=(
            "AI_REVIEW_MAX_ATTEMPTS=2\n"
            "AI_REVIEW_RETRYABLE_FAILURES='startup_transport'\n"
            "AI_REVIEW_STARTUP_EXIT_CODES='7'\n"
            "AI_REVIEW_MAX_BUDGET_USD=2.0001\n"
        ))
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(prompt_copy, "r", encoding="utf-8") as handle:
            argv = handle.read().splitlines()
        cap = float(argv[argv.index("--max-budget-usd") + 1])
        self.assertLessEqual(cap * 2, 2.0001)

    def test_non_finite_budget_is_refused(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(
            fake, extra="AI_REVIEW_ROLLING_SPEND_LIMIT_USD=nan\n"
        )
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.call_count(), 0)

    def test_spend_is_reserved_before_launch_even_when_the_run_fails(self):
        script = (
            "#!/usr/bin/env bash\n"
            'echo "$$" >> "$FAKE_CALL_LOG"\n'
            "exit 9\n"
        )
        fake = self.write_fake_bin(script)
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 2)
        ledger_path = os.path.join(
            self.repo, "ai-reviews", "spend", "ledger.jsonl"
        )
        with open(ledger_path, "r", encoding="utf-8") as handle:
            entries = [json.loads(line) for line in handle if line.strip()]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["assigned_usd"], 2.0)

    def test_old_ledger_entries_age_out(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(
            fake,
            extra=(
                "AI_REVIEW_ROLLING_SPEND_LIMIT_USD=3.00\n"
                "AI_REVIEW_MAX_BUDGET_USD=2.00\n"
            ),
        )
        ledger_path = os.path.join(
            self.repo, "ai-reviews", "spend", "ledger.jsonl"
        )
        stale = {
            "timestamp": time.time() - 48 * 3600,
            "run_id": "old",
            "assigned_usd": 2.0,
            "actual_usd": None,
        }
        self.write_file(ledger_path, json.dumps(stale) + "\n")
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.call_count(), 1)


class TestIncrementalState(GateTestCase):
    def test_incremental_review_carries_open_findings(self):
        fake = self.write_fake_bin(result_script(BLOCKING_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head1 = self.commit_change()
        self.assertEqual(
            self.run_gate("review", "--base", base, "--head", head1).returncode,
            1,
        )

        prompt_copy = os.path.join(self.root, "prompt-copy.txt")
        head2 = self.commit_change("more.txt", "more\n", "More")
        result = self.run_gate(
            "review", "--base", base, "--head", head2,
            env_extra={"FAKE_PROMPT_COPY": prompt_copy},
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        record = self.latest_run_record()
        self.assertEqual(record["review_from"], head1)
        self.assertTrue(record["incremental"])
        self.assertEqual(record["prior_findings_count"], 1)
        with open(prompt_copy, "r", encoding="utf-8") as handle:
            prompt = handle.read()
        self.assertIn("Open findings", prompt)
        self.assertIn("test trigger", prompt)

    def test_reviewer_change_discards_incremental_state(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake)
        base = self.git_out("rev-parse", "HEAD")
        head1 = self.commit_change()
        self.assertEqual(
            self.run_gate("review", "--base", base, "--head", head1).returncode,
            0,
        )

        # A new reviewer must not inherit the old reviewer's coverage of
        # base..head1: the follow-up reviews the full range.
        self.write_profile(fake, extra="AI_REVIEW_MODEL='different-model'\n")
        head2 = self.commit_change("more.txt", "more\n", "More")
        result = self.run_gate("review", "--base", base, "--head", head2)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.latest_run_record()
        self.assertEqual(record["review_from"], base)
        self.assertFalse(record["incremental"])

    def test_damaged_state_is_ignored(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        self.write_profile(fake)
        self.write_file(
            os.path.join(self.repo, "ai-reviews", "state", "main.json"),
            "{not json",
        )
        base = self.git_out("rev-parse", "HEAD")
        head = self.commit_change()

        result = self.run_gate("review", "--base", base, "--head", head)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.latest_run_record()
        self.assertEqual(record["review_from"], base)
        self.assertFalse(record["incremental"])


class TestPolicyValidation(GateTestCase):
    def test_invalid_policy_values_refuse(self):
        fake = self.write_fake_bin(result_script(SAFE_RESULT))
        head = self.commit_change()
        base = self.git_out("rev-parse", "HEAD~1")

        cases = (
            "AI_REVIEW_MAX_ATTEMPTS=3\n",
            "AI_REVIEW_PUSH_MODE=maybe\n",
            "AI_REVIEW_RETRYABLE_FAILURES='anything_goes'\n",
            "AI_REVIEW_MAX_BUDGET_USD=0\n",
        )
        for extra in cases:
            self.write_profile(fake, extra=extra)
            result = self.run_gate("review", "--base", base, "--head", head)
            self.assertEqual(result.returncode, 2, extra)
            self.assertEqual(self.call_count(), 0, extra)


if __name__ == "__main__":
    unittest.main()
