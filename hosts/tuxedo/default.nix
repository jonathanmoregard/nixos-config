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

  # agenix-rekey per-host config — see hosts/dellan/default.nix. The host
  # key was generated on the machine during install; only its public half
  # is here.
  age.rekey.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO87IyCf5NBoDUYvRmjqmqa4bB02YItZu3RgeJ/JHgyu root@tuxedo";
  age.rekey.localStorageDir = ../../secrets/rekeyed/tuxedo;
}
