"""Git plumbing and push-target resolution."""

import re
import subprocess
from dataclasses import dataclass

ZERO_SHA = "0" * 40
_SHA_RE = re.compile(r"^[0-9a-f]{40,64}$")


class TargetError(Exception):
    """The push updates or refs cannot form one review target. Exit code 2."""


@dataclass
class ReviewTarget:
    base: str
    head: str
    tree: str
    local_ref: str
    branch: str


def run_git(repo_root, args, check=True):
    completed = subprocess.run(
        ["git", "-C", repo_root] + args,
        capture_output=True,
        text=True,
    )
    if check and completed.returncode != 0:
        raise TargetError(
            "git %s failed: %s" % (" ".join(args), completed.stderr.strip())
        )
    return completed.stdout.strip()


def repo_toplevel(path):
    completed = subprocess.run(
        ["git", "-C", path, "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise TargetError("not a Git repository: %s" % path)
    return completed.stdout.strip()


def is_valid_sha(value):
    return bool(_SHA_RE.fullmatch(value or ""))


def branch_from_ref(local_ref):
    branch = local_ref
    if branch.startswith("refs/heads/"):
        branch = branch[len("refs/heads/"):]
    if not branch or branch == "HEAD":
        branch = "detached"
    return re.sub(r"[/\s]", "-", branch)


def parse_push_updates(updates_text):
    """Parse Git pre-push standard input into at most one branch update.

    Returns None when nothing needs review (deletes, tags only). Raises
    TargetError for shapes the gate refuses.
    """
    selected = None
    branch_updates = 0
    for line in updates_text.splitlines():
        fields = line.split()
        if len(fields) != 4:
            if line.strip():
                raise TargetError("malformed push update: %r" % line)
            continue
        local_ref, local_sha, remote_ref, remote_sha = fields
        if local_sha == ZERO_SHA:
            continue
        if not (local_ref.startswith("refs/heads/") or local_ref == "HEAD"):
            if remote_ref.startswith("refs/heads/"):
                raise TargetError("%s updates a branch" % local_ref)
            continue
        branch_updates += 1
        if selected is None:
            selected = (local_ref, local_sha, remote_ref, remote_sha)
    if selected is None:
        return None
    if branch_updates > 1:
        raise TargetError("push one branch at a time")
    return selected


def resolve_base(repo_root, policy, head, remote_sha):
    """Resolve the review base, or None when no trustworthy base exists.

    Guessing a base (head's parent, or head itself) silently reviews a
    partial range and caches it as full coverage. No base is a refusal,
    never a guess.
    """
    if remote_sha and remote_sha != ZERO_SHA:
        return remote_sha
    completed = subprocess.run(
        ["git", "-C", repo_root, "merge-base", policy.default_base, head],
        capture_output=True,
        text=True,
    )
    if completed.returncode == 0:
        return completed.stdout.strip()
    return None


def resolve_target(repo_root, policy, base, head, local_ref):
    head_sha = run_git(repo_root, ["rev-parse", "%s^{commit}" % head])
    if base:
        base_sha = run_git(repo_root, ["rev-parse", "%s^{commit}" % base])
    else:
        base_sha = resolve_base(repo_root, policy, head_sha, None)
    tree = run_git(repo_root, ["rev-parse", "%s^{tree}" % head_sha])
    return ReviewTarget(
        base=base_sha,
        head=head_sha,
        tree=tree,
        local_ref=local_ref,
        branch=branch_from_ref(local_ref),
    )


def current_local_ref(repo_root):
    ref = run_git(repo_root, ["symbolic-ref", "-q", "HEAD"], check=False)
    return ref or "HEAD"


def upstream_sha(repo_root):
    completed = subprocess.run(
        ["git", "-C", repo_root, "rev-parse", "@{upstream}"],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def diff_text(repo_root, from_sha, to_sha, paths=None):
    args = ["diff", "--no-color", from_sha, to_sha]
    if paths:
        args += ["--"] + list(paths)
    return run_git(repo_root, args)


def changed_files(repo_root, from_sha, to_sha):
    # NUL-delimited output: a quoted name like "na\303\257ve.py" would
    # match nothing as a pathspec and silently drop the file from the
    # reviewed diff and the sensitive-path check.
    completed = subprocess.run(
        ["git", "-C", repo_root, "diff", "--name-only", "-z", from_sha, to_sha],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise TargetError(
            "git diff --name-only failed: %s" % completed.stderr.strip()
        )
    return [name for name in completed.stdout.split("\0") if name]


def is_ancestor(repo_root, maybe_ancestor, descendant):
    completed = subprocess.run(
        [
            "git",
            "-C",
            repo_root,
            "merge-base",
            "--is-ancestor",
            maybe_ancestor,
            descendant,
        ],
        capture_output=True,
    )
    return completed.returncode == 0
