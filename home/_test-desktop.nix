# Test-only HM entrypoint for vm-desktop.
#
# vm-desktop asserts on HM-installed Cinnamon bits: CopyQ binary,
# gnome-screenshot binary, Cinnamon dconf bindings, Nemo bookmarks.
# All come from home/cinnamon.nix + home/desktop-apps.nix.
#
# Excludes kitty, ghostty, autodoro, drift-analyzer, router-services,
# claude-services, claude-skills, research-agent-mcp.
{ ... }:
{
  imports = [
    ./_test-base.nix
    ./jonathan.nix
    ./cinnamon.nix
    ./desktop-apps.nix
  ];
}
