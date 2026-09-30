# TUXEDO InfinityBook Pro AMD Gen10 (Ryzen AI 9 HX 370) — Dellan's
# successor. Everything hardware-neutral lives in profiles/workstation/;
# this file keeps only what is tied to this laptop's hardware and identity.
# Disk layout mirrors dellan: LUKS2 `cryptroot` + btrfs @ @home @nix @log.
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./swap.nix
    ../../profiles/workstation
    ../../modules/nixos/tuxedo-infinitybook-pro-15-gen10-amd.nix
  ];

  networking.hostName = "tuxedo";

  # The install created the agents before uids were pinned, so they took
  # 1000-1002 and jonathan 1003. Pin those live values rather than rewrite
  # uids on a running system; nothing depends on the number.
  users.users.jonathan.uid = 1003;
  services.claudeAgentUsers.uidBase = 999;

  # Dellan's user key, so the outgoing laptop can configure this one during
  # the overlap. Remove when Dellan is retired.
  users.users.jonathan.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan"
  ];

  # The 15.3" 2560x1600 panel is ~197 DPI. Muffin only does integer scale on
  # X11 and auto-picks 2x for it (a 1280x800 desktop), where Dellan's
  # ~162 DPI panel gets 1x. Pin the built-in panel to 1x and bring text back
  # up instead; 1.2 is the DPI ratio between the two panels (Dellan-sized
  # text), 1.3 is one step above that by taste. Muffin reads monitors.xml
  # from XDG_CONFIG_DIRS as the system default; a layout saved from Display
  # settings (~/.config/cinnamon-monitors.xml) still overrides it, and
  # layouts with an external monitor attached are not covered by this entry.
  environment.etc."xdg/monitors.xml".text = ''
    <monitors version="2">
      <configuration>
        <logicalmonitor>
          <x>0</x>
          <y>0</y>
          <scale>1</scale>
          <primary>yes</primary>
          <monitor>
            <monitorspec>
              <connector>eDP-1</connector>
              <vendor>BOE</vendor>
              <product>NE153QDM-NZ2</product>
              <serial>0x00000000</serial>
            </monitorspec>
            <mode>
              <width>2560</width>
              <height>1600</height>
              <rate>300</rate>
            </mode>
          </monitor>
        </logicalmonitor>
      </configuration>
    </monitors>
  '';
  home-manager.users.jonathan.dconf.settings = {
    "org/cinnamon/desktop/interface".text-scaling-factor = 1.3;
    "org/gnome/desktop/interface".text-scaling-factor = 1.3;
  };

  # agenix-rekey per-host config — see hosts/dellan/default.nix. The host
  # key was generated on the machine during install; only its public half
  # is here.
  age.rekey.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO87IyCf5NBoDUYvRmjqmqa4bB02YItZu3RgeJ/JHgyu root@tuxedo";
  age.rekey.localStorageDir = ../../secrets/rekeyed/tuxedo;
}
