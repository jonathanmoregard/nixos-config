{
  # Codex documents hooks as advisory: timeout, crash, malformed output, and
  # MCP hook errors can fail open. Keep the native permission profile as a
  # system requirement that user/project config and CLI flags cannot weaken.
  environment.etc."codex/requirements.toml".text = ''
    default_permissions = "repos_dev"
    allowed_approval_policies = ["never"]
    allow_managed_hooks_only = true

    [allowed_permission_profiles]
    repos_dev = true

    [permissions.repos_dev]
    description = "Repository development with protected Git metadata"
    extends = ":workspace"

    [permissions.repos_dev.workspace_roots]
    "/home/jonathan/Repos" = true
    "/home/jonathan/worktrees" = true

    [permissions.repos_dev.filesystem]
    "/home/jonathan/.local/state/ai-router" = "write"

    [features]
    hooks = true
  '';
}
