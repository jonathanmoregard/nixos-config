#!/usr/bin/env python3
"""Mutation check for the cache-publisher gates. Run by hand, not by CI.

Every mutation below breaks a gate the publisher's security rests on. Each is
applied to a copy of scripts/cache-publisher.py, the unit suite is run against
that copy, and the suite MUST fail. A mutation that SURVIVES means the tests no
longer bite there — the suite can be fully green and still be asserting
nothing.

That is not hypothetical here. Two tests in this suite were vacuous and passed
for weeks:

  - test_200_but_private_or_internal_never_pushes reused one sha across both
    iterations, and `done` drops a later entry for a retired sha, so the
    `internal` case never ran. Deleting the `visibility == "public"` check —
    the central security gate of the whole module — kept all 55 tests green.
  - test_input_cache_not_used_for_final_recheck expressed a flip as
    ["public", "private"] consumed one element per call, so changing the
    number of preliminary calls silently re-aimed it at a different call.

Both were found by this script and by nothing else. A passing suite never
showed either one.

Usage:

    python3 -I tests/cache-publisher/mutate.py

Exits 0 only if every mutation was killed; non-zero lists the survivors.

Deliberately NOT wired as a nix check (`flake.nix` checks) even though it runs
in seconds. Its mutations are exact source strings, so any refactor of the
lines they quote reports ANCHOR MISSING — correct as a signal, but as a CI gate
it would fail on unrelated edits to this file. ANCHOR MISSING is counted as a
survivor on purpose: an anchor that no longer matches is testing nothing, which
is the same failure as a mutation that lived. When it fires, re-read the moved
code and update the anchor to the gate's new shape; do not delete the entry.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(REPO, "scripts", "cache-publisher.py")
TEST = os.path.join(HERE, "test_publisher.py")

# name -> (exact source to find, what to replace it with)
MUTATIONS = {
    # Gate (a): the one check the entire module exists to perform.
    "visibility gate dropped": (
        '        return d.get("private") is False and d.get("visibility") == "public"',
        '        return d.get("private") is False'),
    # Gate (f): the pre-upload recheck must re-ask GitHub, never trust the
    # preliminary cache, or a repo that went private between scan and push
    # would still be published.
    "final recheck consults the cache": (
        """            if not self.repo_public(o, r):
                raise Skip(f"lock input {o}/{r} stopped being public before upload")""",
        """            if not self.input_public(o, r):
                raise Skip(f"lock input {o}/{r} stopped being public before upload")"""),
    "lock input rev never checked": (
        "            self.input_rev_public(owner, repo, rev)",
        "            pass"),
    # Gate (d): a pushed path must come from the audited derivation, and
    # "not built yet" must never be reported as "rejected".
    "drv lookup absolute-only": (
        """        e = d.get(drv)
        if not isinstance(e, dict):
            e = d.get(os.path.basename(drv))""",
        "        e = d.get(drv)"),
    "output paths not normalised": (
        '        outs = [store_path(o["path"]) for o in (e.get("outputs") or {}).values()',
        '        outs = [o["path"] for o in (e.get("outputs") or {}).values()'),
    "drvPath shape check removed": (
        """        if not DRV_PATH_RE.match(drv):
            raise Skip(f"drvPath {drv!r} is not a store derivation path")""",
        "        pass"),
    "size branch retires unbuilt siblings": (
        "                    keep = []\n        return keep, incomplete",
        "                    return [], False\n        return keep, incomplete"),
    "incomplete treated as finished": (
        "        if incomplete:\n            return Outcome(INCOMPLETE, pushed,",
        "        if False:\n            return Outcome(INCOMPLETE, pushed,"),
    # Queue mechanics: one entry must never be able to wedge or starve the
    # queue, and nothing unexpected may retire a sha.
    "unexpected exception publishes nothing but retires": (
        '            return Outcome(RETRY, [], f"unexpected {type(e).__name__}: {e}")',
        '            return Outcome(FINISHED, [], f"unexpected {type(e).__name__}: {e}")'),
    "retry transition skips the attempt count": (
        '            st["tries"] += 1\n            retire = world.now()',
        '            retire = world.now()'),
    "rate limit never expires": (
        '            retire = world.now() - st["first"] > cfg["expire"]',
        '            retire = False if o.halt else world.now() - st["first"] > cfg["expire"]'),
    "input cache not persisted": (
        "    pub = Publisher(cfg, world, log, input_cache=icache)",
        "    pub = Publisher(cfg, world, log)"),
    # Transient classification: a needle missing from TRANSIENT turns a
    # network blip into a permanent retirement, silently.
    "git fetch failure no longer transient": (
        '             "failed to fetch git repository")',
        '             )'),
}


def main():
    with open(SRC) as f:
        base = f.read()
    survived = []
    with tempfile.TemporaryDirectory() as tmp:
        mutant = os.path.join(tmp, "cache-publisher.py")
        for name, (old, new) in MUTATIONS.items():
            if old not in base:
                print(f"  !! ANCHOR MISSING  {name}")
                survived.append(f"{name} (anchor missing)")
                continue
            with open(mutant, "w") as f:
                f.write(base.replace(old, new, 1))
            p = subprocess.run([sys.executable, "-I", TEST], capture_output=True, text=True,
                               env=dict(os.environ, CACHE_PUBLISHER_SRC=mutant))
            killed = p.returncode != 0
            print(f"  {'KILLED  ' if killed else 'SURVIVED'}  {name}")
            if not killed:
                survived.append(name)
    print()
    if survived:
        print(f"survivors ({len(survived)}/{len(MUTATIONS)}):")
        for s in survived:
            print(f"  - {s}")
        return 1
    print(f"all {len(MUTATIONS)} mutations killed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
