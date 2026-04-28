from __future__ import annotations

import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Env overrides exist for the VM e2e test only — production paths are
# always the defaults. Don't read these env vars at use sites; use the
# module-level constants below.
REPO = Path(os.environ.get("CLAUDE_REBUILD_REPO", "/etc/nixos"))
STATE_DIR = Path(os.environ.get("CLAUDE_REBUILD_STATE_DIR", "/var/lib/claude-rebuild"))
LAST_REV_FILE = STATE_DIR / "last-applied-rev"
AUDIT_LOG = Path(os.environ.get("CLAUDE_REBUILD_AUDIT_LOG", "/var/log/claude-rebuild.log"))
LOCK_FILE = STATE_DIR / "lock"

HOST = "dellan"
FLAKE_TARGET = f"{REPO}#{HOST}"

ALWAYS_LOW_PREFIXES = (
    "home/",
    "overlays/",
    "docs/",
    "modules/nixos/claude-rebuild/",
)
ALWAYS_LOW_FILES = {
    "CLAUDE.md",
    "README.md",
    "modules/nixos/desktop.nix",
    "modules/nixos/laptop.nix",
    "modules/nixos/tailscale.nix",
    "modules/nixos/research-agent.nix",
    "modules/nixos/vm-tweaks.nix",
}
ALWAYS_HIGH_PREFIXES = (
    # Intentionally no `.nix` suffix — matches both
    # `hardware-configuration.nix` (current layout) and a future
    # `hardware-configuration/` subdir if the file ever splits.
    "hardware-configuration",
    "hosts/",
)
ALWAYS_HIGH_FILES = {
    "flake.nix",
    "flake.lock",
    "secrets/secrets.nix",
}

DENY_KEY_PATTERNS = [
    r"boot\.",
    r"fileSystems\.",
    r"users\.users",
    r"networking\.firewall",
    r"hardware-configuration",
    r"systemd\.services\.(sshd|NetworkManager|display-manager|lightdm|polkit)",
    # security.* is risky but security.sudo.extraRules is a common low-blast change.
    # Match security.X for any X != sudo.extraRules.
    r"security\.(?!sudo\.extraRules)",
    # Network exposure / remote-access surface area.
    r"services\.openssh",
    r"services\.tailscale",
    # Login / display-manager flips (autoLogin, lockscreen disable, session swap).
    r"services\.xserver\.displayManager",
    # Privilege escalation channels.
    r"nix\.settings\.trusted-users",
    r"programs\.(ssh|gnupg-agent)",
]


@dataclass
class Classification:
    tier: str  # "low" | "high"
    from_rev: str
    to_rev: str
    changed_paths: list[str] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "tier": self.tier,
            "from": self.from_rev,
            "to": self.to_rev,
            "changed_paths": self.changed_paths,
            "reasons": self.reasons,
        }


def git(*args: str, cwd: Path = REPO, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        # Surface git's own error message — `subprocess.CalledProcessError`
        # alone hides stderr, which makes "fatal: bad revision <sha>" or
        # "fatal: detected dubious ownership" debugging painful.
        sys.stderr.write(
            f"git {' '.join(args)} (cwd={cwd}) failed with exit {result.returncode}:\n"
            f"{result.stderr}"
        )
        raise subprocess.CalledProcessError(
            result.returncode, ["git", *args],
            output=result.stdout, stderr=result.stderr,
        )
    return result.stdout


def resolve_rev(rev: str) -> str:
    return git("rev-parse", rev).strip()


# Tightened to full 40-hex shas only. We always WRITE full shas
# (resolve_rev → git rev-parse → 40 chars lowercase). Abbreviated values
# can become ambiguous as the repo grows; reject and fall back rather
# than risk a silent rev resolution drift.
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def read_last_applied_rev() -> str | None:
    """Read /var/lib/claude-rebuild/last-applied-rev, validate it's a real
    sha that still exists in the repo. A poisoned or stale file (rebased-
    away sha) returned blindly would propagate into git diff and crash
    every classify call until ops manually intervened."""
    if not LAST_REV_FILE.is_file():
        return None
    raw = LAST_REV_FILE.read_text().strip()
    if not raw or not _SHA_RE.match(raw):
        return None
    # Confirm the sha resolves in the current repo.
    rc = subprocess.run(
        ["git", "cat-file", "-e", raw],
        cwd=REPO,
        capture_output=True,
    ).returncode
    if rc != 0:
        return None
    return raw


def changed_paths(from_rev: str, to_rev: str) -> list[str]:
    out = git("diff", "--name-only", from_rev, to_rev)
    return [line for line in out.splitlines() if line]


def diff_added_lines(from_rev: str, to_rev: str, *pathspec: str) -> str:
    args = ["diff", from_rev, to_rev]
    if pathspec:
        args += ["--", *pathspec]
    return git(*args)
