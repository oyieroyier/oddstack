"""Profile validation.

The sourced shell profile is trusted repository policy. The shell adapter
exports its values; this module validates every value before use and maps
version 1 names onto the safer version 2 meanings.
"""

import hashlib
import math
import os
import re
from dataclasses import dataclass, field

PROMPT_TEMPLATE_VERSION_V1 = "1"
PROMPT_TEMPLATE_VERSION_V2 = "2"

RETRYABLE_FAILURE_NAMES = {"startup_transport"}


class PolicyError(Exception):
    """The profile or environment is invalid. Exit code 2."""


@dataclass
class Policy:
    profile_version: int
    push_mode: str
    product_name: str
    default_base: str
    backend_path_regex: str
    sensitive_path_regex: str
    sensitive_allow_regex: str
    total_timeout: int
    kill_grace: int
    max_attempts: int
    retryable_failures: frozenset
    min_retry_time: int
    max_diff_lines: int
    max_backend_diff_lines: int
    max_prompt_tokens: int
    max_prior_report_bytes: int
    max_output_bytes: int
    max_budget_usd: float
    rolling_spend_limit_usd: float
    rolling_spend_window_hours: int
    model: str
    backend: str
    credential_scope: str
    allow_personal_quota: bool
    claude_bin: str
    merge_with_fixes_command: str
    startup_exit_codes: frozenset = field(default_factory=frozenset)

    @property
    def prompt_template_version(self):
        if self.profile_version == 1:
            return PROMPT_TEMPLATE_VERSION_V1
        return PROMPT_TEMPLATE_VERSION_V2

    def policy_hash(self):
        """Hash of every profile control that affects review completeness.

        The reviewer identity is hashed separately; the model is part of
        identity, not policy. The prompt template text is fingerprinted
        at cache-key assembly (prompts.template_fingerprint), not here.
        """
        parts = [
            "profile_version=%d" % self.profile_version,
            "prompt_template_version=%s" % self.prompt_template_version,
            "product_name=%s" % self.product_name,
            "default_base=%s" % self.default_base,
            "backend_path_regex=%s" % self.backend_path_regex,
            "sensitive_path_regex=%s" % self.sensitive_path_regex,
            "sensitive_allow_regex=%s" % self.sensitive_allow_regex,
            "max_diff_lines=%d" % self.max_diff_lines,
            "max_backend_diff_lines=%d" % self.max_backend_diff_lines,
            "max_prompt_tokens=%d" % self.max_prompt_tokens,
            "max_prior_report_bytes=%d" % self.max_prior_report_bytes,
            "max_output_bytes=%d" % self.max_output_bytes,
            "merge_with_fixes_command=%s" % self.merge_with_fixes_command,
        ]
        digest = hashlib.sha256("\n".join(parts).encode("utf-8"))
        return digest.hexdigest()


def _env(environ, key, default):
    value = environ.get(key, "")
    if value == "":
        return default
    return value


def _positive_int(environ, key, default):
    raw = _env(environ, key, default)
    if not re.fullmatch(r"[1-9][0-9]*", str(raw)):
        raise PolicyError("%s must be a positive integer, got %r" % (key, raw))
    return int(raw)


def _non_negative_number(environ, key, default):
    raw = _env(environ, key, default)
    try:
        value = float(raw)
    except ValueError:
        raise PolicyError("%s must be a number, got %r" % (key, raw))
    if not math.isfinite(value) or value < 0:
        raise PolicyError(
            "%s must be a finite non-negative number, got %r" % (key, raw)
        )
    return value


def _regex(environ, key, default):
    raw = _env(environ, key, default)
    try:
        re.compile(raw)
    except re.error as error:
        raise PolicyError("%s is not a valid regex: %s" % (key, error))
    return raw


