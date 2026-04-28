"""Blast-radius classifier.

Reads git diff between two revs (default: last-applied-rev .. HEAD), classifies
each changed path against allowlists, greps added .nix lines for denied config
keys. Outputs JSON describing tier ("low" | "high") and reasons.

Pure userland — no privilege required. Both the MCP server and the privileged
apply binary call this; the apply binary re-runs it as defense-in-depth and
refuses if its own classification disagrees with the requested tier.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

from . import common


def classify_path(path: str) -> tuple[str, str | None]:
    """Return (tier, reason) for a single changed path."""
    if path in common.ALWAYS_HIGH_FILES:
        return "high", f"{path} changed (high-blast file)"
    for prefix in common.ALWAYS_HIGH_PREFIXES:
        if path.startswith(prefix):
            return "high", f"{path} changed (high-blast prefix {prefix!r})"
    if path in common.ALWAYS_LOW_FILES:
        return "low", None
    for prefix in common.ALWAYS_LOW_PREFIXES:
        if path.startswith(prefix):
            return "low", None
    if path.startswith("modules/nixos/"):
        return "high", f"uncurated module changed: {path}"
    if path.startswith("secrets/") and path.endswith(".age"):
        # Rotating an existing .age (re-encrypt) doesn't touch secrets.nix
        # but can break every service that reads the secret if the new
        # ciphertext is malformed or the value changes shape. HITL.
        return "high", f"encrypted secret changed (rotation): {path}"
    return "high", f"uncurated path changed: {path}"


def check_deny_keys(from_rev: str, to_rev: str) -> list[str]:
    """Return list of denied config-key matches found in added lines of *.nix."""
    diff = common.diff_added_lines(from_rev, to_rev, "*.nix")
    pattern = re.compile(
        r"^\+(?!\+\+).*(" + "|".join(common.DENY_KEY_PATTERNS) + r")"
    )
    matches: list[str] = []
    for line in diff.splitlines():
        m = pattern.search(line)
        if m:
            matches.append(line[:200])
            if len(matches) >= 5:
                break
    return matches


def classify(from_rev: str, to_rev: str) -> common.Classification:
    # Refuse if <from> is not an ancestor of <to>. After a rebase / force-push
    # the diff `<from>..<to>` could include unrelated commits and flip tier
    # in either direction. Fail closed rather than classify nonsense.
    rc = subprocess.run(
        ["git", "merge-base", "--is-ancestor", from_rev, to_rev],
        cwd=common.REPO,
        capture_output=True,
    ).returncode
    if rc != 0:
        # ValueError (not SystemExit) — SystemExit inherits BaseException
        # and would propagate through FastMCP's `except Exception` tool
        # wrapping, killing the long-running MCP server. ValueError is
        # caught and surfaces to the MCP client as a tool error.
        raise ValueError(
            f"classify: <from> {from_rev} is not an ancestor of <to> {to_rev}. "
            "Refusing — repo likely rebased between classify and apply."
        )

    paths = common.changed_paths(from_rev, to_rev)
    tier = "low"
    reasons: list[str] = []
    for path in paths:
        path_tier, reason = classify_path(path)
        if path_tier == "high":
            tier = "high"
            if reason:
                reasons.append(reason)
    deny_hits = check_deny_keys(from_rev, to_rev)
    if deny_hits:
        tier = "high"
        for hit in deny_hits:
            reasons.append(f"denied config key introduced: {hit}")
    return common.Classification(
        tier=tier,
        from_rev=common.resolve_rev(from_rev),
        to_rev=common.resolve_rev(to_rev),
        changed_paths=paths,
        reasons=reasons,
    )


def resolve_from(arg: str | None) -> str:
    if arg:
        return arg
    last = common.read_last_applied_rev()
    if last:
        return last
    return "HEAD~1"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="claude-rebuild-classify")
    parser.add_argument(
        "--from", dest="from_rev", default=None,
        help="git rev to diff from (default: /var/lib/claude-rebuild/last-applied-rev or HEAD~1)",
    )
    parser.add_argument(
        "--to", dest="to_rev", default="HEAD",
        help="git rev to diff to (default: HEAD)",
    )
    parser.add_argument(
        "--exit-on-tier", choices=["low", "high"], default=None,
        help="exit 1 if classified tier does not match this value",
    )
    args = parser.parse_args(argv)

    from_rev = resolve_from(args.from_rev)
    try:
        result = classify(from_rev, args.to_rev)
    except ValueError as e:
        sys.stderr.write(f"{e}\n")
        return 1
    json.dump(result.to_dict(), sys.stdout, indent=2)
    sys.stdout.write("\n")

    if args.exit_on_tier and result.tier != args.exit_on_tier:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
