"""Claude CLI adapter.

Knows flags and output format; decides no policy. Reviewer arguments use
an argv array and never a shell string. No fallback to another model or
provider is automatic.
"""

import hashlib
import json
import math
import os
import shutil
from dataclasses import dataclass

# Error classification is structural, never prose. These statuses are
# documented provider semantics, not yet locally captured (the 429 and
# 5xx capture legs are blocked; see tests/fixtures/claude-cli/README.md).
# The distinct outcome names exist so run evidence records *why* an
# attempt failed, not to drive any differing gate behavior.
_TRANSIENT_PROVIDER_STATUSES = frozenset({503, 529})
_AUTH_STATUSES = frozenset({401, 403})


@dataclass
class EnvelopeParse:
    """Semantic interpretation of one CLI stdout envelope.

    `result_text` is populated only for `completed`; an error envelope
    never exposes its text to the review-result parser. `actual_usd`
    carries any well-formed, finite, non-negative cost the envelope
    reported — on every outcome, including rejected and invalid
    envelopes. Settlement may charge a reported cost even when the
    decision trusts nothing else in the envelope.
    """

    outcome: str
    result_text: str = None
    actual_usd: float = None
    provider_status: int = None
    subtype: str = None


class ClaudeAdapter:
    name = "claude"
    provider = "anthropic"
    # The CLI documents no startup-failure exit codes; nothing retries by
    # default. A profile that knows better can list codes explicitly.
    documented_startup_exit_codes = frozenset()

    def __init__(self, policy):
        self.policy = policy
        self._cli_version = None

    def available(self):
        return shutil.which(self.policy.claude_bin) is not None

    def argv(self, attempt_cap_usd):
        argv = [
            self.policy.claude_bin,
            "--tools", "",
            "--max-turns", "1",
            "--max-budget-usd", "%.4f" % attempt_cap_usd,
        ]
        if self.emits_envelope():
            # The JSON envelope is the only channel that reports actual
            # spend (total_cost_usd), which the ledger needs to settle
            # the reservation.
            argv += ["--output-format", "json"]
        if self.policy.model:
            argv += ["--model", self.policy.model]
        argv.append("-p")
        return argv

    def emits_envelope(self):
        """Version 1 profiles keep the plain-stdout reviewer contract
        for their one compatibility release; only version 2 launches
        with the JSON envelope and can settle actual spend."""
        return self.policy.profile_version != 1

    @staticmethod
    def parse_envelope(stdout_text):
        """Classify the CLI's JSON envelope into an EnvelopeParse.

        The success shape is exactly the one captured from the installed
        CLI (2.1.224): `type: "result"`, `subtype: "success"`,
        `is_error: false`, string `result`. Everything else is an error
        or invalid envelope and can never produce a review decision —
        an error envelope that happens to embed a syntactically valid
        review result is still rejected (H1).

        Error classification is structural only: numeric
        `api_error_status` plus captured subtype/terminal_reason
        discriminators (budget exhaustion and transport failure were
        captured locally; the status-code legs rest on documented
        semantics until their captures unblock). Prose (stderr,
        `errors` strings) never classifies. A non-finite or negative cost is unusable — NaN
        poisons the ledger sum and disables the rolling limit — so it
        stays None.
        """
        try:
            data = json.loads(stdout_text)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return EnvelopeParse(outcome="invalid_envelope")
        if not isinstance(data, dict):
            return EnvelopeParse(outcome="invalid_envelope")

        cost = data.get("total_cost_usd")
        if isinstance(cost, bool) or not isinstance(cost, (int, float)):
            cost = None
        elif not math.isfinite(cost) or cost < 0:
            cost = None
        else:
            cost = float(cost)

        subtype = data.get("subtype")
        if not isinstance(subtype, str):
            subtype = None
        status = data.get("api_error_status")
        if isinstance(status, bool) or not isinstance(status, int):
            status = None
        is_error = data.get("is_error")

        common = dict(
            actual_usd=cost, provider_status=status, subtype=subtype
        )
        if data.get("type") != "result" or not isinstance(is_error, bool):
            return EnvelopeParse(outcome="invalid_envelope", **common)

        if not is_error:
            result = data.get("result")
            terminal_reason = data.get("terminal_reason")
            if (
                subtype == "success"
                and isinstance(result, str)
                # A claimed success carrying any error discriminator —
                # a numeric provider status or a non-completed terminal
                # reason — is contradictory; neither side is trusted,
                # so the embedded result never reaches the parser.
                and status is None
                and terminal_reason in (None, "completed")
            ):
                return EnvelopeParse(
                    outcome="completed", result_text=result, **common
                )
            # A claimed success without the captured success shape is
            # contradictory, not trustworthy.
            return EnvelopeParse(outcome="invalid_envelope", **common)

        if subtype == "success":
            # is_error with a success subtype is contradictory.
            return EnvelopeParse(outcome="invalid_envelope", **common)
        if (
            subtype == "error_max_budget_usd"
            or data.get("terminal_reason") == "budget_exhausted"
        ):
            return EnvelopeParse(outcome="budget_exhausted", **common)
        if status in _AUTH_STATUSES:
            return EnvelopeParse(outcome="authentication_failed", **common)
        if status == 429:
            return EnvelopeParse(outcome="rate_limited", **common)
        if status in _TRANSIENT_PROVIDER_STATUSES:
            return EnvelopeParse(outcome="provider_unavailable", **common)
        return EnvelopeParse(outcome="provider_error", **common)

    def capability_fingerprint(self):
        """Fingerprint of the reviewer executable.

        Running `--version` at decision time would cost seconds and a
        process launch on every push. The resolved path, size, and
        mtime change on any CLI upgrade, which is what the cache needs:
        a changed reviewer misses and buys a fresh review.
        """
        if self._cli_version is not None:
            return self._cli_version
        fingerprint = "unknown"
        resolved = shutil.which(self.policy.claude_bin)
        if resolved:
            try:
                stat = os.stat(resolved)
                fingerprint = hashlib.sha256(
                    ("%s\n%d\n%d" % (resolved, stat.st_size, stat.st_mtime_ns))
                    .encode("utf-8")
                ).hexdigest()[:16]
            except OSError:
                fingerprint = "unknown"
        self._cli_version = fingerprint
        return fingerprint

    def identity(self):
        """Adapter, provider, model, and CLI capability fingerprint.

        Version 1 profiles never fingerprinted the CLI; keep their
        identity deterministic so upgrades do not thrash the legacy
        cache path.
        """
        if self.policy.profile_version == 1:
            model = self.policy.model or "legacy-v1"
            return "%s:%s:%s:unprobed" % (self.name, self.provider, model)
        model = self.policy.model or "unknown"
        return "%s:%s:%s:%s" % (
            self.name, self.provider, model, self.capability_fingerprint()
        )

    def model_known(self):
        if self.policy.profile_version == 1:
            return True
        return bool(self.policy.model)

    def classify_failure(self, outcome):
        """Map one failed attempt to a reason code.

        Only documented startup or transport exit data may become
        `startup_transport`. Unknown exit codes and free-form stderr stay
        `unknown_infrastructure` and never retry.
        """
        if not outcome.started:
            return "missing_cli"
        if outcome.interrupted:
            return "interrupted"
        if outcome.timed_out:
            return "timeout"
        if outcome.overflow:
            return "output_overflow"
        if not outcome.cleanup_verified:
            return "cleanup_unverified"
        startup_codes = (
            self.documented_startup_exit_codes | self.policy.startup_exit_codes
        )
        if (
            outcome.exit_code is not None
            and outcome.exit_code != 0
            and outcome.exit_code in startup_codes
            and outcome.stdout_total == 0
            and outcome.duration < self.policy.min_retry_time
        ):
            return "startup_transport"
        return "unknown_infrastructure"
