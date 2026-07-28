{ pkgs, ... }:
# futuresearch-gate-mcp wrapper.
#
# Claude Code spawns `futuresearch-gate-mcp` as a stdio MCP subprocess
# (configured in ~/.claude.json). The gate is an injection-screening
# proxy for FutureSearch forecast results: content coming back from the
# FutureSearch API is scanned for prompt injection before it reaches
# the calling agent. Like research-agent-mcp, the gate self-updates the
# injection-scanner to latest on every boot and then runs a fail-closed
# boot smoke; the scanner's L3 honeypot calls Anthropic + OpenAI, and
# its L2 layer calls Lakera Guard, on every scan. Without ANTHROPIC_API_KEY
# / OPENAI_API_KEY / LAKERA_API_KEY in the spawn env the boot smoke fails
# closed (benign probe rejects, e.g. lakera_unavailable:no-key) and the
# server exits 2 before binding stdio — CC then reports the MCP as failed
# to connect (-32000).
#
# Unlike research-agent-mcp, the gate does no research and drives no
# VM, so it needs ONLY the three scanner keys — no EXA/TAVILY search
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
        # injection-scanner L2 (Lakera Guard) is fail-closed — the gate
        # self-updates to the latest scanner at boot, so without this the
        # boot smoke rejects and the server exits 2 (-32000).
        LAKERA_API_KEY=$(< /run/agenix/lakera-api-key)
        export ANTHROPIC_API_KEY OPENAI_API_KEY LAKERA_API_KEY

        # The scanner's Lakera call uses stdlib urllib, which finds no
        # CA bundle on NixOS with a uv-managed CPython — cert verify
        # fails (lakera_unavailable:URLError) and the fail-closed boot
        # smoke rejects. Full rationale in research-agent-mcp.nix.
        export SSL_CERT_FILE="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"

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
