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
        """Split the CLI's JSON envelope into (result_text, actual_usd).

        Either element is None when the envelope does not carry it.
        Malformed stdout returns (None, None): the review result stays
        untrusted and the ledger keeps charging the assigned cap. A
        non-finite cost is unusable — NaN poisons the ledger sum and
        disables the rolling limit — so it stays None as well.
        """
        try:
            data = json.loads(stdout_text)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None, None
        if not isinstance(data, dict):
            return None, None
        text = data.get("result")
        if not isinstance(text, str):
            text = None
        cost = data.get("total_cost_usd")
        if isinstance(cost, bool) or not isinstance(cost, (int, float)):
            cost = None
        elif not math.isfinite(cost) or cost < 0:
            cost = None
        return text, cost

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
