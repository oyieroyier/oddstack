"""Public command interface: review, check-push, acknowledge."""

import argparse
import os
import sys

from .core import EXIT_INCONCLUSIVE, Gate, error
from .evidence import RunEvidence
from .gitwork import TargetError, repo_toplevel
from .policy import PolicyError, load_policy


def build_parser():
    parser = argparse.ArgumentParser(
        prog="review-gate",
        description=(
            "Aggregate adversarial review gate. Exit 0: accepted. "
            "Exit 1: completed review with blocking findings. "
            "Exit 2: no trustworthy decision."
        ),
    )
    parser.add_argument(
        "--repo", default=os.getcwd(), help="target repository path"
    )
    commands = parser.add_subparsers(dest="command", required=True)

    review = commands.add_parser(
        "review",
        help="local preflight: review one exact base/tree pair now",
    )
    review.add_argument("--base", default="", help="base commit (default: upstream)")
    review.add_argument("--head", default="HEAD", help="head commit")
    review.add_argument("--local-ref", default="", help="local ref name")

    check_push = commands.add_parser(
        "check-push",
        help="convert one git push update into a review decision",
    )
    check_push.add_argument(
        "--updates-file", required=True, help="captured pre-push stdin"
    )
    check_push.add_argument(
        "--mode",
        choices=("verify", "run-if-missing"),
        default=None,
        help="override the profile push mode",
    )

    acknowledge = commands.add_parser(
        "acknowledge",
        help="record a human decision bound to one exact report",
    )
    acknowledge.add_argument("--report", required=True, help="report.md path")
    acknowledge.add_argument(
        "--reason", required=True, help="ticket or reason for the decision"
    )
    return parser


def main(argv=None, environ=None):
    if environ is None:
        environ = os.environ
    args = build_parser().parse_args(argv)

    try:
        repo_root = repo_toplevel(args.repo)
    except TargetError as err:
        error("INCONCLUSIVE: %s" % err)
        return EXIT_INCONCLUSIVE

    try:
        policy = load_policy(environ)
    except PolicyError as err:
        _write_refusal_evidence(repo_root, args.command, "invalid_policy", str(err))
        error("INCONCLUSIVE: %s" % err)
        return EXIT_INCONCLUSIVE

    try:
        gate = Gate(repo_root, policy, environ)
        if args.command == "review":
            return gate.review(args.base, args.head, args.local_ref)
        if args.command == "check-push":
            return gate.check_push(args.updates_file, args.mode)
        return gate.acknowledge(args.report, args.reason)
    except TargetError as err:
        error("INCONCLUSIVE: %s" % err)
        return EXIT_INCONCLUSIVE
    except KeyboardInterrupt:
        error("INCONCLUSIVE: interrupted")
        return EXIT_INCONCLUSIVE


def _write_refusal_evidence(repo_root, invocation, reason_code, detail):
    try:
        ev = RunEvidence(repo_root, invocation)
        ev.finalize(
            {"decision": {"reason_code": reason_code}},
            ev.render_failure_report(None, reason_code, detail),
        )
    except OSError:
        # Evidence is best effort here; the refusal itself still holds.
        pass


if __name__ == "__main__":
    sys.exit(main())
