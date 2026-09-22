{ config, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./deployment-identity.nix
    ./zigbee-coordinator.nix
    ../../profiles/home-server-base.nix
    ../../modules/nixos/home-server-services.nix
    ../../modules/nixos/agenix-rekey-common.nix
  ];

  # Directory exists before hardware does, but becomes an agenix-rekey
  # destination only after bootstrap records this host's real SSH public key.
  age.rekey = lib.mkIf (config.homeServer.ageHostPublicKey != null) {
    localStorageDir = ../../secrets/rekeyed/home-server;
  };

  # New host-specific agenix declarations are inserted above this line by
  # `add-secret --host home-server` after the real host recipient is known.
  # add-secret:insert-here
}
