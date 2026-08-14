#!/usr/bin/env python3
"""Resolve collaboration configuration for the bundled skills.

Resolution walks skill override -> provider default and stops. A field absent
at every level stays absent, so an unconfigured value falls through to
whatever the CLI itself defaults to; the bundle never invents a model.

A repository may ship .codex-claude-skills.json to tighten policy:
spend-authorizing values may only be lowered and process policy may only be
strengthened. An attempt to widen either is a loud error naming both values,
never a silent clamp.
"""

import argparse
import json
import math
import os
import pathlib
import subprocess
import sys

REPO_POLICY_FILENAME = ".codex-claude-skills.json"

# Fixed by the bundle's opinionated design: each skill resolves against the
# provider it delegates work to. deliberate-with-peer delegates to whichever
# model did not initiate, so it requires an explicit --provider.
SKILL_PROVIDERS = {
    "codex-implementation": "codex",
    "codex-review": "codex",
    "codex-computer-use": "codex",
    "route-codex-subagents": "codex",
    "ui-nitpicker": "codex",
    "delegate-frontend-to-claude": "claude",
    "deliberate-with-peer": None,
}

PROVIDER_FIELDS = ("model", "effort", "billing", "maxBudgetUsd")

POLICY_RANK = {"off": 0, "offer": 1, "required": 2}
POLICY_DEFAULTS = {"peerAudit": "offer"}

# Spend-authorizing keys a repository may lower, and process-policy keys it
# may strengthen. Everything else in a repo policy file is refused loudly:
# nothing checked into a repository can redirect spending or select models
# against a personal account.
REPO_ALLOWED = {
    ("claude", "maxBudgetUsd"): "spend",
    ("codex", "maxBudgetUsd"): "spend",
    ("deliberation", "maxRounds"): "spend",
    ("peerAudit", "policy"): "process",
}

# Anthropic cache billing relative to the base input rate. An entry in
# modelRates may override any of these per model.
CACHE_MULTIPLIERS = {"cacheRead": 0.1, "cacheWrite5m": 1.25, "cacheWrite1h": 2.0}


class PolicyError(Exception):
    pass


def default_preferences_path():
    home = os.environ.get("HOME", "")
    config_root = os.environ.get("XDG_CONFIG_HOME") or (
        str(pathlib.Path(home) / ".config") if home else ""
    )
    if not config_root:
        return None
    return pathlib.Path(config_root) / "codex-claude-skills" / "preferences.json"


def load_json(path, label):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise PolicyError(f"cannot read {label} {path}: {error}")
    except json.JSONDecodeError as error:
        raise PolicyError(f"invalid JSON in {label} {path}: {error}")


