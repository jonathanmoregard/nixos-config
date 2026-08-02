# Lakera Guard policy pointer — single source of truth.
#
# The injection-scanner's L2 layer (injection_scanner/lakera.py) reads
# LAKERA_PROJECT_ID from the environment and, when set, sends
# payload["project_id"] with every /v2/guard call so the tuned per-project
# policy (L3 project configured in the Lakera dashboard) applies instead
# of the account default.
#
# This is a policy POINTER, not a secret — it selects which screening
# policy applies but grants no access by itself (the agenix-managed
# LAKERA_API_KEY does that), so it lives here as a plain nix string.
#
# Imported by every wrapper that spawns the scanner:
#   - home/research-agent-mcp.nix   (research-agent-mcp)
#   - home/futuresearch-gate-mcp.nix (futuresearch-gate-mcp)
#   - home/claude-services.nix      (claude-cl-sync-wrap)
# Change the id HERE and all three call sites follow.
{
  lakeraProjectId = "project-5833252261";
}
