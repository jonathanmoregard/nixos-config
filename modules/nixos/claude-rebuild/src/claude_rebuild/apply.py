"""Privileged rebuild apply.

Must run as root. Two invocation paths:

  sudo claude-rebuild-apply low      — NOPASSWD via sudoers (autonomous low-blast)
  pkexec claude-rebuild-apply high   — desktop password prompt via polkit (HITL)

Defense in depth:
  - Refuses to run unless real UID == 0.
  - Re-runs classifier internally; refuses if classification disagrees with
    the requested tier (Claude can't smuggle a high-blast diff via --tier=low).
  - For tier=high, additionally requires PKEXEC_UID env var (set by pkexec,
    NOT by sudo). Prevents bypass via wheel-NOPASSWD sudo for high-blast
    changes — those MUST go through pkexec's desktop prompt.
  - flock on /var/lib/claude-rebuild/lock — only one rebuild at a time.

Writes /var/lib/claude-rebuild/last-applied-rev (HEAD sha) on success.
Appends one JSON line per attempt to /var/log/claude-rebuild.log.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import subprocess
import sys

from . import classifier, common


def require_root() -> None:
    if os.geteuid() != 0:
        sys.stderr.write("claude-rebuild-apply must run as root (sudo or pkexec)\n")
        sys.exit(2)


def require_pkexec_for_high(tier: str) -> None:
    if tier == "high" and "PKEXEC_UID" not in os.environ:
        sys.stderr.write(
            "tier=high must be invoked via pkexec (desktop password prompt).\n"
            "  pkexec claude-rebuild-apply high\n"
            "Refusing — sudo NOPASSWD is not sufficient HITL for high-blast changes.\n"
        )
        sys.exit(3)


def audit(record: dict) -> None:
    common.AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
    record = {"ts": dt.datetime.now(dt.UTC).isoformat(), **record}
    with common.AUDIT_LOG.open("a") as f:
        f.write(json.dumps(record) + "\n")


def write_last_applied_rev(rev: str) -> None:
    common.STATE_DIR.mkdir(parents=True, exist_ok=True)
    common.LAST_REV_FILE.write_text(rev + "\n")


def acquire_lock():
    common.STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd = os.open(common.LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.stderr.write("another claude-rebuild-apply is already running\n")
        sys.exit(4)
    return fd


def run_nixos_rebuild() -> int:
    # NIXOS_REBUILD_BIN env override exists for VM e2e tests; production
    # always invokes the system `nixos-rebuild`.
    bin_path = os.environ.get("CLAUDE_REBUILD_NIXOS_REBUILD_BIN", "nixos-rebuild")
    cmd = [bin_path, "switch", "--flake", common.FLAKE_TARGET]
    sys.stderr.write(f"+ {' '.join(cmd)}\n")
    proc = subprocess.run(cmd)
    return proc.returncode


def caller_identity() -> dict:
    """Capture caller-identifying env + parent process for audit forensics."""
    ident: dict = {
        "sudo_uid": os.environ.get("SUDO_UID"),
        "sudo_user": os.environ.get("SUDO_USER"),
        "pkexec_uid": os.environ.get("PKEXEC_UID"),
        "ppid": os.getppid(),
    }
    try:
        with open(f"/proc/{ident['ppid']}/cmdline", "rb") as f:
            ident["parent_cmdline"] = f.read().replace(b"\0", b" ").decode(errors="replace").strip()
    except OSError:
        ident["parent_cmdline"] = None
    return ident


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="claude-rebuild-apply")
    parser.add_argument("tier", choices=["low", "high"])
    parser.add_argument(
        "--from", dest="from_rev", default=None,
        help="override classifier from-rev (default: last-applied-rev)",
    )
    parser.add_argument(
        "--to", dest="to_rev", default="HEAD",
        help=(
            "git rev to apply (default: HEAD). MCP-driven flows MUST pass the "
            "sha that was classified + presented to the user, so the apply "
            "doesn't silently drift if HEAD moves between elicit and pkexec."
        ),
    )
    args = parser.parse_args(argv)

    require_root()
    require_pkexec_for_high(args.tier)
    lock = acquire_lock()  # noqa: F841 — held until process exit

    from_rev = classifier.resolve_from(args.from_rev)
    result = classifier.classify(from_rev, args.to_rev)
    caller = caller_identity()

    if result.tier != args.tier:
        audit({
            "event": "tier_mismatch",
            "requested_tier": args.tier,
            "classified_tier": result.tier,
            "from": result.from_rev,
            "to": result.to_rev,
            "reasons": result.reasons,
            "caller": caller,
        })
        sys.stderr.write(
            f"REJECT: classifier says tier={result.tier}, requested tier={args.tier}\n"
        )
        for r in result.reasons:
            sys.stderr.write(f"  - {r}\n")
        return 5

    audit({
        "event": "rebuild_start",
        "tier": args.tier,
        "from": result.from_rev,
        "to": result.to_rev,
        "changed_paths": result.changed_paths,
        "caller": caller,
    })

    rc = run_nixos_rebuild()

    audit({
        "event": "rebuild_finish",
        "tier": args.tier,
        "to": result.to_rev,
        "exit_code": rc,
        "caller": caller,
    })

    if rc == 0:
        write_last_applied_rev(result.to_rev)

    return rc


if __name__ == "__main__":
    sys.exit(main())
