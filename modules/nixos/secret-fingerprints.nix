# Known-value secret masking, producer half: salted SHA-256 fingerprints
# of agenix secret values, for consumers that must never hold plaintext
# (the ~/.claude output-redaction hook and the aggregator ingest
# scrubber, both running as jonathan). Regex rules only catch prefixed
# formats; this catches the rest by value. Which values are fingerprinted:
# secret-fingerprints/generate.py.
#
# ── Consumer contract (version 1) ──
#
#   Path:    /run/secret-fingerprints/jonathan.json — root:secret-fingerprints
#            0440 (cfg.user is the group's member), directory root 0755.
#            The reader can neither modify nor replace it. Replaced
#            atomically. Absent → no known values.
#   Schema:  {"version": 1, "salt": "<64 hex>", "min_len": 12,
#             "fingerprints": ["<64 hex>", ...], "generated": "<UTC ISO>"}
#            No secret names. Refuse a version other than 1.
#   Hash:    sha256(bytes.fromhex(salt) + v.encode("utf-8")).hexdigest()
#   Salt:    fresh on every run — re-read the file; never cache hashes.
#   Try v:   every maximal [A-Za-z0-9_-] run of >= min_len chars, and every
#            whitespace/quote-delimited token of >= min_len chars.
#   Health:  a degraded run writes /var/lib/unit-failures/secret-fingerprints.json,
#            which ~/.claude's unit-failure-health hook shows each session.
#
# ── Trigger ──
#
#   agenix decrypts in activation scripts: before systemd starts units at
#   boot, and before switch-to-configuration restarts units. So the unit is
#   wanted by multi-user.target, and its restartTriggers hold every
#   secret's ciphertext path, owner, group, mode and path: adding,
#   removing, re-encrypting or re-permissioning a secret changes the unit,
#   and the switch reruns it after the new secrets exist. Not a path unit
#   on /run/agenix: agenix swaps that symlink before agenixChown sets
#   owners, so a triggered run would race the readability probe.
#
#   The unit exits 0 on a degraded run: a failed unit fails
#   `nixos-rebuild switch`, which nixos-auto-deploy latches as a poisoned
#   commit, and a masking helper must not be able to stop deploys.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.secretFingerprints;
  group = "secret-fingerprints";
  failuresDir = "/var/lib/unit-failures";
  secretList = lib.attrValues config.age.secrets;

  manifest = pkgs.writeText "secret-fingerprints-manifest.json"
    (builtins.toJSON (map (s: s.path) secretList));

  triggers = pkgs.writeText "secret-fingerprints-triggers.json"
    (builtins.toJSON (map (s: {
      inherit (s) path owner group mode;
      file = toString s.file;
    }) secretList));
in
{
  options.services.secretFingerprints = {
    enable = lib.mkEnableOption
      "salted SHA-256 fingerprints of agenix secret values for output masking";
    user = lib.mkOption {
      type = lib.types.str;
      default = "jonathan";
      description = ''
        The reader of /run/secret-fingerprints/<user>.json. Secrets this
        user cannot read are root-only and pass a stricter entropy gate.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${group}.members = [ cfg.user ];

    systemd.tmpfiles.rules = [ "d ${failuresDir} 0755 root root -" ];

    systemd.services.secret-fingerprints = {
      description = "Fingerprint agenix secret values for known-value masking";
      wantedBy = [ "multi-user.target" ];
      after = [ "agenix-install-secrets.service" "systemd-tmpfiles-setup.service" ];
      restartTriggers = [ triggers ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.escapeShellArgs [
          "${pkgs.python3}/bin/python3" "-I" "${./secret-fingerprints/generate.py}"
          "${manifest}" cfg.user group "/run/secret-fingerprints/${cfg.user}.json"
          "${failuresDir}/secret-fingerprints.json"
        ];
        RuntimeDirectory = "secret-fingerprints";
        RuntimeDirectoryMode = "0755";
        # A restart must not delete the last good file before the new one
        # is renamed over it.
        RuntimeDirectoryPreserve = true;
        ReadWritePaths = [ failuresDir ];
        UMask = "0077";

        # Read others' 0400 files, probe as the user, chown the output.
        CapabilityBoundingSet = [
          "CAP_DAC_OVERRIDE" "CAP_DAC_READ_SEARCH" "CAP_CHOWN" "CAP_SETUID" "CAP_SETGID"
        ];
        NoNewPrivileges = true;
        PrivateNetwork = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
