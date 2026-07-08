# Auto-push every successful local build to the jonathanmoregard
# cachix cache via nix.settings.post-build-hook.
#
# Why: when I `nix build .#nixosConfigurations.dellan...toplevel` or
# `nix build .#checks.x86_64-linux.vm-base` on dellan, the resulting
# store paths only live in dellan's local /nix/store. CI on GHA then
# rebuilds the same closures cold because cachix has never seen them.
# With this hook, every successful local build pushes to cachix → the
# next CI run on the same closure substitutes from cache instead.
#
# Test runs (`vm-test-run-vm-*` derivations) push too — they're
# content-addressed store paths like any other; cachix dedupes by hash.
#
# Resilience contract (the hook is opportunistic, NOT load-bearing):
#   - The hook ALWAYS exits 0. A `cachix push` failure must NEVER fail
#     a build — the build artifact is fine on local /nix/store, the
#     remote cache miss is a separate problem.
#   - Each push is wrapped in `timeout` so a stalled upload (cachix.org
#     hiccup, slow network, server-side rate limit) can't hang the
#     whole rebuild. SIGKILL after the timeout; log and move on.
#   - Paths that can't realistically finish inside the timeout are
#     skipped up front (push-budget filter: *-microvm-store-disk.erofs
#     by name, plus anything over maxPathBytes) — otherwise EVERY
#     referencing derivation re-attempts the same doomed upload.
#   - Failures + timeouts go to the journal (stderr is captured by
#     systemd-journald via the nix-daemon service), so they're
#     diagnosable but invisible to interactive build sessions.
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

  # Nix daemon invokes this after every successful local build.
  # OUT_PATHS is space-separated store paths; `cachix push` accepts
  # multiple paths in one invocation. We DELIBERATELY DO NOT use
  # `set -e`: any subcommand failure must be swallowed locally so
  # the script returns 0 to nix-daemon.
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
in
{
  age.secrets.cachix-auth-token.rekeyFile = ../../secrets/cachix-auth-token.age;

  nix.settings.post-build-hook = "${pushHook}";
}
