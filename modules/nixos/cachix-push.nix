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
#   - Failures + timeouts go to the journal (stderr is captured by
#     systemd-journald via the nix-daemon service), so they're
#     diagnosable but invisible to interactive build sessions.
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

  # Nix daemon invokes this after every successful local build.
  # OUT_PATHS is space-separated store paths; `cachix push` accepts
  # multiple paths in one invocation. We DELIBERATELY DO NOT use
  # `set -e`: any subcommand failure must be swallowed locally so
  # the script returns 0 to nix-daemon.
  pushHook = pkgs.writeShellScript "cachix-push-hook" ''
    set -uf
    export IFS=' '
    if [ -z "''${OUT_PATHS:-}" ]; then
      exit 0
    fi
    tokenFile="${config.age.secrets.cachix-auth-token.path}"
    if [ ! -r "$tokenFile" ]; then
      # Secret not yet activated (early boot, or recipient mismatch).
      exit 0
    fi

    # Capture the exit code BEFORE any `if`-test or `!`-inversion —
    # bash zeroes `$?` once a conditional has decided, so reading rc
    # from inside an `if ! cmd; then` block always sees 0 and the
    # 124/137 timeout-vs-failure discriminator below would be wrong.
    rc=0
    # shellcheck disable=SC2086 # OUT_PATHS is intentionally word-split
    CACHIX_AUTH_TOKEN="$(< "$tokenFile")" \
      ${pkgs.coreutils}/bin/timeout \
        --signal=KILL --kill-after=5s ${toString pushTimeoutSeconds}s \
      ${pkgs.cachix}/bin/cachix push ${cacheName} $OUT_PATHS \
      >&2 || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" = "137" ] || [ "$rc" = "124" ]; then
        echo "cachix-push-hook: timed out after ${toString pushTimeoutSeconds}s pushing $OUT_PATHS" >&2
      else
        echo "cachix-push-hook: cachix push failed with exit $rc (ignoring; build artifact is local)" >&2
      fi
    fi

    # Always succeed: the push is opportunistic.
    exit 0
  '';
in
{
  age.secrets.cachix-auth-token.file = ../../secrets/cachix-auth-token.age;

  nix.settings.post-build-hook = "${pushHook}";
}
