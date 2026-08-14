#!/usr/bin/env python3
"""Report what a Claude Code session transcript costs to keep alive.

Every request re-sends the whole conversation and the cached prefix bills at
read rate on every turn, so cumulative cost is roughly turns x context and
rises with the square of session length. This script measures that from the
transcript and recommends a handoff only when the session is both expensive
and drifted off the files it started on. Expensive alone is not a reason: a
long session on one task is the prompt cache working correctly.

It never ends a session, never compacts, never edits a prompt, and in --hook
mode always exits zero; advice that could block a turn would be worse than no
advice. Pricing comes solely from modelRates in the user preferences; without
an entry the report is tokens-only rather than a guess.
"""

import argparse
import json
import math
import pathlib
import sys

import resolve_config

REBUILD_CACHE_MISS_RATIO = 0.5


def as_int(value):
    """Token counts from a transcript; null, NaN, Infinity, or junk counts as zero."""
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
    ):
        return 0
    return int(value)


def parse_transcript(path):
    calls = []
    call_index = {}
    file_events = []

    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(entry, dict) or entry.get("type") != "assistant":
                continue
            message = entry.get("message")
            if not isinstance(message, dict):
                continue

            for block in message.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    block_input = block.get("input")
                    if isinstance(block_input, dict):
                        for key in ("file_path", "path", "notebook_path"):
                            value = block_input.get(key)
                            if isinstance(value, str) and value:
                                file_events.append(value)
                                break

            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue
            creation = usage.get("cache_creation")
            creation = creation if isinstance(creation, dict) else {}
            call = {
                "model": message.get("model") or "unknown",
                "input": as_int(usage.get("input_tokens")),
                "output": as_int(usage.get("output_tokens")),
                "cache_read": as_int(usage.get("cache_read_input_tokens")),
                "write_5m": as_int(
                    creation.get(
                        "ephemeral_5m_input_tokens",
                        usage.get("cache_creation_input_tokens"),
                    )
                ),
                "write_1h": as_int(creation.get("ephemeral_1h_input_tokens")),
            }
            # Streaming writes one line per content block with the same usage;
            # collapse them to one API call keyed by requestId.
            request_id = entry.get("requestId")
            if request_id and request_id in call_index:
                calls[call_index[request_id]] = call
            else:
                if request_id:
                    call_index[request_id] = len(calls)
                calls.append(call)

    return calls, file_events


def context_of(call):
    return call["input"] + call["cache_read"] + call["write_5m"] + call["write_1h"]


def file_drift(file_events):
    if len(file_events) < 2:
        return 0.0
    midpoint = len(file_events) // 2
    early = set(file_events[:midpoint])
    late = set(file_events[midpoint:])
    union = early | late
    if not union:
        return 0.0
    return round(1.0 - len(early & late) / len(union), 2)


def analyze(calls, file_events, rates):
    totals = {
        "turns": len(calls),
        "rebuilds": 0,
        "peak_context": 0,
        "cache_read": 0,
        "write_5m": 0,
        "write_1h": 0,
        "cost_usd": 0.0,
        "unpriced_models": set(),
        "marginal_usd": None,
        "drift": file_drift(file_events),
    }
    previous_context = None
    for call in calls:
        context = context_of(call)
        totals["peak_context"] = max(totals["peak_context"], context)
        if previous_context and call["cache_read"] < REBUILD_CACHE_MISS_RATIO * previous_context:
            totals["rebuilds"] += 1
        previous_context = context
        totals["cache_read"] += call["cache_read"]
        totals["write_5m"] += call["write_5m"]
        totals["write_1h"] += call["write_1h"]

        rate = rates.get(call["model"])
        if rate is None:
            totals["unpriced_models"].add(call["model"])
            continue
        per_million = (
            call["input"] * rate["input"]
            + call["output"] * rate["output"]
            + call["cache_read"] * rate["cacheRead"]
            + call["write_5m"] * rate["cacheWrite5m"]
            + call["write_1h"] * rate["cacheWrite1h"]
        )
        totals["cost_usd"] += per_million / 1_000_000

    if calls:
        last = calls[-1]
        rate = rates.get(last["model"])
        if rate is not None:
            totals["marginal_usd"] = context_of(last) * rate["cacheRead"] / 1_000_000
    totals["unpriced_models"] = sorted(totals["unpriced_models"])
    return totals


