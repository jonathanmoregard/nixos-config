{ config, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./deployment-identity.nix
    ../../profiles/home-server-base.nix
    ../../modules/nixos/home-server-services.nix
    ../../modules/nixos/agenix-rekey-common.nix
  ];

  # Directory exists before hardware does, but becomes an agenix-rekey
  # destination only after bootstrap records this host's real SSH public key.
  age.rekey = lib.mkIf (config.homeServer.ageHostPublicKey != null) {
    localStorageDir = ../../secrets/rekeyed/home-server;
  };

  # Bootstrap the standalone public system-release track. Keep the legacy
  # service defined for one generation so the in-flight deploy that activates
  # this configuration is not stopped on unit removal. Mask both deploy timers
  # to prevent overlapping deployers. After the legacy deploy exits, invoke the
  # standalone service once over pinned SSH; its target generation enables the
  # standalone timer. Rollback restores the previous complete deploy route.
  services.nixos-auto-deploy.enable = true;
  systemd.timers.nixos-deploy.enable = lib.mkForce false;
  services.system-auto-deploy.enable = true;
  systemd.timers.system-deploy.enable = lib.mkForce false;

  # New host-specific agenix declarations are inserted above this line by
  # `add-secret --host home-server` after the real host recipient is known.
  # add-secret:insert-here
}
