#!/usr/bin/env python3
"""Durable budget ledger for one Codex subagent workflow."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
from datetime import datetime, timezone
from uuid import uuid4


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def fail(message: str, code: int = 2) -> None:
    print(f"[subagent-ledger] {message}", file=sys.stderr)
    raise SystemExit(code)


@contextlib.contextmanager
def locked(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(f"{path.name}.lock")
    with lock_path.open("a+", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        yield


def read_state(path: Path) -> dict:
    if not path.is_file():
        fail(f"ledger does not exist: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read ledger {path}: {error}")
    if value.get("version") != 1:
        fail(f"unsupported ledger version in {path}")
    return value


def write_state(path: Path, state: dict) -> None:
    state["updated_at"] = now()
    payload = json.dumps(state, indent=2, sort_keys=True) + "\n"
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def event(state: dict, kind: str, **fields: object) -> None:
    state["events"].append({"at": now(), "kind": kind, **fields})


def ensure_active(state: dict) -> None:
    if state["status"] != "ACTIVE":
        fail(f"ledger is {state['status']}; no further delegation is allowed")


def print_status(state: dict) -> None:
    print(
        json.dumps(
            {
                "task_id": state["task_id"],
                "status": state["status"],
                "creations": state["usage"]["creations"],
                "max_creations": state["caps"]["creations"],
                "turns": state["usage"]["turns"],
                "max_turns": state["caps"]["turns"],
                "violations": state["violations"],
            },
            sort_keys=True,
        )
    )


def init(args: argparse.Namespace) -> None:
    path = args.ledger
    with locked(path):
        if path.exists():
            state = read_state(path)
            if state["task_id"] != args.task_id:
                fail(f"ledger belongs to task {state['task_id']}, not {args.task_id}")
            print_status(state)
            return
        state = {
            "version": 1,
            "task_id": args.task_id,
            "root_agent": args.root_agent,
            "status": "ACTIVE",
            "caps": {"creations": args.max_creations, "turns": args.max_turns},
            "usage": {"creations": 0, "turns": 0},
            "agents": {},
            "reservations": {},
            "violations": [],
            "events": [],
            "created_at": now(),
        }
        event(state, "initialized")
        write_state(path, state)
        print_status(state)


def resume(args: argparse.Namespace) -> None:
    with locked(args.ledger):
        state = read_state(args.ledger)
        if state["task_id"] != args.task_id:
            fail(f"ledger belongs to task {state['task_id']}, not {args.task_id}")
        ensure_active(state)
        print_status(state)


def reserve_spawn(args: argparse.Namespace) -> None:
    with locked(args.ledger):
        state = read_state(args.ledger)
        ensure_active(state)
        if state["usage"]["creations"] >= state["caps"]["creations"]:
            fail("child-creation budget is exhausted")
        if state["usage"]["turns"] >= state["caps"]["turns"]:
            fail("delegated-turn budget is exhausted")
        token = str(uuid4())
        state["usage"]["creations"] += 1
        state["usage"]["turns"] += 1
        state["reservations"][token] = {
            "kind": "spawn",
            "role": args.role,
            "model": args.model,
            "status": "RESERVED",
            "created_at": now(),
        }
        event(state, "spawn_reserved", token=token, role=args.role, model=args.model)
        write_state(args.ledger, state)
        print(token)


def settle_spawn(args: argparse.Namespace) -> None:
    with locked(args.ledger):
        state = read_state(args.ledger)
        reservation = state["reservations"].get(args.token)
        if not reservation or reservation.get("kind") != "spawn":
            fail(f"unknown spawn reservation: {args.token}")
        if reservation["status"] != "RESERVED":
            fail(f"spawn reservation is already {reservation['status']}: {args.token}")
        if args.agent_id in state["agents"]:
            fail(f"agent is already recorded: {args.agent_id}")
        reservation["status"] = "SETTLED"
        reservation["agent_id"] = args.agent_id
        state["agents"][args.agent_id] = {
            "parent_id": state["root_agent"],
            "role": reservation["role"],
            "model": reservation["model"],
            "source": "reserved",
        }
        event(state, "spawn_settled", token=args.token, agent_id=args.agent_id)
        write_state(args.ledger, state)
        print_status(state)


def reserve_turn(args: argparse.Namespace) -> None:
    with locked(args.ledger):
        state = read_state(args.ledger)
        ensure_active(state)
        agent = state["agents"].get(args.agent_id)
        if not agent:
            fail(f"agent is not recorded: {args.agent_id}")
        prior = agent.get("follow_up_turns", 0)
        if prior >= 1:
            fail(f"agent already consumed its one follow-up turn: {args.agent_id}")
        if state["usage"]["turns"] >= state["caps"]["turns"]:
            fail("delegated-turn budget is exhausted")
        state["usage"]["turns"] += 1
        agent["follow_up_turns"] = prior + 1
        event(state, "turn_reserved", agent_id=args.agent_id)
        write_state(args.ledger, state)
        print_status(state)


def observe_agent(args: argparse.Namespace) -> None:
    with locked(args.ledger):
        state = read_state(args.ledger)
        if args.agent_id in state["agents"]:
            print_status(state)
            return
        state["usage"]["creations"] += 1
        state["usage"]["turns"] += 1
        state["agents"][args.agent_id] = {
            "parent_id": args.parent_id,
            "role": "UNEXPECTED",
            "model": "UNKNOWN",
            "source": "observed",
        }
        reasons = []
        if args.parent_id != state["root_agent"]:
            reasons.append(f"descendant spawn {args.agent_id} by {args.parent_id}")
        if state["usage"]["creations"] > state["caps"]["creations"]:
            reasons.append("child-creation budget exceeded")
        if state["usage"]["turns"] > state["caps"]["turns"]:
            reasons.append("delegated-turn budget exceeded")
        if reasons:
            state["status"] = "VIOLATED"
            state["violations"].extend(reasons)
        event(
            state,
            "agent_observed",
            agent_id=args.agent_id,
            parent_id=args.parent_id,
            violations=reasons,
        )
        write_state(args.ledger, state)
        print_status(state)
        if reasons:
            raise SystemExit(3)


def status(args: argparse.Namespace) -> None:
    with locked(args.ledger):
        print_status(read_state(args.ledger))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--ledger", required=True, type=Path)
    commands = result.add_subparsers(dest="command", required=True)

    init_command = commands.add_parser("init")
    init_command.add_argument("--task-id", required=True)
    init_command.add_argument("--root-agent", default="/root")
    init_command.add_argument("--max-creations", type=int, default=3)
    init_command.add_argument("--max-turns", type=int, default=4)
    init_command.set_defaults(run=init)

    resume_command = commands.add_parser("resume")
    resume_command.add_argument("--task-id", required=True)
    resume_command.set_defaults(run=resume)

    spawn_command = commands.add_parser("reserve-spawn")
    spawn_command.add_argument("--role", required=True)
    spawn_command.add_argument("--model", required=True)
    spawn_command.set_defaults(run=reserve_spawn)

    settle_command = commands.add_parser("settle-spawn")
    settle_command.add_argument("--token", required=True)
    settle_command.add_argument("--agent-id", required=True)
    settle_command.set_defaults(run=settle_spawn)

    turn_command = commands.add_parser("reserve-turn")
    turn_command.add_argument("--agent-id", required=True)
    turn_command.set_defaults(run=reserve_turn)

    observe_command = commands.add_parser("observe-agent")
    observe_command.add_argument("--agent-id", required=True)
    observe_command.add_argument("--parent-id", required=True)
    observe_command.set_defaults(run=observe_agent)

    status_command = commands.add_parser("status")
    status_command.set_defaults(run=status)
    return result


def main() -> None:
    args = parser().parse_args()
    if getattr(args, "max_creations", 1) < 1 or getattr(args, "max_turns", 1) < 1:
        fail("caps must be positive")
    args.run(args)


if __name__ == "__main__":
    main()