def discover_repo_root(repo_input):
    try:
        completed = subprocess.run(
            ["git", "-C", str(repo_input), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    top = completed.stdout.strip()
    return pathlib.Path(top) if completed.returncode == 0 and top else None


def non_negative_number(value):
    # json.loads accepts NaN and Infinity; neither is a budget, rate, or count.
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and value >= 0
    )


def known_policy(value):
    return isinstance(value, str) and value in POLICY_RANK


def validate_repo_policy(repo_policy, repo_path):
    refusal = (
        "a repository can only lower maxBudgetUsd, lower "
        "deliberation.maxRounds, or strengthen peerAudit.policy"
    )
    if not repo_policy:
        raise PolicyError(
            f"{repo_path}: repository policy file sets nothing; remove it or "
            f"declare a tightening ({refusal})"
        )
    for section, fields in repo_policy.items():
        if not isinstance(fields, dict) or not fields:
            raise PolicyError(
                f"{repo_path}: repository policy section {section!r} must be a "
                f"non-empty object of allowed keys; {refusal}"
            )
        for field, value in fields.items():
            if (section, field) not in REPO_ALLOWED:
                raise PolicyError(
                    f"{repo_path}: repository policy may not set "
                    f"{section}.{field}; {refusal}"
                )
            if (section, field) == ("peerAudit", "policy"):
                if not known_policy(value):
                    raise PolicyError(
                        f"{repo_path}: peerAudit.policy must be one of "
                        f"required, offer, off; found {value!r}"
                    )
            elif not non_negative_number(value):
                raise PolicyError(
                    f"{repo_path}: {section}.{field} must be a non-negative "
                    f"number; found {value!r}"
                )


def validate_preferences(preferences, path):
    """Type-check the fields the resolver compares or reports.

    Without this, a malformed user value surfaces later as a raw traceback
    instead of the loud, named error the tightening contract promises.
    Unknown keys stay legal; only known fields are checked.
    """

    def check_fields(owner, fields):
        if not isinstance(fields, dict):
            raise PolicyError(f"{path}: {owner} must be an object; found {fields!r}")
        for field in ("model", "effort", "billing"):
            value = fields.get(field)
            if value is not None and not isinstance(value, str):
                raise PolicyError(
                    f"{path}: {owner}.{field} must be a string; found {value!r}"
                )
        budget = fields.get("maxBudgetUsd")
        if budget is not None and not non_negative_number(budget):
            raise PolicyError(
                f"{path}: {owner}.maxBudgetUsd must be a non-negative number "
                f"or null; found {budget!r}"
            )

    for provider in ("claude", "codex"):
        if preferences.get(provider) is not None:
            check_fields(provider, preferences[provider])
    skills = preferences.get("skills")
    if skills is not None:
        if not isinstance(skills, dict):
            raise PolicyError(f"{path}: skills must be an object; found {skills!r}")
        for name, fields in skills.items():
            if fields is None:
                continue
            check_fields(f"skills.{name}", fields)
    for section in ("peerAudit", "deliberation"):
        block = preferences.get(section)
        if block is not None and not isinstance(block, dict):
            raise PolicyError(f"{path}: {section} must be an object; found {block!r}")
    policy = get_path(preferences, "peerAudit", "policy")
    if policy is not None and not known_policy(policy):
        raise PolicyError(
            f"{path}: peerAudit.policy must be one of required, offer, off; "
            f"found {policy!r}"
        )
    rounds = get_path(preferences, "deliberation", "maxRounds")
    if rounds is not None and not non_negative_number(rounds):
        raise PolicyError(
            f"{path}: deliberation.maxRounds must be a non-negative number; "
            f"found {rounds!r}"
        )


def get_path(data, *key_path):
    value = data
    for part in key_path:
        if not isinstance(value, dict) or part not in value:
            return None
        value = value[part]
    return value


def apply_repo_policy(preferences, repo_policy, repo_path):
    """Merge repo tightening into a resolved copy, refusing any widening.

    Returns (merged, sources, spend_caps). spend_caps records every spend
    ceiling the repository declared — including one equal to the user's own
    value — because a cap must keep bounding per-skill overrides even when it
    changes nothing at the provider level.
    """
    merged = json.loads(json.dumps(preferences))
    sources = {}
    spend_caps = {}
    for (section, field), kind in REPO_ALLOWED.items():
        repo_value = get_path(repo_policy, section, field)
        if repo_value is None:
            continue
        user_value = get_path(preferences, section, field)
        if kind == "spend":
            if user_value is not None and repo_value > user_value:
                raise PolicyError(
                    f"{repo_path}: repository requests {section}.{field}="
                    f"{repo_value} but the user preference is {user_value}; "
                    "a repository may lower a spend control, never raise it"
                )
            if field == "maxBudgetUsd":
                spend_caps[(section, field)] = repo_value
            if user_value is not None and repo_value == user_value:
                continue
        else:
            # An unset operator preference still means the documented default
            # applies; a repository must not weaken below that either.
            baseline = user_value if user_value is not None else POLICY_DEFAULTS[section]
            baseline_label = (
                f"the user preference is {user_value!r}"
                if user_value is not None
                else f"the documented default is {baseline!r}"
            )
            if POLICY_RANK[repo_value] < POLICY_RANK[baseline]:
                raise PolicyError(
                    f"{repo_path}: repository requests {section}.{field}="
                    f"{repo_value!r} but {baseline_label}; a repository may "
                    "strengthen process policy, never weaken it"
                )
            if POLICY_RANK[repo_value] == POLICY_RANK[baseline]:
                continue
        # A null section means unset, same as a null field; it must take the
        # tightening rather than crash the merge.
        if not isinstance(merged.get(section), dict):
            merged[section] = {}
        merged[section][field] = repo_value
        sources[f"{section}.{field}"] = "repo"
    return merged, sources, spend_caps


def load_model_rates(preferences):
    """Return validated modelRates; a malformed entry is dropped, not half-applied."""
    rates = {}
    configured = preferences.get("modelRates")
    if configured is None:
        return rates
    if not isinstance(configured, dict):
        print("warning: modelRates must be an object; ignoring it", file=sys.stderr)
        return rates
    for model, entry in configured.items():
        if (
            not isinstance(entry, dict)
            or not non_negative_number(entry.get("input"))
            or not non_negative_number(entry.get("output"))
            or any(
                key in entry and not non_negative_number(entry[key])
                for key in CACHE_MULTIPLIERS
            )
        ):
            print(
                f"warning: dropping malformed modelRates entry for {model!r}; "
                "expected numeric input and output (USD per million tokens)",
                file=sys.stderr,
            )
            continue
        resolved = {
            "input": float(entry["input"]),
            "output": float(entry["output"]),
        }
        for key, multiplier in CACHE_MULTIPLIERS.items():
            resolved[key] = float(entry.get(key, round(resolved["input"] * multiplier, 10)))
        rates[model] = resolved
    return rates


def resolve_skill(skill, provider, preferences, sources, spend_caps=None):
    if skill not in SKILL_PROVIDERS and provider is None:
        raise PolicyError(
            f"unknown skill {skill!r}; pass --provider claude|codex to resolve it"
        )
    mapped = SKILL_PROVIDERS.get(skill)
    if mapped is not None and provider is not None and provider != mapped:
        raise PolicyError(
            f"{skill} always delegates to {mapped}; --provider is only for "
            "deliberate-with-peer and skills the bundle does not know"
        )
    provider = provider or mapped
    if provider is None:
        raise PolicyError(
            f"{skill} delegates to the non-initiating model; pass --provider "
            "claude or --provider codex for the direction in use"
        )

    resolved = {"skill": skill, "provider": provider, "sources": {}}
    skill_overrides = get_path(preferences, "skills", skill) or {}
    if not isinstance(skill_overrides, dict):
        raise PolicyError(f"preferences skills.{skill} must be an object")
    # An explicit null anywhere means unset: it falls through to the next
    # level, never shadows a provider value, and cannot dodge a repo cap.
    for field in PROVIDER_FIELDS:
        if skill_overrides.get(field) is not None:
            resolved[field] = skill_overrides[field]
            resolved["sources"][field] = f"skills.{skill}"
        elif get_path(preferences, provider, field) is not None:
            resolved[field] = get_path(preferences, provider, field)
            resolved["sources"][field] = sources.get(f"{provider}.{field}", provider)

    # A repository budget cap bounds every per-skill override too — including
    # a cap equal to the provider value, which changes nothing at the provider
    # level but must still stop skills.<name>.maxBudgetUsd from exceeding it.
    repo_cap = (spend_caps or {}).get((provider, "maxBudgetUsd"))
    if (
        repo_cap is not None
        and resolved.get("maxBudgetUsd") is not None
        and resolved["maxBudgetUsd"] > repo_cap
    ):
        resolved["maxBudgetUsd"] = repo_cap
        resolved["sources"]["maxBudgetUsd"] = "repo"
    return resolved


def prune_nulls(value):
    """Nulls mean unset; the resolved view omits them rather than echoing them."""
    if isinstance(value, dict):
        return {key: prune_nulls(child) for key, child in value.items() if child is not None}
    return value


def resolve_policy(name, preferences, sources):
    if name not in POLICY_DEFAULTS:
        raise PolicyError(f"unknown policy {name!r}; known policies: peerAudit")
    configured = get_path(preferences, name, "policy")
    if configured is None:
        return {"policy": POLICY_DEFAULTS[name], "source": "default"}
    if not known_policy(configured):
        raise PolicyError(
            f"{name}.policy must be one of required, offer, off; found {configured!r}"
        )
    return {"policy": configured, "source": sources.get(f"{name}.policy", "preferences")}


def main():
    # allow_abbrev stays off to match session_governor.py; the two CLIs in
    # this skill should parse flags the same way.
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--preferences", type=pathlib.Path)
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--skill")
    parser.add_argument("--provider", choices=("claude", "codex"))
    parser.add_argument("--policy")
    parser.add_argument("--show", action="store_true")
    args = parser.parse_args()

    if sum(bool(choice) for choice in (args.skill, args.policy, args.show)) != 1:
        parser.error("pass exactly one of --skill, --policy, or --show")

    preferences_path = args.preferences or default_preferences_path()
    preferences = {}
    if preferences_path and preferences_path.is_file():
        preferences = load_json(preferences_path, "preferences")
        if not isinstance(preferences, dict):
            raise PolicyError(f"preferences {preferences_path} must be a JSON object")
        validate_preferences(preferences, preferences_path)

    repo_root = discover_repo_root(args.repo)
    repo_sources = {}
    repo_caps = {}
    repo_policy_path = None
    if repo_root is not None:
        candidate = repo_root / REPO_POLICY_FILENAME
        if candidate.is_file():
            repo_policy_path = candidate
            repo_policy = load_json(candidate, "repository policy")
            if not isinstance(repo_policy, dict):
                raise PolicyError(f"repository policy {candidate} must be a JSON object")
            validate_repo_policy(repo_policy, candidate)
            preferences, repo_sources, repo_caps = apply_repo_policy(
                preferences, repo_policy, candidate
            )

    if args.skill:
        result = resolve_skill(
            args.skill, args.provider, preferences, repo_sources, repo_caps
        )
    elif args.policy:
        result = resolve_policy(args.policy, preferences, repo_sources)
    else:
        result = {
            "preferences": str(preferences_path) if preferences_path else None,
            "repositoryPolicy": str(repo_policy_path) if repo_policy_path else None,
            "resolved": prune_nulls(preferences),
            "repoTightened": repo_sources,
            "modelRates": load_model_rates(preferences),
            "skills": {
                name: resolve_skill(name, None, preferences, repo_sources, repo_caps)
                for name, provider in SKILL_PROVIDERS.items()
                if provider is not None
            },
            "policies": {
                name: resolve_policy(name, preferences, repo_sources)
                for name in POLICY_DEFAULTS
            },
        }

    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    print()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PolicyError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
