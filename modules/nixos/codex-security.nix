{
  # Codex documents hooks as advisory: timeout, crash, malformed output, and
  # MCP hook errors can fail open. Keep the native permission profile as a
  # system requirement that user/project config and CLI flags cannot weaken.
  # User config selects the default profile but must not duplicate its
  # definition; Codex rejects duplicate managed and loaded profile names.
  environment.etc."codex/requirements.toml".text = ''
    default_permissions = "repos_dev"
    allowed_approval_policies = ["never"]
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
}
