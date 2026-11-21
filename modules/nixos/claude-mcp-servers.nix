# The MCP servers Claude Code may start on this host, with their final argv.
# claude-mcp-policy.nix turns this into the managed allowlist and the list
# claude-mcp-import.nix mirrors into ~/.claude.json.
{ pkgs, ... }:
let
  python3 = "/run/current-system/sw/bin/python3";
  runtime = "/var/lib/claude-runtime/checkout/runtime";
  served = dir: timeout: {
    command = python3;
    args = [ "${runtime}/mcps/${dir}/server.py" ];
    inherit timeout;
  };
in
{
  imports = [ ./claude-mcp-policy.nix ];

  claude.mcp = {
    enable = true;

    servers = {
      research-agent = {
        command = "${pkgs.research-agent-mcp}/bin/research-agent-mcp";
        env.RESEARCH_AGENT_TIMEOUT = "5700";
        timeout = 6000000;
      };
      home-assistant.command = "${pkgs.ha-mcp}/bin/ha-mcp";
      aggregator.command = "${pkgs.aggregator}/bin/aggregator-mcp";
      github = {
        command = "${pkgs.github-mux}/bin/github-mux";
        timeout = 600000;
      };
      reddit.command = "${pkgs.mcp-server-reddit}/bin/mcp-server-reddit";
      gdocs-review = {
        command = "${pkgs.gdocs-review-mcp}/bin/gdocs-review-mcp";
        env.WORKSPACE_MCP_CREDENTIALS_DIR = "/home/jonathan/.google_workspace_mcp/credentials";
      };
      git_broker = served "git-broker" 600000;
      klaffat-app-runner = served "klaffat-app-runner" 1900000;
      agent_e2e_broker = served "agent-e2e-broker" 3900000;
      jobs_broker = served "jobs-broker" 600000;
    };

    extraAllowedCommands = [
      [ python3 "${runtime}/scripts/dev-mcp/dispatch.py" ]
    ];

    connectorUrls = [
      "https://api.anthropic.com/v1/pages/mcp"
      "https://mcp.airtable.com/mcp"
      "https://mcp.ticktick.com"
      "https://mcp.calendly.com"
      "https://drivemcp.googleapis.com/mcp/v1"
      "https://calendarmcp.googleapis.com/mcp/v1"
      "https://gmailmcp.googleapis.com/mcp/v1"
    ];
  };
}
