{
  # Codex documents hooks as advisory: timeout, crash, malformed output, and
  # MCP hook errors can fail open. Keep OS containment and approval review as
  # system requirements that user/project config and CLI flags cannot weaken.
  environment.etc."codex/requirements.toml".text = ''
    allowed_sandbox_modes = ["read-only", "workspace-write"]
    allowed_approval_policies = ["on-request"]
    allow_managed_hooks_only = true

    [features]
    hooks = true
  '';
}
