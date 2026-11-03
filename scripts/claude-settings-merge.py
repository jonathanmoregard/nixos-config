#!/usr/bin/env python3
"""Bring the served claude-config settings.json into the live one.

~/.claude/settings.json is the one projected entry that is a real file
rather than a link into the read-only deploy clone, because Claude Code
writes it at runtime: `/model`, rules saved from a permission prompt,
`/config`. So repository changes cannot simply replace it, and a plain copy
would erase whatever was written there.

This is a three-way merge. BASE is the served copy as of the previous
successful run, OURS the live file, THEIRS the served copy now:

  only THEIRS changed a value   -> take it          (a merged PR arrives)
  only OURS changed a value     -> keep it          (a runtime write survives)
  both changed, both objects    -> merge per key
  both changed, both lists      -> merge per element: elements either side
                                   added are kept, elements either side
                                   removed are dropped
  both changed, anything else   -> take THEIRS and report it

Lists are merged by element because the harness reads hook groups and
permission rules as sets: every matching hook runs, and rule precedence is
deny > ask > allow regardless of position. Replacing a list wholesale --
jq's `*` operator does that -- is how a live-only hook silently disappears.

Before anything is written, `lost_additions` re-derives the one property
that matters from scratch: every list element and object key that either
side added since BASE is present in the result. A merge that fails it is
refused and nothing is written. The real case is a live addition inside a
key the repository deleted; that needs a human, not a guess.

Exit 0 merged or nothing to do, 1 merge refused, 75 inputs unusable.
"""

import argparse
import difflib
import json
import os
import sys
import tempfile

MISSING = object()
RETRIES = 5


