"""Reviewer process supervision.

The supervisor starts the reviewer in a new session (its own process
group), feeds the prompt through a file handle, drains bounded pipes with
selectors, and reaps the whole group on every exit path. It uses the
monotonic clock; the run deadline never resets.

A POSIX process group cannot contain a child that deliberately calls
setsid(). Containment claims stay scoped to the process group.
"""

import os
import selectors
import shutil
import signal
import subprocess
import tempfile
import time
from dataclasses import dataclass, field

_DRAIN_CHUNK = 65536
_VERIFY_WINDOW = 1.0
_VERIFY_STEP = 0.02


@dataclass
class AttemptOutcome:
    argv: list
    started: bool = False
    launch_error: str = ""
    exit_code: int = None
    term_signal: int = None
    duration: float = 0.0
    stdout_data: bytes = b""
    stderr_data: bytes = b""
    stdout_total: int = 0
    stderr_total: int = 0
    overflow: bool = False
    timed_out: bool = False
    interrupted: bool = False
    cleanup_verified: bool = True
    cleanup_detail: str = "no process started"
    pid: int = None


class _PipeDrain:
    def __init__(self, cap):
        self.cap = cap
        self.data = bytearray()
        self.total = 0

    def feed(self, chunk):
        self.total += len(chunk)
        room = self.cap + 1 - len(self.data)
        if room > 0:
            self.data.extend(chunk[:room])


