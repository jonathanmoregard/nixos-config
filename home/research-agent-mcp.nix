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
# script that reads each agenix-decrypted file (raw value, no env
# prefix) and exports the corresponding env var at exec time, then
# execs the Python entry from the project venv.
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
        # Read raw-value secrets from agenix decrypt paths. The `.age`
        # files contain ONLY the key (no `ANTHROPIC_API_KEY=` prefix),
        # so `source` would mis-interpret line 1 as a shell command:
        # `sk-ant-...: command not found`. `$(< file)` reads the file
        # body and strips the trailing newline — exactly what we want
        # as an env var value.
        ANTHROPIC_API_KEY=$(< /run/agenix/anthropic-api-key)
        OPENAI_API_KEY=$(< /run/agenix/openai-api-key)
        export ANTHROPIC_API_KEY OPENAI_API_KEY

        exec uv run --project "$HOME/Repos/research-agent" \
            python3 -m mcp_server.server "$@"
      '';
    })
  ];
}
