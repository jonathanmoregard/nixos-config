#!/usr/bin/env python3
"""Overwrite ~/.claude/settings.json with the served claude-config copy.

The repository wins: after a run the live file IS the served file, byte for
byte, and a live-only edit does not survive. Why that is the wanted behaviour,
and what it costs, is in nixos-config#402.

Exit 0 projected or nothing to do, 75 the served file is unusable.
"""

import argparse
import difflib
import json
import os
import sys
import tempfile


class Unusable(Exception):
    pass


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def _check_object(raw, path):
    """Reject anything Claude Code's `JSON.parse` would reject.

    Deliberately stricter than `json.loads(raw)`: decoding to `str` first is
    what rejects a BOM and stops the UTF-16 sniff that only happens for bytes,
    and `parse_constant` rejects NaN/Infinity. All five would otherwise be
    written out and leave the harness unable to load its own settings.
    """
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Unusable(f"{path} is not UTF-8 ({exc})")

    def _reject_constant(token):
        raise Unusable(f"{path} contains {token}, which JSON.parse rejects")

    try:
        doc = json.loads(text, parse_constant=_reject_constant)
    except json.JSONDecodeError as exc:
        raise Unusable(f"{path} is not valid JSON ({exc})")
    if not isinstance(doc, dict):
        raise Unusable(f"{path} is not a JSON object")


def _live_mode(path):
    """The live file's mode, or 0644 if it vanished since we read it.

    The harness rewrites this file by unlinking and recreating it, so a path
    that existed moments ago can be gone by this call.
    """
    try:
        return os.stat(path).st_mode & 0o7777
    except FileNotFoundError:
        return 0o644


def _die(message, code=75):
    print(f"claude-settings-project: {message}", file=sys.stderr)
    return code


def _replace(path, data, mode):
    """Atomic replace; the temporary file sits beside the target."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".settings-project.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--served", required=True, help="settings.json in the deploy clone")
    parser.add_argument("--live", required=True, help="the live ~/.claude/settings.json")
    parser.add_argument("--marker", required=True,
                        help="the projection cutover marker; absent means nothing to do")
    parser.add_argument("--dry-run", action="store_true", help="print the change, write nothing")
    args = parser.parse_args(argv)
    try:
        return _project(args)
    except Unusable as exc:
        return _die(str(exc))


def _project(args):
    if not os.path.exists(args.marker):
        print(f"claude-settings-project: no cutover marker at {args.marker}; nothing to do")
        return 0

    served_raw = _read(args.served)
    if served_raw is None:
        return _die(f"{args.served} is missing")
    _check_object(served_raw, args.served)

    live_raw = _read(args.live)

    if live_raw == served_raw:
        print("claude-settings-project: nothing to change")
        return 0

    if args.dry_run:
        if live_raw is None:
            print(f"claude-settings-project: would install {args.served} at {args.live}")
            return 0
        sys.stdout.writelines(difflib.unified_diff(
            live_raw.decode("utf-8", "replace").splitlines(True),
            served_raw.decode("utf-8").splitlines(True),
            args.live, f"{args.live} (projected)"))
        return 0

    if live_raw is None:
        _replace(args.live, served_raw, 0o644)
        print(f"claude-settings-project: installed {args.live} from {args.served}")
        return 0

    _replace(args.live, served_raw, _live_mode(args.live))
    print(f"claude-settings-project: updated {args.live} from {args.served}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
