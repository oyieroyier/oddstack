"""E1.1 spike: capture real Claude CLI envelopes through the production path.

Builds argv with the real ClaudeAdapter and runs the attempt through the
real supervisor, so every capture reflects exactly what the gate would
see. Raw stdout/stderr land in an operator-supplied 0700 directory that
must live outside the repository; only sanitized fixtures derived from
them may be committed.

Cases:
  success          small prompt, generous cap; expects a clean envelope
  budget-exhausted oversized prompt against a tiny --max-budget-usd
  partial-result   local server accepts the request then severs transport
  rate-limited     needs an already rate-limited credential; refuses to
                   fabricate one (records BLOCKED otherwise)

Usage:
  python3 capture_claude_envelopes.py --raw-dir DIR --case success \
      --model claude-haiku-4-5-20251001 [--budget-usd 0.25] [--timeout 240]
"""

import argparse
import hashlib
import http.server
import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time

SPIKE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(SPIKE_DIR)))

from review_gate import supervisor  # noqa: E402
from review_gate.adapter import ClaudeAdapter  # noqa: E402
from review_gate.policy import load_policy  # noqa: E402

SUCCESS_PROMPT = (
    "Respond with exactly this text and nothing else:\n"
    "VERDICT: SAFE\nRISK: general\nFINDINGS: none\n"
)

# ~120KB of input so a 0.01 USD cap cannot cover even the input tokens.
BUDGET_PROMPT = (
    "Summarize the following log in one word.\n\n"
    + ("line: the quick brown fox jumped over the lazy dog again\n" * 2200)
)


def _policy_for(model):
    environ = {
        "REVIEW_HOOKS_PROFILE_VERSION": "2",
        "AI_REVIEW_MODEL": model,
        "AI_REVIEW_ALLOW_PERSONAL_QUOTA": "1",
    }
    return load_policy(environ)


def _utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _cli_version(claude_bin):
    try:
        out = subprocess.run(
            [claude_bin, "--version"], capture_output=True, text=True,
            timeout=60,
        )
        return out.stdout.strip() or out.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as err:
        return "unavailable: %s" % err


