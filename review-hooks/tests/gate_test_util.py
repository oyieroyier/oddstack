"""Shared fixtures for review_gate tests.

Tests call the public command (`bin/review-gate`) against throwaway Git
repositories with fake reviewer executables. They never import internal
functions.
"""

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

MODULE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REVIEW_GATE = os.path.join(MODULE_ROOT, "bin", "review-gate")

SAFE_RESULT = {
    "schema_version": 1,
    "verdict": "SAFE",
    "risk_class": "none",
    "findings": [],
    "limitations": [],
}

MERGE_WITH_FIXES_RESULT = {
    "schema_version": 1,
    "verdict": "MERGE-WITH-FIXES",
    "risk_class": "general",
    "findings": [{
        "severity": "SHOULD-FIX",
        "file": "README.md",
        "line": 1,
        "trigger": "a non-blocking defect remains",
        "consequence": "the finding could be lost after publication",
        "fix": "record it in repository-owned durable intake",
    }],
    "limitations": [],
}

BLOCKING_RESULT = {
    "schema_version": 1,
    "verdict": "MERGE-WITH-FIXES",
    "risk_class": "security-money",
    "findings": [{
        "severity": "MUST-FIX",
        "file": "README.md",
        "line": 1,
        "trigger": "test trigger",
        "consequence": "test consequence",
        "fix": "test fix",
    }],
    "limitations": [],
}

INCONCLUSIVE_RESULT = {
    "schema_version": 1,
    "verdict": "INCONCLUSIVE",
    "risk_class": "none",
    "findings": [],
    "limitations": ["test limitation"],
}


def cli_envelope(result_text, total_cost_usd=0.0123):
    """The claude CLI's -p --output-format json stdout envelope."""
    return json.dumps({
        "type": "result",
        "result": result_text,
        "session_id": "fake-session",
        "total_cost_usd": total_cost_usd,
    })


def result_script(result, total_cost_usd=0.0123):
    """A fake reviewer that consumes stdin, counts calls, prints a result."""
    result_text = "\n".join([
        "some review prose",
        "REVIEW-RESULT-BEGIN",
        json.dumps(result),
        "REVIEW-RESULT-END",
    ])
    envelope = cli_envelope(result_text, total_cost_usd)
    return textwrap.dedent("""\
        #!/usr/bin/env bash
        if [ -n "${FAKE_PROMPT_COPY:-}" ]; then
          cat > "$FAKE_PROMPT_COPY"
        else
          cat >/dev/null
        fi
        echo "$$" >> "$FAKE_CALL_LOG"
        cat <<'ENVELOPE'
        %s
        ENVELOPE
    """) % envelope


class GateTestCase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="review-gate-test-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.repo = os.path.join(self.root, "repo")
        self._git_init(self.repo)
        self.call_log = os.path.join(self.root, "calls.log")
        self.base_env = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": self.root,
            "FAKE_CALL_LOG": self.call_log,
        }

    def _git_init(self, path):
        os.makedirs(path, exist_ok=True)
        self._git(path, "init", "-q", "--initial-branch=main")
        self._git(path, "config", "user.name", "Review Gate Test")
        self._git(path, "config", "user.email", "gate@example.invalid")
        self.write_file(os.path.join(path, "README.md"), "base\n")
        self._git(path, "add", "README.md")
        self._git(path, "commit", "-qm", "Initial")

    def _git(self, path, *args):
        subprocess.run(
            ["git", "-C", path] + list(args), check=True, capture_output=True
        )

    def git_out(self, *args):
        return subprocess.run(
            ["git", "-C", self.repo] + list(args),
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def write_file(self, path, content):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)

    def commit_change(self, name="change.txt", content="change\n", message="Change"):
        self.write_file(os.path.join(self.repo, name), content)
        self._git(self.repo, "add", name)
        self._git(self.repo, "commit", "-qm", message)
        return self.git_out("rev-parse", "HEAD")

    def write_profile(self, fake_bin, extra=""):
        profile = textwrap.dedent("""\
            REVIEW_HOOKS_PROFILE_VERSION=2
            AI_REVIEW_ENABLED=1
            AI_REVIEW_CREDENTIAL_SCOPE=ci
            AI_REVIEW_MODEL='test-model'
            AI_REVIEW_PUSH_MODE=run-if-missing
            AI_REVIEW_TOTAL_TIMEOUT=30
            AI_REVIEW_KILL_GRACE=2
            AI_REVIEW_ROLLING_SPEND_LIMIT_USD=0
            AI_REVIEW_CLAUDE_BIN='%s'
        """) % fake_bin
        self.write_file(
            os.path.join(self.repo, ".review-hooks.conf"), profile + extra
        )

    def write_fake_bin(self, script, name="fake-claude"):
        path = os.path.join(self.root, name)
        self.write_file(path, script)
        os.chmod(path, 0o755)
        return path

    def run_gate(self, *args, env_extra=None, cwd=None, gate=None):
        env = dict(os.environ)
        env.update(self.base_env)
        if env_extra:
            env.update(env_extra)
        return subprocess.run(
            [gate or REVIEW_GATE] + list(args),
            cwd=cwd or self.repo,
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def updates_file(self, head, remote_sha=None, ref="refs/heads/main"):
        if remote_sha is None:
            remote_sha = "0" * 40
        path = os.path.join(self.root, "updates.txt")
        self.write_file(
            path, "%s %s %s %s\n" % (ref, head, ref, remote_sha)
        )
        return path

    def call_count(self):
        try:
            with open(self.call_log, "r", encoding="utf-8") as handle:
                return len([line for line in handle if line.strip()])
        except OSError:
            return 0

    def run_dirs(self):
        runs = os.path.join(self.repo, "ai-reviews", "runs")
        try:
            return sorted(os.listdir(runs))
        except OSError:
            return []

    def load_run_record(self, run_id):
        path = os.path.join(
            self.repo, "ai-reviews", "runs", run_id, "run.json"
        )
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)

    def latest_run_record(self):
        runs = self.run_dirs()
        self.assertTrue(runs, "expected at least one evidence run")
        return self.load_run_record(runs[-1])

    def cache_entries(self):
        cache = os.path.join(self.repo, "ai-reviews", "cache")
        try:
            return sorted(
                name for name in os.listdir(cache) if name.endswith(".json")
            )
        except OSError:
            return []
