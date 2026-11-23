{ pkgs, ... }:
# The wrapper is built in overlays/research-agent-mcp.nix so NixOS modules
# can name its store path too.
{
  home.packages = [ pkgs.research-agent-mcp ];
}
