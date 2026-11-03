#!/usr/bin/env python3
"""Project the served claude-config settings.json onto the live one.

~/.claude/settings.json is the one projected entry that is a real file rather
than a symlink into the read-only deploy clone, because Claude Code writes it
at runtime: `/model`, rules saved from a permission prompt, `/config`. Through
a link into the projection those writes fail with EROFS, and worse, Claude
Code replaces the file rather than writing through it -- a link would simply
be swapped back for a regular file on the first write, silently restoring the
problem this unit exists to fix.

So the file stays writable and this unit makes the checked-in copy win. The
repository is authoritative: after a run the live file IS the served file,
byte for byte. A live-only edit does not survive.

That is deliberate. Every live-only entry measured on tuxedo on 2026-11-03
was drift nobody wanted:

  - a PreToolUse hook group dcg's own `self_heal_hook` wrote into the file,
    pinned to a fixed /nix/store path that stops resolving after the next
    dcg upgrade and GC -- a check that looks present and does nothing;
  - `Edit(//home/jonathan/.claude/skills/**)`, an allow rule a merged PR
    had deliberately removed;
  - `model: claude-opus-5`, written by `/model` over the checked-in
    `opus[1m]`.

The cost is the other side of the same coin: a `/model` or `/config` change
made in a session is reverted at the next deploy tick. Values meant to
persist belong in the repository, which is where this unit reads them from.

This delivers configuration; it does not enforce it. Between ticks the live
file is still writable by the account the agents run as. Managed settings
(/etc/claude-code/managed-settings.json) is the enforcement layer, and it is
a separate decision -- it also overrides the user, not just the agent.

Nothing is parsed out of the live file, so a corrupt live file cannot wedge
the unit; it is simply replaced. The served file IS parsed, purely to refuse
projecting something that is not a settings object: an unusable input leaves
the live file exactly as it was.

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
    """Validate without keeping the parse: the bytes are what gets written.

    Stricter than `json.loads(raw)` on purpose. Claude Code is a JavaScript
    program and reads this file with `JSON.parse`, which rejects things
    Python's parser accepts from BYTES: `NaN`, `Infinity`, `-Infinity`, and a
    UTF-16 encoding it sniffs from a byte string. Accepting any of them would
    project a file the harness then cannot load -- the exact outcome this
    check exists to prevent.

    Decoding first, and passing a `str`, is what closes the encoding half:
    `json.loads` only sniffs UTF-16/UTF-32 when handed bytes, and on a `str`
    it rejects a leading BOM itself. An explicit BOM check here was tried and
    removed -- a mutation proved it unreachable as the sole guard, and a
    guard that looks load-bearing while nothing depends on it is a trap. The
    BOM case stays asserted in the suite, so a change in that behaviour fails
    the tests rather than slipping through.
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
    """The live file's mode, or 0644 when it is not there to be asked.

    Read separately from the content, so a writer that unlinks and recreates
    the file between the two can make this lookup fail on a path that existed
    moments earlier. That must not become an unhandled traceback: the unit
    would exit 1 -- not a code this script defines -- and the OnFailure
    notifier would record that merged settings are not arriving when the only
    thing that happened was a concurrent write.
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

    # The harness may rewrite the file while this runs. That is harmless for
    # the content -- the bytes written do not depend on what was there, so the
    # last writer wins and the next tick converges either way. The mode is the
    # one thing still read from the live file, hence _live_mode's fallback.
    _replace(args.live, served_raw, _live_mode(args.live))
    print(f"claude-settings-project: updated {args.live} from {args.served}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