def _key(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


def _merge_lists(base, ours, theirs):
    base_keys = {_key(v) for v in base} if isinstance(base, list) else set()
    ours_keys = {_key(v) for v in ours}
    theirs_keys = {_key(v) for v in theirs}
    result, seen = [], set()
    for v in theirs:
        k = _key(v)
        if k in seen or (k in base_keys and k not in ours_keys):
            continue
        seen.add(k)
        result.append(v)
    for v in ours:
        k = _key(v)
        if k in seen or k in base_keys or k in theirs_keys:
            continue
        seen.add(k)
        result.append(v)
    return result


def _merge(base, ours, theirs, path, conflicts):
    if _same(ours, theirs):
        return ours
    if _same(ours, base):
        return theirs
    if _same(theirs, base):
        return ours
    if isinstance(ours, dict) and isinstance(theirs, dict):
        b = base if isinstance(base, dict) else {}
        out = {}
        for k in list(theirs) + [k for k in ours if k not in theirs]:
            v = _merge(b.get(k, MISSING), ours.get(k, MISSING),
                       theirs.get(k, MISSING), path + [k], conflicts)
            if v is not MISSING:
                out[k] = v
        return out
    if isinstance(ours, list) and isinstance(theirs, list):
        return _merge_lists(base, ours, theirs)
    conflicts.append(f"{_path(path)}: changed live and upstream; took upstream")
    return theirs


def _same(a, b):
    if a is MISSING or b is MISSING:
        return a is b
    return _key(a) == _key(b)


def _path(path):
    return "." + ".".join(str(p) for p in path) if path else "(root)"


def merge3(base, ours, theirs):
    """Return (merged, conflicts). Inputs are not modified."""
    conflicts = []
    return _merge(base, ours, theirs, [], conflicts), conflicts


def _additions(base, side, path, out):
    if isinstance(side, dict):
        b = base if isinstance(base, dict) else {}
        for k, v in side.items():
            if k not in b:
                out.append((path + [k], None))
            else:
                _additions(b[k], v, path + [k], out)
    elif isinstance(side, list):
        b = {_key(v) for v in base} if isinstance(base, list) else set()
        out.extend((path, v) for v in side if _key(v) not in b)


def _lookup(doc, path):
    for p in path:
        if not isinstance(doc, dict) or p not in doc:
            return MISSING
        doc = doc[p]
    return doc


def lost_additions(base, ours, theirs, result):
    """Everything OURS or THEIRS added since BASE that RESULT lacks."""
    lost = []
    for name, side in (("live", ours), ("served", theirs)):
        added = []
        _additions(base, side, [], added)
        for path, element in added:
            found = _lookup(result, path)
            if element is None:
                missing = found is MISSING
                what = "key"
            else:
                missing = not isinstance(found, list) or _key(element) not in {
                    _key(v) for v in found}
                what = _key(element)
            if missing:
                lost.append(f"{name} added {what} at {_path(path)}")
    return lost


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


class Unusable(Exception):
    pass


def _parse(raw, path):
    try:
        doc = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise Unusable(f"{path} is not valid JSON ({exc})")
    if not isinstance(doc, dict):
        raise Unusable(f"{path} is not a JSON object")
    return doc


def _die(message, code=75):
    print(f"claude-settings-merge: {message}", file=sys.stderr)
    return code


def _render(doc):
    return (json.dumps(doc, indent=2, ensure_ascii=False) + "\n").encode()


def _replace(path, data, mode):
    """Atomic replace; the temporary file sits beside the target."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".settings-merge.")
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
    parser.add_argument("--base", required=True, help="served copy as of the last merge")
    parser.add_argument("--marker", required=True,
                        help="the projection cutover marker; absent means nothing to do")
    parser.add_argument("--dry-run", action="store_true", help="print the change, write nothing")
    args = parser.parse_args(argv)
    try:
        return _sync(args)
    except Unusable as exc:
        return _die(str(exc))


def _sync(args):
    if not os.path.exists(args.marker):
        print(f"claude-settings-merge: no cutover marker at {args.marker}; nothing to do")
        return 0

    served_raw = _read(args.served)
    if served_raw is None:
        return _die(f"{args.served} is missing")
    served = _parse(served_raw, args.served)

    for _ in range(RETRIES):
        live_raw = _read(args.live)
        if live_raw is None:
            if args.dry_run:
                print(f"claude-settings-merge: would install {args.served} at {args.live}")
                return 0
            _replace(args.live, _render(served), 0o644)
            _replace(args.base, _render(served), 0o644)
            print(f"claude-settings-merge: installed {args.live} from {args.served}")
            return 0
        live = _parse(live_raw, args.live)

        base_raw = _read(args.base)
        if base_raw is None:
            if _same(live, served):
                if not args.dry_run:
                    _replace(args.base, _render(served), 0o644)
                print("claude-settings-merge: live already matches served; recorded the base")
                return 0
            return _die(
                f"no merge base at {args.base}, and {args.live} differs from "
                f"{args.served}. Without the base, a value only one side has "
                "cannot be told apart as an addition on that side or a removal "
                "on the other. Write the served settings.json this live file was "
                f"last synced from to {args.base}.")
        base = _parse(base_raw, args.base)

        merged, conflicts = merge3(base, live, served)
        for line in conflicts:
            print(f"claude-settings-merge: conflict {line}")
        lost = lost_additions(base, live, served, merged)
        if lost:
            for line in lost:
                print(f"claude-settings-merge: would lose: {line}", file=sys.stderr)
            return _die(f"refusing a merge that drops {len(lost)} entr(y/ies); "
                        f"{args.live} left as it was", code=1)

        changed = not _same(merged, live)
        if args.dry_run:
            if changed:
                sys.stdout.writelines(difflib.unified_diff(
                    _render(live).decode().splitlines(True),
                    _render(merged).decode().splitlines(True),
                    args.live, args.live + " (merged)"))
            else:
                print("claude-settings-merge: nothing to change")
            return 0

        if changed:
            # Claude Code may rewrite the file while this runs. Re-read just
            # before replacing it; if it moved, merge again from the new bytes.
            if _read(args.live) != live_raw:
                continue
            _replace(args.live, _render(merged), os.stat(args.live).st_mode & 0o7777)
            print(f"claude-settings-merge: updated {args.live}")
        else:
            print("claude-settings-merge: nothing to change")
        if base_raw != _render(served):
            _replace(args.base, _render(served), 0o644)
        return 0

    return _die(f"{args.live} kept changing during {RETRIES} attempts; try again later")


if __name__ == "__main__":
    sys.exit(main())
