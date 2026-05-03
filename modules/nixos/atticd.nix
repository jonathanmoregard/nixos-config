# modules/nixos/atticd.nix
#
# Self-hosted Nix binary cache (Attic) on dellan. Used by the GHA runner
# and by manual builds in worktrees to deduplicate /nix/store paths
# across builds.
#
# Listening on 127.0.0.1:8080 (overridable). Trust model: the public
# signing key is generated on first start (chicken-and-egg with
# trusted-public-keys); see B.6 / A.4 of the spec for the bootstrap flow.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.atticCache;
in
{
  options.services.atticCache = {
    enable = lib.mkEnableOption "self-hosted Attic binary cache";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "TCP port for the Attic API. Overridable to avoid dev-server collisions.";
    };

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "dellan";
      description = "Cache name component of the substituter URL (http://localhost:PORT/<name>).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.atticd = {
      enable = true;
      # Settings minimal — bootstrap flow expects atticd to generate the
      # signing key on first start. The public key is then committed into
      # flake.nix's trusted-public-keys (see B.6).
      settings = {
        listen = "127.0.0.1:${toString cfg.port}";
        # Use file-backed storage for the chunk store. NixOS module
        # supplies sensible defaults; override here only if needed.
      };
    };

    # Marker file that an activation script can use to gate "include Attic
    # as a substituter". The marker is written manually as part of the
    # bootstrap procedure once the public key is committed to flake.nix.
    systemd.tmpfiles.rules = [
      "d /var/lib/atticd 0755 atticd atticd - -"
    ];

    # Open the port to localhost only (defense in depth; default firewall
    # may not block lo, but this makes intent explicit).
    networking.firewall.interfaces.lo.allowedTCPPorts = [ cfg.port ];
  };
}
