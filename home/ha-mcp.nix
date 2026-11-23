{ pkgs, ... }:
# The wrapper is built in overlays/ha-mcp.nix so NixOS modules can name its
# store path too.
{
  home.packages = [ pkgs.ha-mcp ];
}
