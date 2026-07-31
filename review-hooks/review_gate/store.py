"""Decision cache, branch state, spend ledger, and acknowledgements.

All writes are atomic: temp file in the destination directory, then
os.replace. Malformed or moved state is ignored and recorded; it is never
a reason to paste unknown content into a prompt.
"""

import fcntl
import hashlib
import json
import math
import os
import re
import tempfile
import time

from . import ACK_SCHEMA_VERSION, CACHE_SCHEMA_VERSION, STATE_SCHEMA_VERSION


def out_dir(repo_root):
    return os.path.join(repo_root, "ai-reviews")


def atomic_write_text(path, text):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temp_path, path)
    except BaseException:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def atomic_write_json(path, data):
    atomic_write_text(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


def _load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cache_key(base, tree, policy_hash, prompt_template_version, identity):
    return sha256_text(
        "\n".join([base, tree, policy_hash, prompt_template_version, identity])
    )


class DecisionCache:
    def __init__(self, repo_root):
        self.directory = os.path.join(out_dir(repo_root), "cache")

    def path(self, key):
        return os.path.join(self.directory, "%s.json" % key)

    def load(self, key):
        entry = _load_json(self.path(key))
        if not isinstance(entry, dict):
            return None
        if entry.get("schema_version") != CACHE_SCHEMA_VERSION:
            return None
        if entry.get("verdict") not in (
            "SAFE",
            "MERGE-WITH-FIXES",
            "DO-NOT-MERGE",
        ):
            # Only completed reviews may act as decisions.
            return None
        return entry

    def write(self, key, entry):
        entry = dict(entry)
        entry["schema_version"] = CACHE_SCHEMA_VERSION
        atomic_write_json(self.path(key), entry)


class LegacyCache:
    """Read-only view of version 1 markdown cache entries.

    Only the compatibility path (profile version 1) consults these.
    """

    def __init__(self, repo_root):
        self.directory = os.path.join(out_dir(repo_root), "cache")

    def load(self, base, tree):
        key = sha256_text("%s:%s" % (base, tree))
        path = os.path.join(self.directory, "%s.md" % key)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            return None
        lines = [line for line in text.splitlines() if line.strip()]
        tail = lines[-3:]
        if len(tail) != 3:
            return None
        markers = {}
        for line, marker in zip(tail, ("VERDICT", "BLOCKERS", "RISK-CLASS")):
            match = re.fullmatch(
                r"%s: (.+)" % re.escape(marker), line.strip()
            )
            if match is None:
                return None
            markers[marker] = match.group(1)
        if markers["VERDICT"] not in ("SAFE", "MERGE-WITH-FIXES", "DO-NOT-MERGE"):
            return None
        if markers["BLOCKERS"] not in ("yes", "no"):
            return None
        return {
            "verdict": markers["VERDICT"],
            "blocking": (
                markers["BLOCKERS"] == "yes"
                or markers["VERDICT"] == "DO-NOT-MERGE"
            ),
            "risk_class": markers["RISK-CLASS"],
            "report_path": path,
            "parser": "legacy-v1",
        }


class BranchState:
    def __init__(self, repo_root):
        self.directory = os.path.join(out_dir(repo_root), "state")

    def path(self, branch):
        # The sanitized name alone collides (feature/x vs feature-x); a
        # short digest of the raw name keeps state files distinct.
        return os.path.join(
            self.directory,
            "%s-%s.json" % (branch, sha256_text(branch)[:8]),
        )

    def load(self, branch):
        state = _load_json(self.path(branch))
        if not isinstance(state, dict):
            return None
        if state.get("schema_version") != STATE_SCHEMA_VERSION:
            return None
        required = ("base", "head", "report_path", "report_digest", "open_findings")
        if any(key not in state for key in required):
            return None
        if not isinstance(state["open_findings"], list):
            return None
        try:
            if sha256_file(state["report_path"]) != state["report_digest"]:
                return None
        except OSError:
            return None
        return state

    def write(self, branch, state):
        state = dict(state)
        state["schema_version"] = STATE_SCHEMA_VERSION
        atomic_write_json(self.path(branch), state)


class SpendLedger:
    def __init__(self, repo_root):
        self.path = os.path.join(out_dir(repo_root), "spend", "ledger.jsonl")

    @staticmethod
    def _window_total(handle, window_hours, now):
        """Sum recorded spend inside the window.

        Counts the assigned cap when actual use is unknown. A run may
        appear more than once (a reservation, then a settlement); only
        the newest entry per run id counts. Malformed lines are skipped;
        the ledger is advisory evidence, not a financial record.
        """
        cutoff = now - window_hours * 3600
        total = 0.0
        by_run = {}
        for line in handle:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(entry, dict):
                continue
            timestamp = entry.get("timestamp")
            if not isinstance(timestamp, (int, float)):
                continue
            if timestamp < cutoff:
                continue
            # A non-finite number would poison the sum and make every
            # limit comparison false, disabling the gate; treat it as
            # absent and fall back conservatively.
            actual = entry.get("actual_usd")
            assigned = entry.get("assigned_usd")
            charge = None
            if isinstance(actual, (int, float)) and math.isfinite(actual):
                charge = actual
            elif isinstance(assigned, (int, float)) and math.isfinite(assigned):
                charge = assigned
            if charge is None:
                continue
            run_id = entry.get("run_id")
            if isinstance(run_id, str) and run_id:
                by_run[run_id] = float(charge)
            else:
                total += float(charge)
        return total + sum(by_run.values())

    def reserve(self, run_id, assigned_usd, limit_usd, window_hours):
        """Atomically check the rolling window and record a reservation.

        The reservation lands before any reviewer launches, so a crash
        mid-run can never leave paid spend unrecorded, and two
        concurrent runs cannot both squeeze under the limit. Returns
        (True, window_total) when reserved, (False, window_total) when
        the limit refuses the run. A reservation is never reclaimed.
        """
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        now = time.time()
        with open(self.path, "a+", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                handle.seek(0)
                total = self._window_total(handle, window_hours, now)
                if limit_usd > 0 and total + assigned_usd > limit_usd:
                    return False, total
                handle.seek(0, os.SEEK_END)
                handle.write(json.dumps({
                    "timestamp": now,
                    "run_id": run_id,
                    "assigned_usd": assigned_usd,
                    "actual_usd": None,
                }, sort_keys=True, allow_nan=False) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
                return True, total
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def settle(self, run_id, actual_usd):
        """Record trustworthy actual spend for a reserved run.

        Appends a settlement entry stamped at settle time; the window
        sum keeps only the newest entry per run id, so the settlement
        supersedes the reservation without rewriting it, and the spend
        stays in the window at least as long as the reservation would
        have. The amount rounds up, never down. Any failure mid-settle —
        including filesystem errors — leaves the conservative
        reservation standing and returns False; a completed review is
        never voided over this advisory record.
        """
        if isinstance(actual_usd, bool):
            return False
        if not isinstance(actual_usd, (int, float)):
            return False
        if not math.isfinite(actual_usd) or actual_usd < 0:
            return False
        try:
            with open(self.path, "a+", encoding="utf-8") as handle:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
                try:
                    handle.seek(0)
                    reserved = False
                    assigned = None
                    for line in handle:
                        try:
                            entry = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if not isinstance(entry, dict):
                            continue
                        if entry.get("run_id") != run_id:
                            continue
                        reserved = True
                        if isinstance(entry.get("assigned_usd"), (int, float)):
                            assigned = entry["assigned_usd"]
                    if not reserved:
                        return False
                    handle.seek(0, os.SEEK_END)
                    handle.write(json.dumps({
                        "timestamp": time.time(),
                        "run_id": run_id,
                        "assigned_usd": assigned,
                        # round() before ceil kills binary-float fuzz
                        # (0.0375 * 10000 == 375.00000000000006).
                        "actual_usd": math.ceil(
                            round(float(actual_usd) * 10000, 6)
                        ) / 10000,
                    }, sort_keys=True, allow_nan=False) + "\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                    return True
                finally:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        except (OSError, ValueError):
            return False


def ack_digest(report_digest, base, tree, risk_class, policy_hash):
    return sha256_text(
        "\n".join([report_digest, base, tree, risk_class, policy_hash])
    )


class AckStore:
    def __init__(self, repo_root):
        self.directory = os.path.join(out_dir(repo_root), "acks")

    def path(self, digest):
        return os.path.join(self.directory, "%s.json" % digest)

    def load(self, digest):
        ack = _load_json(self.path(digest))
        if not isinstance(ack, dict):
            return None
        if ack.get("schema_version") != ACK_SCHEMA_VERSION:
            return None
        if not isinstance(ack.get("reason"), str) or not ack["reason"].strip():
            return None
        return ack

    def write(self, digest, ack):
        ack = dict(ack)
        ack["schema_version"] = ACK_SCHEMA_VERSION
        atomic_write_json(self.path(digest), ack)
        return self.path(digest)
