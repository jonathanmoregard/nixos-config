# Dell Latitude 7440 — the machine half of the daily driver. Everything
# hardware-neutral lives in profiles/workstation/; this file keeps only
# what is tied to this laptop's hardware and identity.
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./swap.nix
    ../../profiles/workstation
    ../../modules/nixos/dell-latitude-7440.nix
  ];

  networking.hostName = "dellan";

  # ---------------------------------------------------------------------
  # agenix-rekey per-host config.
  # hostPubkey = dellan's SSH ed25519 host key. Each .age secret's source
  # is encrypted to the master identity (see modules/nixos/agenix-rekey-common.nix);
  # `nix run .#agenix-rekey.x86_64-linux.rekey` produces a copy in
  # secrets/rekeyed/dellan/ encrypted to this hostPubkey, which is what
  # the running system decrypts against /etc/ssh/ssh_host_ed25519_key.
  # ---------------------------------------------------------------------
  age.rekey.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJNvaYqBU7k/iTKPHcfVGYz5WJNVWnf0t26SX6Y7SZ0e root@dellan";
  age.rekey.localStorageDir = ../../secrets/rekeyed/dellan;
}
