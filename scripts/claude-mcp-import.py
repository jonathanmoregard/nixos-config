#!/usr/bin/env python3
"""Merge the served claude-config mcp-servers.json into ~/.claude.json.

Additive: a tracked server is added or updated by name, recursively, so the
tracked file wins on every value it states. Live-only servers, and live-only
keys inside a tracked server (an `env` secret added by hand), are kept.
Removing a server from the tracked file therefore does not remove it live.

Exit 0 merged or nothing to do, 75 an input is unusable or the lock is busy.
"""

import argparse
import json
import math
import os
import sys
import tempfile
import time


class Unusable(Exception):
    pass


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def _parse_object(raw, path):
    """Strict enough that whatever is written, Claude Code's JSON.parse loads."""
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Unusable(f"{path} is not UTF-8 ({exc})")

    def _reject_constant(token):
        raise Unusable(f"{path} contains {token}, which JSON.parse rejects")

    def _finite_float(token):
        value = float(token)
        if not math.isfinite(value):
            raise Unusable(f"{path} contains {token}, which would be written back as Infinity")
        return value

    try:
        doc = json.loads(text, parse_constant=_reject_constant, parse_float=_finite_float)
    except json.JSONDecodeError as exc:
        raise Unusable(f"{path} is not valid JSON ({exc})")
    if not isinstance(doc, dict):
        raise Unusable(f"{path} is not a JSON object")
    return doc


def _load_served(path):
    raw = _read(path)
    if raw is None:
        raise Unusable(f"{path} is missing")
    servers = _parse_object(raw, path)
    for name, entry in servers.items():
        if not isinstance(entry, dict):
            raise Unusable(f"{path}: server {name!r} is not a JSON object")
    return servers


def _merge(live, tracked):
    out = dict(live)
    for key, value in tracked.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def _current(doc):
    current = doc.get("mcpServers", {})
    if not isinstance(current, dict):
        raise Unusable("live mcpServers is not a JSON object")
    return current


def _merged(doc, servers):
    current = _current(doc)
    merged = _merge(current, servers)
    # Compared as JSON text: Python's == holds for true == 1 == 1.0.
    same = json.dumps(merged, sort_keys=True) == json.dumps(current, sort_keys=True)
    return None if same else merged


class _ConfigLock:
    """Claude Code's own lock on ~/.claude.json (proper-lockfile: mkdir <file>.lock).

    Holding it means a running session's next save re-reads our write under
    the same lock instead of overwriting it from its cache. A lock that stays
    busy is reported, never broken: it is not ours to judge stale.
    """

    def __init__(self, live, timeout):
        self.path = live + ".lock"
        self.timeout = timeout

    def __enter__(self):
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                os.mkdir(self.path)
                return self
            except FileExistsError:
                if time.monotonic() >= deadline:
                    raise Unusable(f"{self.path} still held after {self.timeout}s")
                time.sleep(0.2)

    def __exit__(self, *exc):
        os.rmdir(self.path)


def _replace(path, doc, mode):
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".claude.json.mcp-import.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            # ASCII escapes carry a lone surrogate, which JSON.stringify emits
            # and UTF-8 cannot encode.
            json.dump(doc, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _import(args):
    if not os.path.exists(args.marker):
        print(f"claude-mcp-import: no cutover marker at {args.marker}; nothing to do")
        return 0

    servers = _load_served(args.served)

    raw = _read(args.live)
    if raw is None:
        print(f"claude-mcp-import: no {args.live} yet; nothing to do")
        return 0
    if _merged(_parse_object(raw, args.live), servers) is None:
        print("claude-mcp-import: nothing to change")
        return 0

    with _ConfigLock(args.live, args.lock_timeout):
        raw = _read(args.live)
        if raw is None:
            raise Unusable(f"{args.live} vanished under the lock")
        doc = _parse_object(raw, args.live)
        merged = _merged(doc, servers)
        if merged is None:
            print("claude-mcp-import: nothing to change")
            return 0
        added = sorted(set(merged) - set(_current(doc)))
        doc["mcpServers"] = merged
        _replace(args.live, doc, os.stat(args.live).st_mode & 0o7777)
    print(f"claude-mcp-import: updated {args.live}; added: {', '.join(added) or 'none'}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--served", required=True, help="mcp-servers.json in the deploy clone")
    parser.add_argument("--live", required=True, help="the live ~/.claude.json")
    parser.add_argument("--marker", required=True,
                        help="the projection cutover marker; absent means nothing to do")
    parser.add_argument("--lock-timeout", type=float, default=30.0)
    args = parser.parse_args(argv)
    try:
        return _import(args)
    except Unusable as exc:
        print(f"claude-mcp-import: {exc}", file=sys.stderr)
        return 75


if __name__ == "__main__":
    sys.exit(main())
