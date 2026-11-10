# Test-only HM entrypoint for vm-desktop.
#
# vm-desktop asserts on HM-installed Cinnamon bits: CopyQ binary,
# gnome-screenshot binary, Cinnamon dconf bindings, Nemo bookmarks.
# All come from home/cinnamon.nix + home/desktop-apps.nix, plus the
# lid-guard lid-close keys + agent-activity tool (home/lid-guard.nix), the
# cinnamon-rescue watchdog (home/cinnamon-watchdog.nix) and the
# desktop-freeze-sample forensic sampler (home/desktop-freeze-forensics.nix).
#
# Excludes kitty, ghostty, autodoro, drift-analyzer, router-services,
# claude-services, research-agent-mcp.
{ ... }:
{
  imports = [
    ./_test-base.nix
    ./jonathan.nix
    ./cinnamon.nix
    ./cinnamon-watchdog.nix
    ./desktop-freeze-forensics.nix
    ./lid-guard.nix
    ./desktop-apps.nix
  ];
}
