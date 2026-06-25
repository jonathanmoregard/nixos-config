{ pkgs, ... }:
# research-agent-mcp wrapper.
#
# Claude Code spawns `research-agent-mcp` as a stdio MCP subprocess
# (configured in ~/.claude.json). The MCP server has two key dependencies
# at startup:
#
#  1. The injection-scanner L3 honeypot calls Anthropic + OpenAI on every
#     scan. Without ANTHROPIC_API_KEY / OPENAI_API_KEY in the spawn env,
#     smoke fails closed and the server exits before binding stdio.
#  2. The research agent itself (inside the dev container) needs EXA +
#     TAVILY for search providers and a Claude Code OAuth token to drive
#     the headless `claude` CLI. Without these, `research()` calls fail
#     at the first tool invocation with `<provider>-api-key not in keyring`.
#
# The MCP server's secret loader prefers env vars before falling back to
# the GNOME keyring (see `_SECRET_ENV` in mcp_server/server.py). On NixOS
# the keyring isn't the source of truth — agenix is — so we always
# populate via env to keep behaviour fully declarative.
#
# Claude Code's `env` block in ~/.claude.json takes literal values, not
# file paths. We wrap with a shell script that reads each
# agenix-decrypted file (raw value, no env prefix) and exports the
# corresponding env var at exec time, then execs the Python entry from
# the project venv.
#
# Post-microvm migration: the SSH transport reads `RESEARCH_SSH_KEY`
# (default: agenix-decrypted host-to-VM private key path). The MCP
# server's `_ssh_settings()` reads it lazily at call time so we just
# export it here.
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
        EXA_API_KEY=$(< /run/agenix/exa-api-key)
        TAVILY_API_KEY=$(< /run/agenix/tavily-api-key)
        CLAUDE_CODE_OAUTH_TOKEN=$(< /run/agenix/claude-token)
        # EUIPO OAuth2 client_credentials for the trademark_shim. Both
        # files start empty (placeholder) and decrypt to empty strings
        # until the EUIPO dev-portal subscription is approved; the shim's
        # _clean_env() guard treats an empty value as unset and the tool
        # errors cleanly only when actually called — so existing research
        # paths keep working with the secrets unset.
        EUIPO_CLIENT_ID=$(< /run/agenix/euipo-client-id)
        EUIPO_CLIENT_SECRET=$(< /run/agenix/euipo-client-secret)
        export ANTHROPIC_API_KEY OPENAI_API_KEY \
               EXA_API_KEY TAVILY_API_KEY CLAUDE_CODE_OAUTH_TOKEN \
               EUIPO_CLIENT_ID EUIPO_CLIENT_SECRET

        # Host-to-VM SSH private key. The mcp_server reads this lazily
        # in _ssh_settings(); we only need to point it at the agenix
        # decrypt path. Override-friendly: a caller exporting
        # RESEARCH_SSH_KEY before us wins.
        export RESEARCH_SSH_KEY="''${RESEARCH_SSH_KEY:-/run/agenix/research-agent-host-key}"

        exec uv run --project "$HOME/Repos/research-agent" \
            python3 -m mcp_server.server "$@"
      '';
    })
  ];
}
