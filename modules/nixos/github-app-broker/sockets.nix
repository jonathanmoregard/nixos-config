# Where the GitHub App key broker (./default.nix) listens. Imported by the
# broker and by its jonathan-side clients (gh-token.service in
# home/claude-services.nix, home/github-app-mcp.nix), so the paths have one
# home.
{
  # One line in: `<app_id> <installation_id> [<repo_id>]`.
  # One line out: GitHub's installation-token JSON, or `refused: ...`.
  token = "/run/github-app/token.sock";
  # One header line in: `<app_id> <installation_id> <server args...>`,
  # then the MCP stdio stream in both directions.
  mcp = "/run/github-app/mcp.sock";
}
