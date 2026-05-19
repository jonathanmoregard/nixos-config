# Test-only HM entrypoint for vm-kitty.
#
# vm-kitty exercises kitty session save → kill → restore (4-pane 2x2
# grid). Needs:
#   - home/kitty.nix     → wrappers, scripts, systemd user units
#   - home/jonathan.nix  → packages used inside the test (jq via su, p10k
#                          for shell init, base nodejs/python toolchain
#                          some scripts assume on PATH)
#
# Excludes cinnamon, desktop-apps, ghostty, autodoro, drift-analyzer,
# router-services, claude-services, claude-skills, research-agent-mcp.
{ ... }:
{
  imports = [
    ./_test-base.nix
    ./jonathan.nix
    ./kitty.nix
  ];
}
