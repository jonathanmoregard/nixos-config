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
# Failure modes:
#   - Hook exit code does NOT affect the build's overall success
#     (Nix daemon swallows it).
#   - Hook is synchronous: a slow cachix upload slows the next build.
#     Acceptable for a daily-driver where dev builds are infrequent;
#     swap to `cachix daemon` async queue if it becomes a problem.
#   - Secret not yet decrypted at early-boot rebuilds: hook exits 0
#     silently so the build still completes.
{ config, pkgs, ... }:

let
  cacheName = "jonathanmoregard";

  # Nix daemon invokes this after every successful local build.
  # OUT_PATHS is space-separated store paths; cachix push accepts
  # multiple paths in one invocation.
  pushHook = pkgs.writeShellScript "cachix-push-hook" ''
    set -euf
    export IFS=' '
    if [ -z "''${OUT_PATHS:-}" ]; then
      exit 0
    fi
    tokenFile="${config.age.secrets.cachix-auth-token.path}"
    if [ ! -r "$tokenFile" ]; then
      # Secret not yet activated (early boot, or recipient mismatch).
      # Skip silently so the build still completes.
      exit 0
    fi
    CACHIX_AUTH_TOKEN="$(< "$tokenFile")" \
      ${pkgs.cachix}/bin/cachix push ${cacheName} $OUT_PATHS
  '';
in
{
  age.secrets.cachix-auth-token.file = ../../secrets/cachix-auth-token.age;

  nix.settings.post-build-hook = "${pushHook}";
}
