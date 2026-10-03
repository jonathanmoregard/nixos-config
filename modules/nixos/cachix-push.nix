# Push the DEPLOYED system closure to the public jonathanmoregard cachix
# cache after nixos-deploy switched to a new main commit.
#
# Why only the deployed closure: this used to be a global
# nix.settings.post-build-hook that pushed EVERY successful local build.
# The cache is publicly readable, so any local `nix build` of a private
# flake (Klaffat) published its outputs to the world — 31 Klaffat store
# paths were found in the public cache (security review 2026-10-03).
# A deployed system is built only from this public repo and its public
# flake inputs, so it is the one local build that is safe to publish.
#
# What it is for: nixos-deploy fires on the merge webhook, minutes before
# CI's push:main run has built and pushed the same toplevel. Whatever the
# first host built locally lands in the cache for the second host. CI
# (push:main only) remains the primary cache writer.
#
# Cost, stated: ad-hoc local builds (VM gates, feature-vm, test lanes)
# no longer warm the cache for CI.
#
# Trigger: a path unit on /var/lib/nixos-deploy/notify-success, which
# nixos-deploy touches only after a successful switch (never on no-op or
# deferred ticks) — so a push runs once per real deploy, not hourly.
#
# Resilience contract (the push is opportunistic, NOT load-bearing):
#   - The script ALWAYS exits 0; a push failure is logged and dropped.
#   - Each push is wrapped in `timeout` so a stalled upload (cachix.org
#     hiccup, slow network, server-side rate limit) can't run unbounded.
#   - Paths that can't realistically finish inside the timeout are
#     skipped up front (push-budget filter: *-microvm-store-disk.erofs
#     by name, plus anything over maxPathBytes).
#   - Failures + timeouts go to the journal of cachix-push-deployed.service.
#
# Contract enforced by checks.cachix-push-filter
# (tests/cachix-push-filter.nix), a runtime-invocation harness over the
# shared script template in ./cachix-push-hook.nix.
#
# Past incident (2026-05-19): with no timeout and `set -euf`, an
# 80 MiB firefox tarball push hung for 11+ minutes against an
# unresponsive cachix endpoint, then the hook exit code propagated
# upward and killed the nixosTest build that triggered it. The
# old comment "Hook exit code does NOT affect the build's overall
# success (Nix daemon swallows it)" was wishful — `set -e` + a
# non-zero `cachix push` propagated through the daemon to the
# top-level `nix build` invocation as a hard failure.
{ config, pkgs, lib, ... }:

let
  cacheName = "jonathanmoregard";

  # Wall-clock cap on each `cachix push` invocation. Tuned for the
  # largest artifact we expect to push routinely — a NixOS system
  # closure with firefox/chromium/android-studio. 300 MiB at a
  # 1 MiB/s pessimistic upstream = 5 min; 600s gives 2x headroom
  # before we cut losses.
  pushTimeoutSeconds = 600;

  # Per-path push budget. Anything larger than this cannot finish
  # inside pushTimeoutSeconds on dellan's ~2.4 Mbit uplink, so every
  # referencing derivation re-attempts the same blob forever.
  # Incident (2026-07-07): the ~621 MiB *-microvm-store-disk.erofs was
  # re-pushed dozens of times across two VM-gate runs (30-50 min each)
  # and once livelocked the uplink. Skipping is safe — the hook is
  # opportunistic; CI rebuilds whatever the cache misses.
  maxPathBytes = 256 * 1024 * 1024;

  # OUT_PATHS is space-separated store paths (here: the deployed
  # toplevel; `cachix push` uploads its closure minus what the caches
  # already hold). We DELIBERATELY DO NOT use `set -e`: any subcommand
  # failure must be swallowed so a push problem never reads as a
  # failed deploy.
  #
  # The script body lives in ./cachix-push-hook.nix, parameterized so
  # the runtime-invocation check (nix build
  # .#checks.x86_64-linux.cachix-push-filter -L) can exercise the same
  # logic with stubbed binaries and a short timeout. Keep logic there.
  pushHook = pkgs.writeShellScript "cachix-push-hook" (import ./cachix-push-hook.nix {
    inherit cacheName pushTimeoutSeconds maxPathBytes;
    tokenFile = config.age.secrets.cachix-auth-token.path;
    cachixBin = "${pkgs.cachix}/bin/cachix";
    timeoutBin = "${pkgs.coreutils}/bin/timeout";
    duBin = "${pkgs.coreutils}/bin/du";
    cutBin = "${pkgs.coreutils}/bin/cut";
  });

  pushDeployed = pkgs.writeShellScript "cachix-push-deployed" ''
    OUT_PATHS="$(${pkgs.coreutils}/bin/readlink -f /run/current-system)" || OUT_PATHS=""
    export OUT_PATHS
    exec ${pushHook}
  '';
in
{
  age.secrets.cachix-auth-token.rekeyFile = ../../secrets/cachix-auth-token.age;

  # Exact deployed script bytes, smoked by checks.cachix-push-filter.
  system.build.cachixPushHook = pushHook;

  # Deliberately NO nix.settings.post-build-hook: see the header.

  systemd.services.cachix-push-deployed = {
    description = "Push the deployed system closure to cachix";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pushDeployed}";
      Nice = 19;
      IOSchedulingClass = "idle";
      # The script's own timeout caps the push at pushTimeoutSeconds.
      TimeoutStartSec = "${toString (pushTimeoutSeconds + 120)}s";
    };
  };

  systemd.paths.cachix-push-deployed = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathChanged = "/var/lib/nixos-deploy/notify-success";
  };
}
