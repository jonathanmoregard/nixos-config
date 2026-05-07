{ pkgs, ... }:
# research-agent-mcp wrapper.
#
# Claude Code spawns `research-agent-mcp` as a stdio MCP subprocess
# (configured in ~/.claude.json). The MCP server runs an injection
# scanner whose L3 honeypot calls Anthropic + OpenAI; without
# ANTHROPIC_API_KEY / OPENAI_API_KEY in the spawn env, smoke fails
# closed and the server exits before binding stdio.
#
# Claude Code's `env` block in ~/.claude.json takes literal values, not
# file paths. To keep the keys out of dotfiles we wrap with a shell
# script that sources both agenix-decrypted env-format files at exec
# time, then execs the Python entry from the project venv.
#
# Wrapper name `research-agent-mcp` matches the ~/.claude.json command
# string so the config doesn't need to change. The wrapped binary lives
# inside the project venv at a different absolute path, so no PATH loop.
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "research-agent-mcp";
      runtimeInputs = [ pkgs.uv ];
      text = ''
        # Source env-format secrets from agenix decrypt paths. set -a /
        # set +a is the only safe way to ingest a KEY=VAL file: plain
        # `source` without `-a` doesn't export to the child process,
        # `export $(<file)` mishandles values with spaces or `=` chars.
        set -a
        # shellcheck disable=SC1091
        source /run/agenix/anthropic-api-key
        # shellcheck disable=SC1091
        source /run/agenix/openai-api-key
        set +a

        exec uv run --project "$HOME/Repos/research-agent" \
            python3 -m mcp_server.server "$@"
      '';
    })
  ];
}
