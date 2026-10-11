# Known-value secret masking, producer half: salted SHA-256 fingerprints
# of every agenix secret value, readable by the user agents run as.
#
# ── Why ──
#
# Agent tool output is redacted by regex / gitleaks rules, and those only
# catch formats with a recognisable prefix or armour. Format-less secrets
# (a UUID-shaped API key, a Hetzner token, a client secret, a passphrase)
# pass straight through. CI systems solve this with known-VALUE masking.
# The consumers — the ~/.claude PostToolUse redaction hook and the
# aggregator ingest scrubber, both running as jonathan — hash candidate
# tokens from output and redact matches. They must never hold plaintext,
# so this unit gives them fingerprints only.
#
# ── Consumer contract (version 1) ──
#
#   Path:   /run/secret-fingerprints/<user>.json   (jonathan.json here)
#           owner <user>, group root, mode 0400; directory root 0755.
#           Rewritten atomically (rename), so a reader never sees half a
#           file. Absent until the first run after boot finishes; a
#           consumer must treat "absent" as "no known values", not error.
#   Schema: {"version": 1,
#            "salt": "<64 lowercase hex = 32 random bytes>",
#            "min_len": 12,
#            "fingerprints": ["<64 lowercase hex>", ...],   sorted, unique
#            "generated": "<UTC ISO-8601, e.g. 2026-10-11T18:00:00Z>"}
#           No secret names, no per-secret grouping: counts only.
#   Recipe: fp(v) = sha256(bytes.fromhex(salt) + v.encode("utf-8")).hexdigest()
#           A candidate v from tool output is a known secret iff
#           len(v) >= min_len and fp(v) is in the set.
#   Which v to try: every maximal run of [A-Za-z0-9_-] of length >=
#           min_len, AND every whitespace/quote-delimited token of length
#           >= min_len (so values containing . / + = : ? are caught
#           whole — URLs, base64). Every fingerprinted value is one of
#           those shapes or has its [A-Za-z0-9_-] runs fingerprinted too.
#   Refuse a file whose "version" is not 1.
#
# ── What is fingerprinted (generate.py) ──
#
#   Per secret: the whole file (trimmed); each KEY=value value (quotes and
#   unquoted ` #` comments stripped); each JSON string value; each other
#   non-empty line; and every maximal [A-Za-z0-9_-]{12,} run of those.
#   Skipped: values < 12 chars; PEM / OpenSSH private-key blocks (the
#   regex rules catch their armour); derived values without both a digit
#   and a letter ("service_account", file paths, a secret's own name —
#   masking those would redact ordinary words and gain nothing).
#
# ── Brute force: the root-only entropy rule ──
#
#   The jonathan-readable output plus its salt is enough to test guesses
#   offline at GPU speed (~1e10 SHA-256/s). For a secret jonathan can
#   already read that costs nothing — he can read the value itself. For a
#   ROOT-ONLY secret (the klaffat-* provisioning credentials, encrypted to
#   the host key precisely so the agent principal cannot read them) a
#   weak, human-chosen value would become crackable. So root-only values
#   are fingerprinted only when they look machine-generated: >= 24 chars
#   of [A-Za-z0-9_+/=.-] that are either hex (>= 32 hex digits, UUIDs
#   included) or mixed-case with >= 3 separate digit runs. Rationale and
#   measured alternatives (zxcvbn rates "correct-horse-battery-staple" at
#   1e20 guesses, so it is not a sound lower bound) in generate.py's
#   machine_token(). A slow hash for root-only values was rejected: every
#   consumer would pay it per output token.
#
#   "Readable" is decided at runtime by asking AS the user (access(2) in
#   a child with the user's uid/gid/groups), not from declared owner/mode,
#   so directory modes, ACLs and group membership all count. A failed
#   probe classifies everything as root-only (safe direction) and fails
#   the unit.
#
# ── Trigger ──
#
#   agenix decrypts in an activation script (system.activationScripts.
#   agenixInstall): before systemd starts at boot, and before units are
#   (re)started on every switch. So:
#     boot   — wantedBy multi-user.target; secrets already exist.
#     switch — restartTriggers carries every secret's ciphertext store
#              path, owner, group, mode and path. Any secret added,
#              removed, re-encrypted with a new value or re-permissioned
#              changes the unit, and switch-to-configuration restarts it
#              AFTER activation has decrypted the new generation.
#   Rejected: a .path unit on /run/agenix (agenix swaps that symlink at
#   the end of agenixInstall but applies owners afterwards, in
#   agenixChown, so a triggered run would race the ownership the
#   readability probe measures — and inotify on a replaced symlink is
#   fragile), and regenerating inside an activation script (an exception
#   there fails every switch; a unit is isolated and can be rerun with
#   `systemctl restart secret-fingerprints`). Manual rerun is always safe:
#   the output is a pure function of the secrets and the persisted salt.
#
# ── Failure reporting ──
#
#   A declared secret missing or unreadable, a failed readability probe,
#   or a crash: the file is still written with everything that worked
#   (partial masking beats none), the journal says DEGRADED with counts,
#   and generate.py writes /var/lib/unit-failures/secret-fingerprints.json
#   — the record ~/.claude/hooks/unit-failure-health.py surfaces in every
#   Claude session (shape as in nix-gc.nix). A clean run removes it.
#   The unit still exits 0: a failed unit fails `nixos-rebuild switch`,
#   and nixos-auto-deploy latches a failed switch as a poisoned commit, so
#   a masking helper must never be able to stop deploys. It exits non-zero
#   only when even the record cannot be written.
#
# Logs carry counts only — never values, never secret names.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.secretFingerprints;

  stateDir = "/var/lib/secret-fingerprints";
  runtimeDir = "/run/secret-fingerprints";
  outPath = "${runtimeDir}/${cfg.user}.json";

  failuresDir = "/var/lib/unit-failures";
  record = "${failuresDir}/secret-fingerprints.json";

  secretList = lib.attrValues config.age.secrets;

  # Paths only: generate.py needs nothing else, and the output never
  # names a secret.
  manifest = pkgs.writeText "secret-fingerprints-manifest.json"
    (builtins.toJSON (map (s: s.path) secretList));

  # Everything about a secret that can change its value or who can read
  # it. `file` is the ciphertext's store path, so a new value is a new
  # trigger.
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
        The user the fingerprint file is for: it owns
        ${runtimeDir}/<user>.json, and root-only means "not readable by
        this user" for the entropy rule.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Shared with nix-gc and security-batch, which mkdir it on demand; it
    # must exist up front here because the unit's filesystem is read-only
    # outside its ReadWritePaths.
    systemd.tmpfiles.rules = [ "d ${failuresDir} 0755 root root -" ];

    systemd.services.secret-fingerprints = {
      description = "Fingerprint agenix secret values for known-value masking";
      wantedBy = [ "multi-user.target" ];
      # agenix runs in activation today; if it ever moves to its systemd
      # unit, order after it rather than racing it.
      after = [ "agenix-install-secrets.service" "systemd-tmpfiles-setup.service" ];
      restartTriggers = [ triggers ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.escapeShellArgs [
          "${pkgs.python3}/bin/python3" "-I" "${./secret-fingerprints/generate.py}"
          "${manifest}" cfg.user stateDir outPath record
        ];
        StateDirectory = "secret-fingerprints";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "secret-fingerprints";
        RuntimeDirectoryMode = "0755";
        # Keep the last good file across restarts; the atomic rename
        # replaces it. Without this a restart deletes it first.
        RuntimeDirectoryPreserve = true;
        UMask = "0077";
        ReadWritePaths = [ failuresDir ];

        # Root, but only what reading 0400 files of other owners, the
        # as-user readability probe and the chown of the output need.
        CapabilityBoundingSet = [
          "CAP_DAC_OVERRIDE" "CAP_DAC_READ_SEARCH" "CAP_CHOWN" "CAP_FOWNER"
          "CAP_SETUID" "CAP_SETGID"
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
