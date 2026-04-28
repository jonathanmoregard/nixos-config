"""MCP server for claude-rebuild.

Exposes one tool: rebuild_dellan.

  - Runs the classifier.
  - Tier=low  → invokes `sudo claude-rebuild-apply low` (NOPASSWD).
  - Tier=high → uses MCP elicitation to surface diff + reasons to the user;
                on accept, invokes `pkexec claude-rebuild-apply high` which
                triggers polkit's desktop password prompt.

The server runs as the user; privileged work is delegated to the apply binary
via sudo or pkexec. The apply binary re-runs the classifier and refuses if
its classification disagrees with the requested tier — so a compromised MCP
server cannot escalate a high-blast change to low-tier silently.
"""

from __future__ import annotations

import json
import subprocess
import sys
from typing import Any

from mcp.server.fastmcp import Context, FastMCP
from pydantic import BaseModel, Field

from . import classifier, common


mcp = FastMCP("claude-rebuild")


class ApprovalSchema(BaseModel):
    """Confirm a high-blast rebuild."""

    confirm: bool = Field(
        description="Set true to approve the rebuild. The system will then prompt you for your password via polkit before applying."
    )


_MAX_PATHS_IN_SUMMARY = 100


def _summarize(c: common.Classification) -> str:
    lines = [
        f"tier: {c.tier}",
        f"from: {c.from_rev[:12]}",
        f"to:   {c.to_rev[:12]}",
        "",
        "changed paths:",
    ]
    shown = c.changed_paths[:_MAX_PATHS_IN_SUMMARY]
    for p in shown:
        lines.append(f"  - {p}")
    if len(c.changed_paths) > len(shown):
        lines.append(f"  ... and {len(c.changed_paths) - len(shown)} more")
    if c.reasons:
        lines.append("")
        lines.append("reasons:")
        for r in c.reasons:
            lines.append(f"  - {r}")
    return "\n".join(lines)


_APPLY_TIMEOUT_SECONDS = 1800  # 30 min — generous upper bound for nixos-rebuild


def _run_apply(tier: str, from_rev: str, to_rev: str) -> dict[str, Any]:
    """Invoke the privileged apply binary, pinning rev range to what was
    classified for the user. Without --to, apply would re-resolve HEAD and
    could silently apply a diff that differs from the one shown to the user."""
    base = ["claude-rebuild-apply", tier, "--from", from_rev, "--to", to_rev]
    cmd = ["sudo", "-n", *base] if tier == "low" else ["pkexec", *base]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=_APPLY_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as e:
        return {
            "applied": False,
            "exit_code": None,
            "stdout": (e.stdout or b"")[-2000:].decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")[-2000:],
            "stderr": f"apply timed out after {_APPLY_TIMEOUT_SECONDS}s and was killed",
            "timed_out": True,
        }
    return {
        "applied": proc.returncode == 0,
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-2000:],
        "stderr": proc.stderr[-2000:],
    }


@mcp.tool()
async def classify_dellan(ctx: Context) -> dict[str, Any]:
    """Classify the pending /etc/nixos diff as low- or high-blast. Read-only."""
    from_rev = classifier.resolve_from(None)
    result = classifier.classify(from_rev, "HEAD")
    return result.to_dict()


@mcp.tool()
async def rebuild_dellan(ctx: Context) -> dict[str, Any]:
    """Rebuild dellan from current /etc/nixos HEAD.

    Low-blast diffs apply automatically. High-blast diffs surface a summary
    via elicitation; on user approval, polkit prompts for the password.
    """
    from_rev = classifier.resolve_from(None)
    classification = classifier.classify(from_rev, "HEAD")
    summary = _summarize(classification)

    if classification.tier == "low":
        result = _run_apply("low", classification.from_rev, classification.to_rev)
        return {
            "tier": "low",
            "summary": summary,
            **result,
        }

    # High tier — elicit
    elicit_result = await ctx.elicit(
        message=(
            "High-blast rebuild requested.\n\n"
            f"{summary}\n\n"
            "Approve to proceed (polkit will then prompt for your password)."
        ),
        schema=ApprovalSchema,
    )
    if elicit_result.action != "accept":
        return {
            "tier": "high",
            "summary": summary,
            "applied": False,
            "reason": f"user did not approve (action={elicit_result.action})",
        }

    data = elicit_result.data
    if not (data and getattr(data, "confirm", False)):
        return {
            "tier": "high",
            "summary": summary,
            "applied": False,
            "reason": "user did not set confirm=true",
        }

    result = _run_apply("high", classification.from_rev, classification.to_rev)
    return {
        "tier": "high",
        "summary": summary,
        **result,
    }


def main(argv: list[str] | None = None) -> int:
    mcp.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