def load_policy(environ=None):
    if environ is None:
        environ = os.environ

    raw_version = environ.get("REVIEW_HOOKS_PROFILE_VERSION", "")
    if raw_version not in ("1", "2"):
        raise PolicyError(
            "REVIEW_HOOKS_PROFILE_VERSION must be 1 or 2, got %r" % raw_version
        )
    profile_version = int(raw_version)

    backend = _env(environ, "AI_REVIEW_BACKEND", "claude")
    if backend != "claude":
        raise PolicyError("unsupported AI_REVIEW_BACKEND: %r" % backend)

    credential_scope = _env(environ, "AI_REVIEW_CREDENTIAL_SCOPE", "personal")
    if credential_scope not in ("personal", "ci"):
        raise PolicyError(
            "AI_REVIEW_CREDENTIAL_SCOPE must be personal or ci, got %r"
            % credential_scope
        )

    if profile_version == 1:
        # Version 1's per-attempt timeout maps to the run-wide deadline.
        total_timeout = _positive_int(environ, "AI_REVIEW_TIMEOUT", "600")
        push_mode = "run-if-missing"
        retryable = frozenset()
    else:
        total_timeout = _positive_int(environ, "AI_REVIEW_TOTAL_TIMEOUT", "600")
        push_mode = _env(environ, "AI_REVIEW_PUSH_MODE", "verify")
        if push_mode not in ("verify", "run-if-missing"):
            raise PolicyError(
                "AI_REVIEW_PUSH_MODE must be verify or run-if-missing, got %r"
                % push_mode
            )
        raw_retryable = _env(environ, "AI_REVIEW_RETRYABLE_FAILURES", "")
        names = {name for name in re.split(r"[,\s]+", raw_retryable) if name}
        unknown = names - RETRYABLE_FAILURE_NAMES
        if unknown:
            raise PolicyError(
                "unknown AI_REVIEW_RETRYABLE_FAILURES entries: %s"
                % ", ".join(sorted(unknown))
            )
        retryable = frozenset(names)

    if profile_version == 1:
        # Version 1's unconditional retry loop is gone; a second attempt
        # would only halve the single real attempt's spend cap.
        max_attempts = 1
    else:
        max_attempts = _positive_int(environ, "AI_REVIEW_MAX_ATTEMPTS", "1")
        if max_attempts not in (1, 2):
            raise PolicyError("AI_REVIEW_MAX_ATTEMPTS must be 1 or 2")
        if max_attempts == 2 and not retryable:
            raise PolicyError(
                "AI_REVIEW_MAX_ATTEMPTS=2 needs AI_REVIEW_RETRYABLE_FAILURES; "
                "an unreachable second attempt only halves the spend cap"
            )

    max_budget = _non_negative_number(environ, "AI_REVIEW_MAX_BUDGET_USD", "2.00")
    if max_budget <= 0:
        raise PolicyError("AI_REVIEW_MAX_BUDGET_USD must be greater than zero")

    raw_startup_codes = _env(environ, "AI_REVIEW_STARTUP_EXIT_CODES", "")
    startup_codes = set()
    for chunk in re.split(r"[,\s]+", raw_startup_codes):
        if not chunk:
            continue
        if not re.fullmatch(r"[0-9]+", chunk):
            raise PolicyError(
                "AI_REVIEW_STARTUP_EXIT_CODES must list integers, got %r" % chunk
            )
        startup_codes.add(int(chunk))

    return Policy(
        profile_version=profile_version,
        push_mode=push_mode,
        product_name=_env(environ, "AI_REVIEW_PRODUCT_NAME", "this repository"),
        default_base=_env(environ, "AI_REVIEW_DEFAULT_BASE", "origin/main"),
        backend_path_regex=_regex(
            environ,
            "AI_REVIEW_BACKEND_PATH_REGEX",
            r"^(api/|backend/|server/|db/|migrations/|sql/)",
        ),
        sensitive_path_regex=_regex(
            environ,
            "AI_REVIEW_SENSITIVE_PATH_REGEX",
            r"(^|/)\.env[^/]*$|\.pem$|\.key$",
        ),
        sensitive_allow_regex=_regex(
            environ, "AI_REVIEW_SENSITIVE_PATH_ALLOW_REGEX", r"\.example$"
        ),
        total_timeout=total_timeout,
        kill_grace=_positive_int(environ, "AI_REVIEW_KILL_GRACE", "5"),
        max_attempts=max_attempts,
        retryable_failures=retryable,
        min_retry_time=_positive_int(environ, "AI_REVIEW_MIN_RETRY_TIME", "30"),
        max_diff_lines=_positive_int(environ, "AI_REVIEW_MAX_DIFF_LINES", "3000"),
        max_backend_diff_lines=_positive_int(
            environ, "AI_REVIEW_MAX_BACKEND_DIFF_LINES", "1200"
        ),
        max_prompt_tokens=_positive_int(
            environ, "AI_REVIEW_MAX_PROMPT_TOKENS", "32000"
        ),
        max_prior_report_bytes=_positive_int(
            environ, "AI_REVIEW_MAX_PRIOR_REPORT_BYTES", "12000"
        ),
        max_output_bytes=_positive_int(
            environ, "AI_REVIEW_MAX_OUTPUT_BYTES", "30000"
        ),
        max_budget_usd=max_budget,
        rolling_spend_limit_usd=_non_negative_number(
            environ, "AI_REVIEW_ROLLING_SPEND_LIMIT_USD", "0"
        ),
        rolling_spend_window_hours=_positive_int(
            environ, "AI_REVIEW_ROLLING_SPEND_WINDOW_HOURS", "24"
        ),
        model=_env(environ, "AI_REVIEW_MODEL", ""),
        backend=backend,
        credential_scope=credential_scope,
        allow_personal_quota=environ.get("AI_REVIEW_ALLOW_PERSONAL_QUOTA", "") == "1",
        claude_bin=_env(environ, "AI_REVIEW_CLAUDE_BIN", "claude"),
        merge_with_fixes_command=_env(
            environ, "AI_REVIEW_MERGE_WITH_FIXES_COMMAND", ""
        ),
        startup_exit_codes=frozenset(startup_codes),
    )
