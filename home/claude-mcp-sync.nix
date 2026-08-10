{ pkgs, ... }:
# Auto-capture the mcpServers slice of ~/.claude.json into a tracked
# file inside the ~/.claude git repo on every push.
#
# Why: ~/.claude.json is Claude Code's live global state (OAuth token,
# per-project session history, telemetry — ~150KB, rewritten every
# session), and tracking it whole would churn every session and leak
# credentials. The mcpServers slice is the only part worth versioning.
# ~/.claude/scripts/sync-mcp-servers.sh (owned by the ~/.claude repo)
# has `export` / `import` / `diff` subcommands; this hook wires the
# export step to run automatically when the user pushes ~/.claude, so
# the tracked snapshot rides along with every push instead of drifting
# silently.
#
# Non-blocking by construction: export writes to a tmp file and mv's
# it atomically, the git-add is best-effort under `|| true`, and the
# shared hook (home/git-hooks.nix) exits 0 unconditionally.
{
  homeGitHooks.prePush = [
    {
      name = "claude-mcp-sync";
      repoPath = "$HOME/.claude";
      body = ''
        # Capture live mcpServers slice into the tracked snapshot.
        # Runs || true so a jq / mv failure never blocks the push.
        # If the export produced a diff, stage it so the *next* commit
        # picks it up — we deliberately do NOT auto-commit here
        # because the fresh commit would not be included in this
        # push (git already computed the ref list). The user notices
        # the staged change on next `git status`.
        if [ -x "$HOME/.claude/scripts/sync-mcp-servers.sh" ]; then
          "$HOME/.claude/scripts/sync-mcp-servers.sh" export || true
          ${pkgs.git}/bin/git -C "$HOME/.claude" add mcp-servers.json 2>/dev/null || true
        fi
      '';
    }
  ];
}
