{ pkgs, ... }:
# futuresearch-gate-mcp wrapper.
#
# Claude Code spawns `futuresearch-gate-mcp` as a stdio MCP subprocess
# (configured in ~/.claude.json). The gate is an injection-screening
# proxy for FutureSearch forecast results: content coming back from the
# FutureSearch API is scanned for prompt injection before it reaches
# the calling agent. Like research-agent-mcp, the injection-scanner's
# L3 honeypot calls Anthropic + OpenAI on every scan, and the server
# runs a boot smoke at startup — without ANTHROPIC_API_KEY /
# OPENAI_API_KEY in the spawn env the smoke fails closed and the
# server exits 2 before binding stdio.
#
# Unlike research-agent-mcp, the gate does no research and drives no
# VM, so it needs ONLY the two scanner keys — no EXA/TAVILY search
# providers, no Claude Code OAuth token, no EUIPO credentials, no
# RESEARCH_SSH_KEY.
#
# The python module (futuresearch_gate.server) lives in the standalone
# futuresearch-gate repo (github.com/jonathanmoregard/futuresearch-gate,
# depends only on the injection-scanner package), already checked out
# at ~/Repos/futuresearch-gate — so there is no deploy-order dependency:
# the wrapper works as soon as it lands on PATH.
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "futuresearch-gate-mcp";
      # No tesseract: the gate produces no browser-screenshot artifacts,
      # so there is no OCR step (contrast research-agent-mcp.nix).
      runtimeInputs = [ pkgs.uv ];
      text = ''
        # Read raw-value secrets from agenix decrypt paths. The `.age`
        # files contain ONLY the key (no `ANTHROPIC_API_KEY=` prefix),
        # so `source` would mis-interpret line 1 as a shell command.
        # `$(< file)` reads the file body and strips the trailing
        # newline — exactly what we want as an env var value.
        ANTHROPIC_API_KEY=$(< /run/agenix/anthropic-api-key)
        OPENAI_API_KEY=$(< /run/agenix/openai-api-key)
        export ANTHROPIC_API_KEY OPENAI_API_KEY

        # Project dir for `uv run`. Override-friendly for pre-deploy
        # testing (mirrors the RESEARCH_SSH_KEY pattern in
        # research-agent-mcp.nix): a caller exporting
        # FUTURESEARCH_GATE_PROJECT before us wins.
        GATE_PROJECT="''${FUTURESEARCH_GATE_PROJECT:-$HOME/Repos/futuresearch-gate}"

        exec uv run --project "$GATE_PROJECT" \
            python3 -m futuresearch_gate.server "$@"
      '';
    })
  ];
}
