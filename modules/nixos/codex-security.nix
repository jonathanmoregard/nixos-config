{
  # Codex documents hooks as advisory: timeout, crash, malformed output, and
  # MCP hook errors can fail open. Keep the native permission profile as a
  # system requirement that user/project config and CLI flags cannot weaken.
  # User config selects the default profile but must not duplicate its
  # definition; Codex rejects duplicate managed and loaded profile names.
  environment.etc."codex/requirements.toml".text = ''
    default_permissions = "repos_dev"
    # Permit explicit approval prompts (including MCP writes). User config
    # still defaults to never; the managed permission profiles remain enforced.
    allowed_approval_policies = ["never", "on-request"]
    allow_managed_hooks_only = true

    [allowed_permission_profiles]
    repos_dev = true
    repos_readonly = true

    [permissions.repos_dev]
    description = "Repository development with protected Git metadata"
    extends = ":workspace"

    [permissions.repos_dev.workspace_roots]
    "/home/jonathan/Repos" = true
    "/home/jonathan/worktrees" = true

    [permissions.repos_dev.filesystem]
    "/home/jonathan/.local/state/ai-router" = "write"

    # Selectable read-only profile for delegated review jobs (ai-router
    # `delegate --sandbox read-only`). With profiles active, Codex ignores
    # `--sandbox read-only` and runs default_permissions, i.e. repos_dev
    # (workspace-write over ~/Repos and ~/worktrees). Select this with
    # `-c default_permissions="repos_readonly"` on `codex exec` AND on
    # `codex exec resume` (a resume without it falls back to repos_dev).
    # No write roots; :read-only has no network.
    [permissions.repos_readonly]
    description = "Read-only review: no write roots, no network"
    extends = ":read-only"

    [features]
    hooks = true
  '';

  # Keep Claude Code's session back-channel out of the environment Codex hands
  # to the commands it runs. A process holding both CLAUDE_CODE_MESSAGING_SOCKET
  # and CLAUDE_CODE_MESSAGING_TOKEN can drive the Claude Code session that
  # spawned it, and a Claude session invoking `codex exec` (codex-advise.sh, the
  # advice loop) passes its whole environment down. The adversary is prompt
  # injection reaching the Codex agent, not the operator.
  #
  # This is defence in depth, deliberately: measured 2026-10-27, a connect-only
  # probe inside Codex's sandbox is already refused — `PermissionError: [Errno 1]
  # Operation not permitted` — under plain `codex sandbox`, under
  # `sandbox_workspace_write.network_access=true`, and on the real `codex exec`
  # agent path, while the same probe unsandboxed connects fine. What makes the
  # second layer worth declaring is that the control in front of it is the same
  # kind that fail-opened on this host for weeks: sandbox-runtime resolves one
  # helper binary and, failing to find it, logs a single debug line and applies
  # no filter at all (see overlays/sandbox-runtime.nix, tests/sandbox-seccomp.nix).
  #
  # Both halves of the pair, because Codex's defaults drop neither: all 13
  # CLAUDE* variables survive into the sandbox untouched, TOKEN included.
  #
  # Patterns are globs, not regexes. `CLAUDE_CODE_MESSAGING_.*` silently matches
  # nothing and leaves both variables in place — verified the hard way.
  #
  # ignore_default_excludes stays false so Codex's own default patterns keep
  # applying on top of this one rather than being replaced by it; the key is
  # additive, not a substitution.
  environment.etc."codex/config.toml".text = ''
    [shell_environment_policy]
    ignore_default_excludes = false
    exclude = ["CLAUDE_CODE_MESSAGING_*"]
  '';
}
