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
  routerAgent = "/home/jonathan/Repos/router-agent";
  routerProxy = mode: [
    "uv" "run" "--directory" routerAgent "router-proxy"
    "--mode" mode
    "--paths" "/home/jonathan/.config/router/paths.yaml"
    "--policy" "${routerAgent}/config/policy.yaml"
    "--children" "${routerAgent}/config/children.yaml"
  ];
  routerIssue = "https://github.com/jonathanmoregard/nixos-config/issues/430";
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

    unreviewedAllowedCommands = {
      router-proxy-interactive = {
        argv = routerProxy "interactive";
        reason = "router-proxy from ~/Repos/router-agent's project .mcp.json, for interactive sessions in that repo. Runs uv from a writable checkout of a private repo, which cannot be a public flake input.";
        issue = routerIssue;
      };
      router-proxy-autonomous = {
        argv = routerProxy "autonomous";
        reason = "router-proxy for router-worker.service: launch.sh passes --strict-mcp-config --mcp-config with the profile .mcp.json in ~/.local/share/router-agent, whose uv --directory points at ~/Repos/router-agent, not the worker clone. Private source repo, so unpackaged.";
        issue = routerIssue;
      };
    };

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
