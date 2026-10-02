# Scheduled Nix garbage collection, and keeping recently built store
# paths alive across it.
#
# Daily GC reclaims old profile generations and unreachable store paths
# before they can fill the root filesystem again; Nix's min-free/max-free
# guard (modules/common.nix) also reacts during build spikes.
#
# `nix-collect-garbage --delete-older-than 14d` only ages out *profile
# generations*; every store path no root reaches is deleted on the next
# run, however fresh. Dev shells entered with `nix develop --command …`
# and crane `cargoArtifacts` built by `nix build` / `nix flake check` are
# never rooted, so the daily timer evicted them every night and the next
# agent session rebuilt or re-fetched them cold (RSI proposal
# 2026-09-19-nix-auto-gc-evicts-build-cache-mid-session; journal on
# tuxedo 2026-10-01/02: ~3.6k paths per run, incl. the rustc/rustfmt
# wrappers klaffat's dev shell uses).
#
# Upstream has no age gate for unrooted paths yet (NixOS/nix#7572, PR
# #14725). Until it does, the nix-gc unit roots every path registered in
# the last `days` days for the duration of the run only:
#
#   preStart  — symlink each recent path into gcroots/keep-recent
#   script    — the stock nix-collect-garbage, unchanged
#   postStop  — remove the roots again (runs on success AND failure)
#
# The roots exist only while nix-gc.service runs, so the in-build
# min-free/max-free emergency collector and manual `nix-collect-garbage`
# still see that garbage as reclaimable: disk pressure wins over cache.
# A failure while pinning fails the unit before collection starts, so
# the cache is never deleted unprotected.
#
# Known limit: age is registration time, not last use. A closure that
# stays unchanged and unrooted for longer than `days` is still collected
# once per `days`+1 nights (weekly instead of nightly at the default).
# Closures that must never go cold want a real root (`nix develop
# --profile`, nix-direnv).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.nixGcKeepRecent;
  rootsDir = "/nix/var/nix/gcroots/keep-recent";

  pinRecent = pkgs.writeShellApplication {
    name = "nix-gc-pin-recent";
    runtimeInputs = [ config.nix.package pkgs.jq pkgs.coreutils pkgs.findutils ];
    text = ''
      days=${toString cfg.days}
      cutoff=$(( $(date +%s) - days * 86400 ))

      rm -rf -- ${rootsDir}
      mkdir -p -- ${rootsDir}

      # registrationTime is when the path became valid in this store
      # (built or substituted). `nix path-info --all` is the supported
      # read of it; no direct db.sqlite access.
      nix --extra-experimental-features nix-command \
        path-info --all --json --json-format 1 \
        | jq -r --argjson cutoff "$cutoff" \
            'to_entries[] | select(.value.registrationTime >= $cutoff) | .key' \
        | xargs -r ln -s -t ${rootsDir} --

      pinned=$(find ${rootsDir} -mindepth 1 -maxdepth 1 | wc -l)
      echo "nix-gc-pin-recent: rooted $pinned paths registered in the last $days days"
    '';
  };
in
{
  options.services.nixGcKeepRecent.days = lib.mkOption {
    type = lib.types.ints.positive;
    default = 7;
    description = ''
      Store paths registered within this many days survive the scheduled
      nix-gc run even when nothing roots them. Emergency (min-free) and
      manual collections are unaffected.
    '';
  };

  config = {
    nix.gc = {
      automatic = true;
      dates = [ "daily" ];
      options = "--delete-older-than 14d";
    };

    # Power loss mid-run skips postStop; drop leftover roots at boot so
    # they never outlive the run that made them by more than one boot.
    systemd.tmpfiles.rules = [ "R ${rootsDir}" ];

    systemd.services.nix-gc = {
      preStart = "${lib.getExe pinRecent}";
      postStop = "${pkgs.coreutils}/bin/rm -rf -- ${rootsDir}";
    };
  };
}