def _group_gone(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def _signal_group(pgid, signum):
    try:
        os.killpg(pgid, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        pass


def run_attempt(argv, prompt_text, deadline, stdout_cap, kill_grace,
                stderr_cap=16384, environ=None):
    """Run one reviewer attempt under the shared monotonic deadline.

    `deadline` is an absolute time.monotonic() value. Returns an
    AttemptOutcome; never raises for reviewer behavior. KeyboardInterrupt
    is recorded as an interrupted outcome after cleanup.
    """
    if environ is None:
        environ = os.environ
    outcome = AttemptOutcome(argv=list(argv))
    started_at = time.monotonic()

    work_dir = tempfile.mkdtemp(prefix="review-gate-")
    os.chmod(work_dir, 0o700)
    prompt_path = os.path.join(work_dir, "prompt.txt")
    proc = None
    prompt_handle = None
    stdout_drain = _PipeDrain(stdout_cap)
    stderr_drain = _PipeDrain(stderr_cap)

    try:
        with open(prompt_path, "w", encoding="utf-8") as handle:
            handle.write(prompt_text)
        prompt_handle = open(prompt_path, "rb")

        try:
            proc = subprocess.Popen(
                argv,
                stdin=prompt_handle,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=work_dir,
                env=dict(environ),
                start_new_session=True,
            )
        except (FileNotFoundError, PermissionError, OSError) as error:
            outcome.launch_error = str(error)
            outcome.cleanup_detail = "launch failed; no process started"
            outcome.duration = time.monotonic() - started_at
            return outcome

        outcome.started = True
        outcome.pid = proc.pid
        pgid = proc.pid

        sel = selectors.DefaultSelector()
        sel.register(proc.stdout, selectors.EVENT_READ, stdout_drain)
        sel.register(proc.stderr, selectors.EVENT_READ, stderr_drain)
        open_pipes = 2

        try:
            while True:
                now = time.monotonic()
                if now >= deadline:
                    outcome.timed_out = True
                    break
                if outcome.overflow:
                    break
                # The group counts as active while any pipe stays open,
                # even after the direct child exits.
                if open_pipes == 0 and proc.poll() is not None:
                    break
                wait = min(0.2, max(0.01, deadline - now))
                for key, _ in sel.select(wait):
                    chunk = os.read(key.fileobj.fileno(), _DRAIN_CHUNK)
                    if not chunk:
                        sel.unregister(key.fileobj)
                        key.fileobj.close()
                        open_pipes -= 1
                        continue
                    key.data.feed(chunk)
                    # The cap covers combined captured output; stderr
                    # cannot smuggle an unbounded stream past it.
                    if (
                        stdout_drain.total > stdout_cap
                        or stdout_drain.total + stderr_drain.total
                        > stdout_cap + stderr_cap
                    ):
                        outcome.overflow = True
        except KeyboardInterrupt:
            outcome.interrupted = True
        finally:
            clean_exit = (
                not outcome.timed_out
                and not outcome.overflow
                and not outcome.interrupted
                and open_pipes == 0
                and proc.poll() is not None
            )
            # One cleanup budget for the whole kill sequence: the grace
            # for SIGTERM plus a short fixed allowance to reap SIGKILL.
            cleanup_deadline = time.monotonic() + kill_grace
            if not clean_exit:
                _signal_group(pgid, signal.SIGTERM)
                try:
                    proc.wait(
                        timeout=max(0.1, cleanup_deadline - time.monotonic())
                    )
                except subprocess.TimeoutExpired:
                    pass
                except KeyboardInterrupt:
                    outcome.interrupted = True
                if not _group_gone(pgid) or proc.poll() is None:
                    _signal_group(pgid, signal.SIGKILL)
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
                except KeyboardInterrupt:
                    outcome.interrupted = True

            # Final bounded drain for diagnostics after the kill sequence.
            try:
                for key in list(sel.get_map().values()):
                    try:
                        os.set_blocking(key.fileobj.fileno(), False)
                        while True:
                            chunk = os.read(key.fileobj.fileno(), _DRAIN_CHUNK)
                            if not chunk:
                                break
                            key.data.feed(chunk)
                    except (BlockingIOError, OSError, ValueError):
                        pass
                    try:
                        sel.unregister(key.fileobj)
                        key.fileobj.close()
                    except (KeyError, OSError, ValueError):
                        pass
            except KeyboardInterrupt:
                # A second Ctrl-C must not skip the kill or the evidence.
                outcome.interrupted = True
            sel.close()

        verified = False
        try:
            if proc.poll() is None or not _group_gone(pgid):
                # Covers a lingering group member that closed its pipes
                # and survived a clean-looking child exit.
                _signal_group(pgid, signal.SIGKILL)
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass

            verify_until = time.monotonic() + _VERIFY_WINDOW
            while time.monotonic() < verify_until:
                if proc.poll() is not None and _group_gone(pgid):
                    verified = True
                    break
                time.sleep(_VERIFY_STEP)
        except KeyboardInterrupt:
            outcome.interrupted = True
            _signal_group(pgid, signal.SIGKILL)
            verified = proc.poll() is not None and _group_gone(pgid)

        if environ.get("REVIEW_GATE_TEST_CLEANUP_FAULT") == "1":
            # Documented test hook: prove the unverified-cleanup path
            # without needing an unkillable process.
            verified = False
            outcome.cleanup_detail = "test-forced cleanup fault"
        elif verified:
            outcome.cleanup_detail = "process group reaped and verified gone"
        else:
            outcome.cleanup_detail = "process group may have survived cleanup"

        outcome.cleanup_verified = verified
        rc = proc.returncode
        if rc is not None and rc < 0:
            outcome.term_signal = -rc
        else:
            outcome.exit_code = rc
        return outcome
    finally:
        outcome.duration = time.monotonic() - started_at
        outcome.stdout_data = bytes(stdout_drain.data)
        outcome.stderr_data = bytes(stderr_drain.data)
        outcome.stdout_total = stdout_drain.total
        outcome.stderr_total = stderr_drain.total
        if prompt_handle is not None:
            try:
                prompt_handle.close()
            except OSError:
                pass
        # Diagnostics live in the returned buffers; the work directory
        # (including the prompt) must not outlive the attempt.
        shutil.rmtree(work_dir, ignore_errors=True)
