#!/usr/bin/env python3
"""Hold the report-delivery state lock until stdin closes."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import sys
import time


def process_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_owner(handle) -> dict[str, object] | None:
    handle.seek(0)
    raw = handle.read()
    if not raw:
        return None
    try:
        owner = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not isinstance(owner, dict):
        return {}
    pid = owner.get("pid")
    created = owner.get("created_at_epoch")
    token = owner.get("token")
    if (
        not isinstance(pid, int)
        or isinstance(pid, bool)
        or pid < 1
        or not isinstance(created, int)
        or isinstance(created, bool)
        or created < 0
        or not isinstance(token, str)
        or not token
    ):
        return {}
    return owner


def main() -> int:
    if len(sys.argv) != 5:
        print("error", flush=True)
        return 2
    lock_path = Path(sys.argv[1])
    ttl = int(sys.argv[2])
    owner_pid = int(sys.argv[3])
    token = sys.argv[4]
    lock_path.parent.mkdir(parents=True, exist_ok=True)

    with lock_path.open("a+", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("busy", flush=True)
            return 1

        current = int(time.time())
        prior = read_owner(handle)
        if prior == {}:
            print("busy", flush=True)
            return 1
        if prior is not None:
            prior_pid = int(prior["pid"])
            prior_age = current - int(prior["created_at_epoch"])
            if process_is_alive(prior_pid) or prior_age < ttl:
                print("busy", flush=True)
                return 1

        handle.seek(0)
        handle.truncate()
        json.dump(
            {"pid": owner_pid, "created_at_epoch": current, "token": token},
            handle,
            separators=(",", ":"),
        )
        handle.flush()
        os.fsync(handle.fileno())
        print("ready", flush=True)
        sys.stdin.read()

        handle.seek(0)
        active = read_owner(handle)
        if active is not None and active != {} and active.get("token") == token:
            handle.seek(0)
            handle.truncate()
            handle.flush()
            os.fsync(handle.fileno())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
