"""Evidence for every terminal decision.

Each invocation that reaches decision logic writes
`ai-reviews/runs/<run-id>/run.json` and `report.md`, plus bounded
attempt files. Prompt text and raw diffs never enter evidence; their
hashes bind the run.
"""

import os
import time
from datetime import datetime, timezone

from . import RUN_SCHEMA_VERSION, RUNTIME_VERSION
from . import store

_STDERR_EXCERPT_BYTES = 4096


def utc_now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_run_id():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return "%s-%d-%s" % (stamp, os.getpid(), os.urandom(3).hex())


def sanitize(text):
    """Reviewer output is untrusted data. Neutralize fence escapes."""
    return str(text).replace("```", "` ` `")


class RunEvidence:
    def __init__(self, repo_root, invocation):
        self.repo_root = repo_root
        self.run_id = new_run_id()
        self.invocation = invocation
        self.started_utc = utc_now_iso()
        self.started_monotonic = time.monotonic()
        self.attempts = []
        self.run_dir = os.path.join(
            store.out_dir(repo_root), "runs", self.run_id
        )

    def record_attempt(
        self, index, outcome, reason_code, assigned_usd, actual_usd=None
    ):
        self.attempts.append({
            "attempt": index,
            "reason_code": reason_code,
            "assigned_usd": assigned_usd,
            "actual_usd": actual_usd,
            "started": outcome.started,
            "launch_error": outcome.launch_error,
            "exit_code": outcome.exit_code,
            "term_signal": outcome.term_signal,
            "duration_seconds": round(outcome.duration, 3),
            "stdout_bytes": outcome.stdout_total,
            "stderr_bytes": outcome.stderr_total,
            "stdout_truncated": outcome.stdout_total > len(outcome.stdout_data),
            "stderr_truncated": outcome.stderr_total > len(outcome.stderr_data),
            "overflow": outcome.overflow,
            "timed_out": outcome.timed_out,
            "interrupted": outcome.interrupted,
            "cleanup_verified": outcome.cleanup_verified,
            "cleanup_detail": outcome.cleanup_detail,
            "pid": outcome.pid,
            "_stdout_data": outcome.stdout_data,
            "_stderr_data": outcome.stderr_data,
        })

    def finalize(self, record, report_body):
        """Write the run directory and return the report digest."""
        os.makedirs(self.run_dir, mode=0o700, exist_ok=True)
        # An already-existing ai-reviews/ or runs/ directory keeps whatever
        # mode it was created with; force both roots private too.
        for directory in (store.out_dir(self.repo_root),
                          os.path.join(store.out_dir(self.repo_root), "runs")):
            try:
                os.chmod(directory, 0o700)
            except OSError:
                pass

        attempt_records = []
        for attempt in self.attempts:
            index = attempt["attempt"]
            stdout_data = attempt.get("_stdout_data", b"")
            stderr_data = attempt.get("_stderr_data", b"")
            attempt_record = {
                key: value
                for key, value in attempt.items()
                if not key.startswith("_")
            }
            stdout_path = os.path.join(
                self.run_dir, "attempt-%d.stdout" % index
            )
            stderr_path = os.path.join(
                self.run_dir, "attempt-%d.stderr" % index
            )
            stdout_fd = os.open(
                stdout_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600
            )
            with os.fdopen(stdout_fd, "wb") as handle:
                handle.write(stdout_data)
            stderr_fd = os.open(
                stderr_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600
            )
            with os.fdopen(stderr_fd, "wb") as handle:
                handle.write(stderr_data)
            store.atomic_write_json(
                os.path.join(self.run_dir, "attempt-%d.json" % index),
                attempt_record,
            )
            attempt_records.append(attempt_record)

        report_path = os.path.join(self.run_dir, "report.md")
        header = "# Aggregate review run %s\n\n" % self.run_id
        store.atomic_write_text(report_path, header + report_body)
        report_digest = store.sha256_file(report_path)

        # Canonical fields win over caller-supplied ones so a record can
        # never override the digest, schema, or attempt data.
        run_record = dict(record)
        run_record.update({
            "schema_version": RUN_SCHEMA_VERSION,
            "runtime_version": RUNTIME_VERSION,
            "run_id": self.run_id,
            "invocation": self.invocation,
            "started_utc": self.started_utc,
            "ended_utc": utc_now_iso(),
            "elapsed_monotonic_seconds": round(
                time.monotonic() - self.started_monotonic, 3
            ),
            "attempts": attempt_records,
            "report_digest": report_digest,
        })
        store.atomic_write_json(
            os.path.join(self.run_dir, "run.json"), run_record
        )

        latest_path = os.path.join(store.out_dir(self.repo_root), "latest.md")
        pointer = (
            header
            + report_body
            + "\n---\nMachine record: `%s`\n"
            % os.path.relpath(
                os.path.join(self.run_dir, "run.json"), self.repo_root
            )
        )
        store.atomic_write_text(latest_path, pointer)
        return report_path, report_digest

    def render_decision_report(self, target, result, policy):
        lines = [
            "Decision: **%s**  Risk class: `%s`  Parser: `%s`"
            % (result.verdict, result.risk_class, result.parser),
            "",
            "Base: `%s`" % target.base,
            "Head: `%s`" % target.head,
            "Tree: `%s`" % target.tree,
            "Branch: `%s`" % target.branch,
            "",
        ]
        if result.findings:
            lines.append("## Findings")
            lines.append("")
            for finding in result.findings:
                lines.append(
                    "- **%s** `%s:%s` — trigger: %s; consequence: %s; fix: %s"
                    % (
                        finding["severity"],
                        sanitize(finding["file"]),
                        finding["line"],
                        sanitize(finding["trigger"]),
                        sanitize(finding["consequence"]),
                        sanitize(finding["fix"]),
                    )
                )
            lines.append("")
        else:
            lines.append("No findings.")
            lines.append("")
        if result.limitations:
            lines.append("## Limitations")
            lines.append("")
            for limitation in result.limitations:
                lines.append("- %s" % sanitize(limitation))
            lines.append("")
        if result.parser == "legacy-v1" and result.raw_text:
            lines.append("## Legacy report text")
            lines.append("")
            lines.append("```")
            lines.append(sanitize(result.raw_text))
            lines.append("```")
            lines.append("")
        return "\n".join(lines)

    def render_failure_report(self, target, reason_code, detail):
        lines = [
            "Decision: **INCONCLUSIVE**  Reason: `%s`" % reason_code,
            "",
            "%s" % sanitize(detail),
            "",
        ]
        if target is not None:
            lines += [
                "Base: `%s`" % target.base,
                "Head: `%s`" % target.head,
                "Branch: `%s`" % target.branch,
                "",
            ]
        for attempt in self.attempts:
            stderr_data = attempt.get("_stderr_data", b"")
            if stderr_data:
                excerpt = stderr_data[-_STDERR_EXCERPT_BYTES:].decode(
                    "utf-8", errors="replace"
                )
                lines += [
                    "## Attempt %d stderr (bounded)" % attempt["attempt"],
                    "",
                    "```",
                    sanitize(excerpt),
                    "```",
                    "",
                ]
        return "\n".join(lines)
