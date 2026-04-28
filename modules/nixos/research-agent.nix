{ config, pkgs, ... }:
# research-agent MCP wrapper.
# Reads ANTHROPIC_API_KEY + OPENAI_API_KEY from agenix-decrypted runtime paths
# at exec time (not baked into the Nix store). Both keys feed the injection
# scanner's honeypot probe (multi-provider ensemble — server aborts startup
# if either is missing). Re-register MCP against `research-agent-mcp` on PATH:
#   claude mcp add --scope user research-agent research-agent-mcp
let
  repo = "/home/jonathan/Repos/research-agent";
  anthropicPath = config.age.secrets.anthropic-api-key-scanner.path;
  openaiPath = config.age.secrets.openai-api-key-scanner.path;
  wrapper = pkgs.writeShellApplication {
    name = "research-agent-mcp";
    runtimeInputs = [ pkgs.uv ];
    text = ''
      ANTHROPIC_API_KEY=$(cat ${anthropicPath})
      OPENAI_API_KEY=$(cat ${openaiPath})
      export ANTHROPIC_API_KEY OPENAI_API_KEY
      exec uv run --project ${repo} python3 ${repo}/mcp_server/server.py "$@"
    '';
  };
in {
  age.secrets.anthropic-api-key-scanner = {
    file = ../../secrets/anthropic-api-key-scanner.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  age.secrets.openai-api-key-scanner = {
    file = ../../secrets/openai-api-key-scanner.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  environment.systemPackages = [ wrapper ];
}