def _credential_scope_names(environ):
    """Names only; never values. The credential file is resolved
    against the CHILD's HOME — for a disposable-credential capture the
    evidence must name the identity the capture actually ran under,
    not the harness operator's."""
    names = [
        name for name in (
            "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
            "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        ) if environ.get(name)
    ]
    child_home = environ.get("HOME", "")
    if child_home and os.path.exists(
        os.path.join(child_home, ".claude", ".credentials.json")
    ):
        names.append("$HOME/.claude/.credentials.json")
        if child_home != os.path.expanduser("~"):
            names.append("(HOME overridden to a disposable identity)")
    return names


_AMBIENT_AUTH_VARS = (
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
)


def _child_environ(extra=None, strip_auth=False):
    env = dict(os.environ)
    # A capture must behave like a plain operator shell, not a nested
    # Claude Code session.
    for name in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"):
        env.pop(name, None)
    if strip_auth:
        # A disposable-credential capture must not fall back to the
        # operator's ambient credentials: an env token outranks the
        # override HOME's stored login, silently running the paid
        # capture against the production account.
        for name in _AMBIENT_AUTH_VARS:
            env.pop(name, None)
    if extra:
        env.update(extra)
    return env


def _top_level_shape(stdout_bytes):
    try:
        data = json.loads(stdout_bytes.decode("utf-8", errors="replace"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(data, dict):
        return {"<non-object>": type(data).__name__}
    return {key: type(value).__name__ for key, value in sorted(data.items())}


class _SeveringHandler(http.server.BaseHTTPRequestHandler):
    """Accepts the request, reads headers and body, then severs the
    connection without a response: a genuine transport interruption
    after the request began."""

    def _sever(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(min(length, 1 << 20))
        try:
            self.connection.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER,
                b"\x01\x00\x00\x00\x00\x00\x00\x00",
            )
        except OSError:
            pass
        self.connection.close()

    do_GET = _sever
    do_POST = _sever

    def log_message(self, *args):
        pass


def _start_severing_server():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _SeveringHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, "http://127.0.0.1:%d" % server.server_address[1]


def run_capture(case, raw_dir, model, budget_usd, timeout):
    mode = stat.S_IMODE(os.stat(raw_dir).st_mode)
    if mode & 0o077:
        raise SystemExit("raw dir %s must be mode 0700, is %o" % (raw_dir, mode))

    policy = _policy_for(model)
    adapter = ClaudeAdapter(policy)

    extra_env = None
    strip_auth = False
    server = None
    if case == "success":
        prompt, cap = SUCCESS_PROMPT, budget_usd
    elif case == "budget-exhausted":
        prompt, cap = BUDGET_PROMPT, 0.01
    elif case == "partial-result":
        prompt, cap = SUCCESS_PROMPT, budget_usd
        server, base_url = _start_severing_server()
        extra_env = {"ANTHROPIC_BASE_URL": base_url}
    elif case == "rate-limited":
        cred = os.environ.get("E1_RATE_LIMITED_CREDENTIAL_HOME", "")
        if not cred:
            print("BLOCKED: no already-rate-limited disposable credential "
                  "(set E1_RATE_LIMITED_CREDENTIAL_HOME); a fabricated "
                  "envelope does not qualify")
            return 3
        prompt, cap = SUCCESS_PROMPT, budget_usd
        extra_env = {"HOME": cred}
        strip_auth = True
    else:
        raise SystemExit("unknown case %r" % case)

    argv = adapter.argv(cap)
    environ = _child_environ(extra_env, strip_auth=strip_auth)
    started_utc = _utc_now()
    started_mono = time.monotonic()
    try:
        outcome = supervisor.run_attempt(
            argv, prompt, started_mono + timeout,
            stdout_cap=policy.max_output_bytes, kill_grace=5,
            environ=environ,
        )
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()

    ended_utc = _utc_now()
    base = os.path.join(raw_dir, case)
    with open(base + ".stdout", "wb") as handle:
        handle.write(outcome.stdout_data)
    with open(base + ".stderr", "wb") as handle:
        handle.write(outcome.stderr_data)

    meta = {
        "case": case,
        "cli_version": _cli_version(policy.claude_bin),
        "argv_redacted": argv,
        "model": model,
        "attempt_cap_usd": cap,
        "started_utc": started_utc,
        "ended_utc": ended_utc,
        "duration_seconds": round(outcome.duration, 3),
        "exit_code": outcome.exit_code,
        "term_signal": outcome.term_signal,
        "stdout_bytes": outcome.stdout_total,
        "stderr_bytes": outcome.stderr_total,
        "stdout_sha256": _sha256(outcome.stdout_data),
        "stderr_sha256": _sha256(outcome.stderr_data),
        "top_level_fields": _top_level_shape(outcome.stdout_data),
        "supervisor": {
            "started": outcome.started,
            "timed_out": outcome.timed_out,
            "overflow": outcome.overflow,
            "interrupted": outcome.interrupted,
            "cleanup_verified": outcome.cleanup_verified,
            "cleanup_detail": outcome.cleanup_detail,
            "launch_error": outcome.launch_error,
        },
        "parse_envelope": None,
        "credential_scope_present": _credential_scope_names(environ),
        "ambient_auth_stripped": sorted(
            name for name in _AMBIENT_AUTH_VARS
            if strip_auth and os.environ.get(name)
        ),
    }
    parsed = ClaudeAdapter.parse_envelope(
        outcome.stdout_data.decode("utf-8", errors="replace")
    )
    meta["parse_envelope"] = {
        "outcome": parsed.outcome,
        "subtype": parsed.subtype,
        "provider_status": parsed.provider_status,
        "result_is_string": isinstance(parsed.result_text, str),
        "result_length": (
            len(parsed.result_text)
            if isinstance(parsed.result_text, str) else None
        ),
        "actual_usd": parsed.actual_usd,
    }
    with open(base + ".meta.json", "w", encoding="utf-8") as handle:
        json.dump(meta, handle, indent=2)
    print(json.dumps(meta, indent=2))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-dir", required=True)
    parser.add_argument("--case", required=True, choices=[
        "success", "budget-exhausted", "partial-result", "rate-limited",
    ])
    parser.add_argument("--model", default="claude-haiku-4-5-20251001")
    parser.add_argument("--budget-usd", type=float, default=0.25)
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    repo_root = os.path.realpath(
        os.path.dirname(os.path.dirname(os.path.dirname(SPIKE_DIR)))
    )
    raw_real = os.path.realpath(args.raw_dir)
    if raw_real == repo_root or raw_real.startswith(repo_root + os.sep):
        raise SystemExit("raw dir must live outside the repository")
    return run_capture(
        args.case, raw_real, args.model, args.budget_usd, args.timeout
    )


if __name__ == "__main__":
    sys.exit(main())