def recommendation(totals, billing, expensive_usd, expensive_cache_read, drift_threshold):
    if totals["unpriced_models"] or billing != "api":
        expensive = totals["cache_read"] >= expensive_cache_read
    else:
        expensive = totals["cost_usd"] >= expensive_usd
    drifted = totals["drift"] >= drift_threshold
    if expensive and drifted:
        return (
            "This session is expensive and has drifted off the files it started "
            "on; consider /session-handoff to continue in a fresh session."
        )
    return None


def render(totals, billing, advice):
    lines = [
        "Turns: {turns:,}   Rebuilds: {rebuilds:,}   Peak context: {peak:,} tokens".format(
            turns=totals["turns"], rebuilds=totals["rebuilds"], peak=totals["peak_context"]
        ),
        "Cache: {read:,} read, {w5:,} written (5m), {w1:,} written (1h)".format(
            read=totals["cache_read"], w5=totals["write_5m"], w1=totals["write_1h"]
        ),
    ]
    if totals["unpriced_models"]:
        lines.append(
            "Cost: tokens only; no modelRates entry for "
            + ", ".join(totals["unpriced_models"])
            + " (add one under modelRates in preferences.json to price this)"
        )
    else:
        suffix = (
            "actual API billing" if billing == "api" else "API-equivalent (not charged on a plan)"
        )
        lines.append("Cost: ${:,.2f} {}".format(totals["cost_usd"], suffix))
        if totals["marginal_usd"] is not None:
            lines.append(
                "Each further turn re-reads the context for about ${:,.2f}".format(
                    totals["marginal_usd"]
                )
            )
    lines.append("File drift: {:.2f}".format(totals["drift"]))
    if advice:
        lines.append(advice)
    return "\n".join(lines)


def load_rates(preferences_path):
    path = preferences_path or resolve_config.default_preferences_path()
    if not path or not pathlib.Path(path).is_file():
        return {}
    preferences = resolve_config.load_json(pathlib.Path(path), "preferences")
    if not isinstance(preferences, dict):
        return {}
    return resolve_config.load_model_rates(preferences)


def advise(args, totals):
    return recommendation(
        totals,
        args.billing,
        args.expensive_usd,
        args.expensive_cache_read_tokens,
        args.drift_threshold,
    )


def main():
    # The exit-zero guarantee must cover argument parsing too: a typo in the
    # configured hook command (argparse exits 2) must never block a turn.
    hook_requested = "--hook" in sys.argv[1:]
    try:
        return run()
    except BaseException:
        if hook_requested:
            return 0
        raise


def run():
    # allow_abbrev stays off so an abbreviation like --hoo cannot enter hook
    # mode while the literal --hook scan in main() misses it.
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--transcript", type=pathlib.Path)
    parser.add_argument("--preferences", type=pathlib.Path)
    parser.add_argument("--billing", choices=("plan", "api"), default="plan")
    parser.add_argument("--expensive-usd", type=float, default=25.0)
    parser.add_argument("--expensive-cache-read-tokens", type=int, default=25_000_000)
    parser.add_argument("--drift-threshold", type=float, default=0.6)
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--hook",
        action="store_true",
        help="read hook JSON on stdin, surface advice as systemMessage, always exit 0",
    )
    args = parser.parse_args()

    transcript = args.transcript
    if args.hook:
        # Advice that could block a turn would be worse than no advice, so
        # hook mode swallows every failure — bad stdin, unreadable transcript,
        # malformed preferences, anything — and exits zero.
        try:
            payload = json.load(sys.stdin)
            transcript = pathlib.Path(payload["transcript_path"])
            calls, file_events = parse_transcript(transcript)
            totals = analyze(calls, file_events, load_rates(args.preferences))
            advice = advise(args, totals)
            if advice:
                json.dump({"systemMessage": advice}, sys.stdout)
                print()
        except Exception:
            pass
        return 0
    if transcript is None:
        parser.error("--transcript is required outside --hook mode")

    try:
        calls, file_events = parse_transcript(transcript)
    except OSError as error:
        print(f"error: cannot read transcript: {error}", file=sys.stderr)
        return 1

    totals = analyze(calls, file_events, load_rates(args.preferences))
    advice = advise(args, totals)

    if args.json:
        totals["recommendation"] = advice
        json.dump(totals, sys.stdout, indent=2, sort_keys=True)
        print()
        return 0
    print(render(totals, args.billing, advice))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except resolve_config.PolicyError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
