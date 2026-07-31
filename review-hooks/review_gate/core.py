"""Gate orchestration.

One decision per invocation: exit 0 (accepted), 1 (completed review with
blocking findings), or 2 (no trustworthy decision).
"""

import math
import os
import sys
import time

from . import evidence, gitwork, prompts, results, store, supervisor
from .adapter import ClaudeAdapter
from .gitwork import ReviewTarget, TargetError
from .policy import PolicyError
from .prompts import PromptError, SensitivePathError
from .results import ResultError

EXIT_ACCEPT = 0
EXIT_BLOCKING = 1
EXIT_INCONCLUSIVE = 2

_SKIP_MIN_PREFIX = 12


def info(message):
    print("[review-gate] %s" % message)


def error(message):
    print("[review-gate] %s" % message, file=sys.stderr)


class Gate:
    def __init__(self, repo_root, policy, environ):
        self.repo_root = repo_root
        self.policy = policy
        self.environ = environ
        self.adapter = ClaudeAdapter(policy)
        self.cache = store.DecisionCache(repo_root)
        self.legacy_cache = store.LegacyCache(repo_root)
        self.state = store.BranchState(repo_root)
        self.ledger = store.SpendLedger(repo_root)
        self.acks = store.AckStore(repo_root)

    # ----- public commands -------------------------------------------------

    def check_push(self, updates_path, mode_override=None):
        try:
            with open(updates_path, "r", encoding="utf-8") as handle:
                updates_text = handle.read()
        except OSError as err:
            error("INCONCLUSIVE: cannot read push updates: %s" % err)
            return EXIT_INCONCLUSIVE

        try:
            update = gitwork.parse_push_updates(updates_text)
        except TargetError as err:
            self._write_refusal_evidence("check-push", "invalid_push_updates", str(err))
            error("INCONCLUSIVE: %s" % err)
            return EXIT_INCONCLUSIVE
        if update is None:
            info("no branch update to review")
            return EXIT_ACCEPT

        local_ref, local_sha, _remote_ref, remote_sha = update
        base = gitwork.resolve_base(
            self.repo_root, self.policy, local_sha, remote_sha
        )
        if base is None:
            detail = (
                "no trustworthy review base: the remote ref is new and %s "
                "does not resolve locally; fetch it or set "
                "AI_REVIEW_DEFAULT_BASE" % self.policy.default_base
            )
            self._write_refusal_evidence(
                "check-push", "unresolvable_base", detail
            )
            error("INCONCLUSIVE: %s" % detail)
            return EXIT_INCONCLUSIVE
        try:
            target = gitwork.resolve_target(
                self.repo_root, self.policy, base, local_sha, local_ref
            )
        except TargetError as err:
            self._write_refusal_evidence("check-push", "invalid_target", str(err))
            error("INCONCLUSIVE: %s" % err)
            return EXIT_INCONCLUSIVE

        if not gitwork.diff_text(self.repo_root, target.base, target.head):
            info("no diff vs %s; skipping" % target.base)
            return EXIT_ACCEPT

        mode = mode_override or self.policy.push_mode
        return self._decide(target, mode=mode, allow_skip=True)

    def review(self, base, head, local_ref):
        head = head or "HEAD"
        if not base:
            base = gitwork.upstream_sha(self.repo_root)
        try:
            head_sha = gitwork.run_git(
                self.repo_root, ["rev-parse", "%s^{commit}" % head]
            )
            if not base:
                base = gitwork.resolve_base(
                    self.repo_root, self.policy, head_sha, None
                )
            if not base:
                detail = (
                    "no trustworthy review base: no upstream and %s does "
                    "not resolve; pass --base explicitly"
                    % self.policy.default_base
                )
                self._write_refusal_evidence(
                    "review", "unresolvable_base", detail
                )
                error("INCONCLUSIVE: %s" % detail)
                return EXIT_INCONCLUSIVE
            target = gitwork.resolve_target(
                self.repo_root,
                self.policy,
                base,
                head_sha,
                local_ref or gitwork.current_local_ref(self.repo_root),
            )
        except TargetError as err:
            error("INCONCLUSIVE: %s" % err)
            return EXIT_INCONCLUSIVE

        if not gitwork.diff_text(self.repo_root, target.base, target.head):
            info("no diff vs %s; nothing to review" % target.base)
            return EXIT_ACCEPT

        return self._decide(target, mode="run", allow_skip=False)

    def acknowledge(self, report_path, reason):
        if not reason or not reason.strip():
            error("INCONCLUSIVE: an acknowledgement needs a ticket or reason")
            return EXIT_INCONCLUSIVE
        run_json = os.path.join(os.path.dirname(report_path), "run.json")
        record = store._load_json(run_json)
        if not isinstance(record, dict):
            error("INCONCLUSIVE: no run.json next to %s" % report_path)
            return EXIT_INCONCLUSIVE
        try:
            current_digest = store.sha256_file(report_path)
        except OSError as err:
            error("INCONCLUSIVE: cannot read report: %s" % err)
            return EXIT_INCONCLUSIVE
        if record.get("report_digest") != current_digest:
            error(
                "INCONCLUSIVE: report does not match its run record; "
                "refusing to acknowledge an altered report"
            )
            return EXIT_INCONCLUSIVE
        decision = record.get("decision") or {}
        required = (
            record.get("base"),
            record.get("tree"),
            decision.get("risk_class"),
            record.get("policy_hash"),
        )
        if not all(required):
            error(
                "INCONCLUSIVE: run record lacks base, tree, risk class, "
                "or policy hash; only a completed review can be acknowledged"
            )
            return EXIT_INCONCLUSIVE
        digest = store.ack_digest(current_digest, *required)
        path = self.acks.write(digest, {
            "created_utc": evidence.utc_now_iso(),
            "reason": reason,
            "report_path": os.path.abspath(report_path),
            "report_digest": current_digest,
            "base": record["base"],
            "tree": record["tree"],
            "risk_class": decision["risk_class"],
            "policy_hash": record["policy_hash"],
        })
        info("acknowledgement recorded at %s" % path)
        info("it accepts only this exact report, base, tree, and policy")
        return EXIT_ACCEPT

    # ----- decision flow ---------------------------------------------------

    def _write_refusal_evidence(self, invocation, reason_code, detail):
        ev = evidence.RunEvidence(self.repo_root, invocation)
        ev.finalize(
            {"decision": {"reason_code": reason_code}},
            ev.render_failure_report(None, reason_code, detail),
        )

    def _decide(self, target, mode, allow_skip):
        identity = self.adapter.identity()
        policy_hash = self.policy.policy_hash()
        key = store.cache_key(
            target.base,
            target.tree,
            policy_hash,
            self.policy.prompt_template_version,
            identity,
        )

        cached = self._load_intact_cache_entry(key, target, policy_hash, identity)
        if cached is not None:
            return self._apply_cached(cached, target, policy_hash, key)

        if self.policy.profile_version == 1:
            legacy = self.legacy_cache.load(target.base, target.tree)
            if legacy is not None:
                return self._apply_legacy_cached(legacy, target)

        if allow_skip and self.environ.get("SKIP_AI_REVIEW", "") not in ("", "0"):
            return self._apply_skip(target, policy_hash, identity)

        if mode == "verify":
            return self._verify_miss(target, policy_hash, identity, key)

        return self._run_paid_review(target, policy_hash, identity, key)

    def _load_intact_cache_entry(self, key, target, policy_hash, identity):
        """Load a cache entry and prove its internal consistency.

        The cache is local state. These checks defend against staleness,
        copied entries, and accidental edits — a local writer who can
        forge a whole consistent entry could equally skip or disable the
        gate, so authentication stops at consistency.
        """
        entry = self.cache.load(key)
        if entry is None:
            return None
        bound = (
            entry.get("base") == target.base
            and entry.get("tree") == target.tree
            and entry.get("policy_hash") == policy_hash
            and entry.get("prompt_template_version")
            == self.policy.prompt_template_version
            and entry.get("reviewer_identity") == identity
        )
        if not bound:
            info("cache entry does not bind to this target; ignoring it")
            return None
        # Blocking is derived, never trusted from a stored flag.
        must_fix = entry.get("must_fix_count")
        if not isinstance(must_fix, int) or isinstance(must_fix, bool):
            info("cache entry lacks a finding count; ignoring it")
            return None
        entry["blocking"] = (
            entry["verdict"] == "DO-NOT-MERGE" or must_fix > 0
        )
        report_path = entry.get("report_path", "")
        runs_root = os.path.realpath(
            os.path.join(store.out_dir(self.repo_root), "runs")
        )
        if not os.path.realpath(report_path).startswith(runs_root + os.sep):
            info("cached report lives outside the evidence store; ignoring it")
            return None
        try:
            if store.sha256_file(report_path) != entry.get("report_digest"):
                info("cached report was altered; ignoring the cache entry")
                return None
        except OSError:
            info("cached report is missing; ignoring the cache entry")
            return None
        return entry

    def _apply_cached(self, entry, target, policy_hash, key):
        ev = evidence.RunEvidence(self.repo_root, "cache")
        blocking = bool(entry.get("blocking"))
        body_lines = [
            "Decision: **%s** (from decision cache)" % entry["verdict"],
            "",
            "Cache key: `%s`" % key,
            "Original run: `%s`" % entry.get("run_id", "unknown"),
            "Original report: `%s`" % entry.get("report_path", ""),
            "",
        ]
        record = {
            "base": target.base,
            "head": target.head,
            "tree": target.tree,
            "local_ref": target.local_ref,
            "branch": target.branch,
            "policy_hash": policy_hash,
            "cache_hit": key,
            "decision": {
                "verdict": entry["verdict"],
                "blocking": blocking,
                "risk_class": entry.get("risk_class", "general"),
            },
        }

        if not blocking:
            ev.finalize(record, "\n".join(body_lines))
            info("cache hit; no reviewer call needed (%s)" % entry["verdict"])
            return EXIT_ACCEPT

        ack = self.acks.load(store.ack_digest(
            entry["report_digest"],
            target.base,
            target.tree,
            entry.get("risk_class", "general"),
            policy_hash,
        ))
        if ack is not None:
            record["acknowledgement_digest"] = store.ack_digest(
                entry["report_digest"],
                target.base,
                target.tree,
                entry.get("risk_class", "general"),
                policy_hash,
            )
            body_lines.append(
                "Accepted through a bound human acknowledgement: %s"
                % evidence.sanitize(ack["reason"])
            )
            ev.finalize(record, "\n".join(body_lines))
            info("blocking review accepted through a bound acknowledgement")
            return EXIT_ACCEPT

        ev.finalize(record, "\n".join(body_lines))
        error("BLOCKING: cached findings remain unresolved")
        error(
            "acknowledge with: review-gate acknowledge "
            "--report %s --reason <ticket>" % entry.get("report_path", "")
        )
        return EXIT_BLOCKING

    def _apply_legacy_cached(self, legacy, target):
        ev = evidence.RunEvidence(self.repo_root, "legacy-cache")
        record = {
            "base": target.base,
            "head": target.head,
            "tree": target.tree,
            "branch": target.branch,
            "decision": {
                "verdict": legacy["verdict"],
                "blocking": legacy["blocking"],
                "risk_class": legacy.get("risk_class", "general"),
                "parser": "legacy-v1",
            },
        }
        body = (
            "Decision: **%s** (from the version 1 markdown cache)\n\n"
            "Original report: `%s`\n" % (legacy["verdict"], legacy["report_path"])
        )
        if not legacy["blocking"]:
            ev.finalize(record, body)
            info("legacy cache hit; no reviewer call needed")
            return EXIT_ACCEPT
        ack_reason = self.environ.get("AI_REVIEW_HUMAN_ACK", "").strip()
        if ack_reason:
            # Version 1 compatibility only. Version 2 binds
            # acknowledgements to the exact report and source state.
            record["legacy_env_ack"] = ack_reason
            ev.finalize(
                record,
                body + "\nOverridden by AI_REVIEW_HUMAN_ACK: %s\n"
                % evidence.sanitize(ack_reason),
            )
            info("legacy blocking review overridden by AI_REVIEW_HUMAN_ACK")
            info("this override is version 1 compatibility; migrate to "
                 "bound acknowledgements")
            return EXIT_ACCEPT
        ev.finalize(record, body)
        error("BLOCKING: cached findings remain unresolved (legacy cache)")
        return EXIT_BLOCKING

    def _apply_skip(self, target, policy_hash, identity):
        skip_value = self.environ.get("SKIP_AI_REVIEW", "")
        ack_reason = self.environ.get("AI_REVIEW_HUMAN_ACK", "").strip()
        if not ack_reason:
            error("INCONCLUSIVE: skipping requires AI_REVIEW_HUMAN_ACK")
            return EXIT_INCONCLUSIVE

        if self.policy.profile_version == 1:
            if skip_value != "1":
                error("INCONCLUSIVE: SKIP_AI_REVIEW must be 1 for version 1")
                return EXIT_INCONCLUSIVE
        else:
            # Bind the skip to the exact push so an exported variable
            # cannot silently skip every future review.
            valid = (
                len(skip_value) >= _SKIP_MIN_PREFIX
                and target.head.startswith(skip_value)
            )
            if not valid:
                error(
                    "INCONCLUSIVE: SKIP_AI_REVIEW must be at least the "
                    "first %d characters of the pushed commit %s"
                    % (_SKIP_MIN_PREFIX, target.head)
                )
                return EXIT_INCONCLUSIVE

        ev = evidence.RunEvidence(self.repo_root, "skip")
        record = {
            "base": target.base,
            "head": target.head,
            "tree": target.tree,
            "local_ref": target.local_ref,
            "branch": target.branch,
            "policy_hash": policy_hash,
            "reviewer_identity": identity,
            "decision": {
                "verdict": "SKIPPED",
                "blocking": False,
                "risk_class": "unreviewed",
            },
            "skip_reason": ack_reason,
        }
        body = (
            "Decision: **SKIPPED** — the operator skipped AI review for "
            "`%s..%s`.\n\nReason: %s\n"
            % (target.base, target.head, evidence.sanitize(ack_reason))
        )
        ev.finalize(record, body)
        info("review skipped by operator; evidence recorded")
        return EXIT_ACCEPT

    def _verify_miss(self, target, policy_hash, identity, key):
        ev = evidence.RunEvidence(self.repo_root, "check-push")
        detail = (
            "No completed review matches this push. Run the local "
            "preflight before pushing:\n\n"
            "  .review-hooks/bin/review-gate review --base %s --head %s\n\n"
            "verify mode never starts a reviewer during git push."
            % (target.base, target.head)
        )
        record = {
            "base": target.base,
            "head": target.head,
            "tree": target.tree,
            "local_ref": target.local_ref,
            "branch": target.branch,
            "policy_hash": policy_hash,
            "reviewer_identity": identity,
            "cache_miss": key,
            "decision": {"reason_code": "verify_no_decision"},
        }
        ev.finalize(record, ev.render_failure_report(
            target, "verify_no_decision", detail
        ))
        error("INCONCLUSIVE: no completed review covers this push")
        error(
            "run: .review-hooks/bin/review-gate review --base %s --head %s"
            % (target.base, target.head)
        )
        return EXIT_INCONCLUSIVE

    # ----- paid review -----------------------------------------------------

    def _refuse(self, ev, target, record, reason_code, detail):
        record = dict(record)
        record["decision"] = {"reason_code": reason_code}
        ev.finalize(record, ev.render_failure_report(target, reason_code, detail))
        error("INCONCLUSIVE: %s" % detail.splitlines()[0])
        return EXIT_INCONCLUSIVE

    def _run_paid_review(self, target, policy_hash, identity, key):
        policy = self.policy
        ev = evidence.RunEvidence(self.repo_root, "review")
        files = gitwork.changed_files(self.repo_root, target.base, target.head)
        base_record = {
            "base": target.base,
            "head": target.head,
            "tree": target.tree,
            "local_ref": target.local_ref,
            "branch": target.branch,
            "files_digest": store.sha256_text("\n".join(files)),
            "policy_hash": policy_hash,
            "prompt_template_version": policy.prompt_template_version,
            "reviewer_identity": identity,
            "credential_scope": policy.credential_scope,
            "personal_opt_in": policy.allow_personal_quota,
            "total_timeout_seconds": policy.total_timeout,
            "kill_grace_seconds": policy.kill_grace,
            "max_budget_usd": policy.max_budget_usd,
        }

        try:
            prompts.check_sensitive_paths(policy, files)
        except SensitivePathError as err:
            detail = "external review refused for sensitive paths:\n%s" % (
                "\n".join("  - %s" % path for path in err.paths)
            )
            return self._refuse(ev, target, base_record, "sensitive_paths", detail)

        if (
            policy.credential_scope != "ci"
            and not policy.allow_personal_quota
        ):
            detail = (
                "personal model quota requires explicit opt-in\n"
                "set AI_REVIEW_ALLOW_PERSONAL_QUOTA=1 for this invocation"
            )
            return self._refuse(
                ev, target, base_record, "personal_quota_refused", detail
            )

        if not self.adapter.model_known():
            detail = (
                "the profile names no reviewer model\n"
                "set AI_REVIEW_MODEL before a paid attempt can start"
            )
            return self._refuse(ev, target, base_record, "model_unnamed", detail)

        # The run deadline starts here, after policy and target
        # validation, and covers prompt creation, every attempt, parsing,
        # and cleanup.
        deadline = time.monotonic() + policy.total_timeout

        review_from = target.base
        prior_findings = []
        state = self.state.load(target.branch)
        if (
            state is not None
            and state.get("base") == target.base
            # Incremental coverage binds to the same policy, prompt, and
            # reviewer as the prior report. Any change reviews the full
            # range again; a new reviewer never inherits an old one's
            # coverage of earlier commits.
            and state.get("policy_hash") == policy_hash
            and state.get("prompt_template_version")
            == policy.prompt_template_version
            and state.get("reviewer_identity") == identity
            and gitwork.is_valid_sha(state.get("head", ""))
            and state["head"] != target.head
            and gitwork.is_ancestor(self.repo_root, state["head"], target.head)
        ):
            review_from = state["head"]
            prior_findings = state["open_findings"]

        try:
            built = prompts.build_prompt(
                self.repo_root, policy, target, review_from, prior_findings
            )
        except SensitivePathError as err:
            detail = "external review refused for sensitive paths:\n%s" % (
                "\n".join("  - %s" % path for path in err.paths)
            )
            return self._refuse(ev, target, base_record, "sensitive_paths", detail)
        except PromptError as err:
            return self._refuse(ev, target, base_record, "prompt_budget", str(err))
        if built is None:
            info("no incremental changes since the previous verdict")
            return EXIT_ACCEPT

        base_record.update({
            "prompt_digest": store.sha256_text(built.text),
            "review_from": built.review_from,
            "incremental": built.incremental,
            "prior_findings_count": built.prior_findings_count,
        })

        # Attempt caps floor at four decimals so their serialized sum can
        # never exceed the run cap.
        attempt_cap = (
            math.floor(policy.max_budget_usd / policy.max_attempts * 10000)
            / 10000
        )
        assigned_usd = round(attempt_cap * policy.max_attempts, 4)

        # Reserve the whole run's spend before any launch. A crash
        # mid-run can never leave paid spend unrecorded, and concurrent
        # runs cannot both squeeze under the rolling limit.
        reserved, window_total = self.ledger.reserve(
            ev.run_id,
            assigned_usd,
            policy.rolling_spend_limit_usd,
            policy.rolling_spend_window_hours,
        )
        if not reserved:
            detail = (
                "rolling spend ledger is at %.2f USD of its %.2f USD "
                "limit over %d hours; this run's %.2f USD cap does not fit"
                % (
                    window_total,
                    policy.rolling_spend_limit_usd,
                    policy.rolling_spend_window_hours,
                    assigned_usd,
                )
            )
            return self._refuse(ev, target, base_record, "spend_limit", detail)

        result = None
        terminal_reason = None
        terminal_detail = ""
        attempt_costs = []

        attempt_index = 0
        while attempt_index < policy.max_attempts:
            attempt_index += 1
            remaining = deadline - time.monotonic()
            if remaining <= 0 or (
                attempt_index > 1 and remaining < policy.min_retry_time
            ):
                terminal_reason = terminal_reason or "timeout"
                terminal_detail = "run deadline left no room for another attempt"
                break

            outcome = supervisor.run_attempt(
                self.adapter.argv(attempt_cap),
                built.text,
                deadline,
                stdout_cap=policy.max_output_bytes,
                kill_grace=policy.kill_grace,
                environ=self.environ,
            )

            stdout_text = outcome.stdout_data.decode("utf-8", errors="replace")
            if self.adapter.emits_envelope():
                result_text, attempt_cost = self.adapter.parse_envelope(
                    stdout_text
                )
            else:
                result_text, attempt_cost = stdout_text, None
            attempt_costs.append(attempt_cost)

            completed_cleanly = (
                outcome.started
                and outcome.exit_code == 0
                and outcome.cleanup_verified
                and not outcome.overflow
                and not outcome.timed_out
                and not outcome.interrupted
            )
            if completed_cleanly:
                try:
                    if result_text is None:
                        raise ResultError(
                            "reviewer stdout is not a CLI result envelope"
                        )
                    result = results.parse_result(
                        result_text, policy.prompt_template_version
                    )
                    ev.record_attempt(
                        attempt_index, outcome, "completed", attempt_cap,
                        actual_usd=attempt_cost,
                    )
                except ResultError as err:
                    ev.record_attempt(
                        attempt_index, outcome, "invalid_result", attempt_cap,
                        actual_usd=attempt_cost,
                    )
                    terminal_reason = "invalid_result"
                    terminal_detail = str(err)
                break

            reason = self.adapter.classify_failure(outcome)
            ev.record_attempt(
                attempt_index, outcome, reason, attempt_cap,
                actual_usd=attempt_cost,
            )
            if (
                reason == "startup_transport"
                and reason in policy.retryable_failures
                and attempt_index < policy.max_attempts
            ):
                continue
            terminal_reason = reason
            terminal_detail = (
                "attempt %d ended with reason %s (exit=%s signal=%s "
                "stdout=%dB stderr=%dB)"
                % (
                    attempt_index,
                    reason,
                    outcome.exit_code,
                    outcome.term_signal,
                    outcome.stdout_total,
                    outcome.stderr_total,
                )
            )
            if outcome.launch_error:
                terminal_detail += "\nlaunch error: %s" % outcome.launch_error
            break

        # Settle the reservation to what the attempts can prove: the
        # reported cost where the adapter supplied one, the full cap for
        # a launched attempt that reported nothing, zero for an attempt
        # that never launched. When nothing is reclaimed the reservation
        # already says it all.
        settled_usd = sum(
            attempt_cap if cost is None else cost for cost in attempt_costs
        )
        if settled_usd != assigned_usd:
            self.ledger.settle(ev.run_id, settled_usd)

        if result is None:
            record = dict(base_record)
            record["decision"] = {"reason_code": terminal_reason}
            ev.finalize(record, ev.render_failure_report(
                target, terminal_reason, terminal_detail or terminal_reason
            ))
            error("INCONCLUSIVE: reviewer failed within the configured budget")
            error("reason: %s" % terminal_reason)
            return EXIT_INCONCLUSIVE

        record = dict(base_record)
        record["decision"] = {
            "verdict": result.verdict,
            "blocking": result.blocking,
            "risk_class": result.risk_class,
            "parser": result.parser,
            "findings_count": len(result.findings),
        }
        report_path, report_digest = ev.finalize(
            record, ev.render_decision_report(target, result, policy)
        )

        if result.verdict == "INCONCLUSIVE":
            # A completed INCONCLUSIVE verdict is evidence, never a
            # decision; it is not cached and not retried.
            error("INCONCLUSIVE: reviewer could not complete the review")
            return EXIT_INCONCLUSIVE

        self.cache.write(key, {
            "created_utc": evidence.utc_now_iso(),
            "base": target.base,
            "tree": target.tree,
            "policy_hash": policy_hash,
            "prompt_template_version": policy.prompt_template_version,
            "reviewer_identity": identity,
            "verdict": result.verdict,
            "must_fix_count": sum(
                1 for f in result.findings if f["severity"] == "MUST-FIX"
            ),
            "risk_class": result.risk_class,
            "report_digest": report_digest,
            "report_path": report_path,
            "run_id": ev.run_id,
        })
        self.state.write(target.branch, {
            "created_utc": evidence.utc_now_iso(),
            "base": target.base,
            "head": target.head,
            "policy_hash": policy_hash,
            "prompt_template_version": policy.prompt_template_version,
            "reviewer_identity": identity,
            "report_path": report_path,
            "report_digest": report_digest,
            "open_findings": result.findings,
        })

        if result.blocking:
            ack = self.acks.load(store.ack_digest(
                report_digest,
                target.base,
                target.tree,
                result.risk_class,
                policy_hash,
            ))
            if ack is not None:
                info("blocking review accepted through a bound acknowledgement")
                return EXIT_ACCEPT
            error("BLOCKING: %s findings require resolution" % result.risk_class)
            error(
                "acknowledge with: review-gate acknowledge "
                "--report %s --reason <ticket>" % report_path
            )
            return EXIT_BLOCKING

        info("aggregate review passed and was cached (%s)" % result.verdict)
        return EXIT_ACCEPT
