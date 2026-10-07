# Bump codex past what the locked nixpkgs ships.
#
# Security floor: Codex CLI >= 0.149.0. Before it, `apply_patch` widened
# its write grant to the PARENT directory of any path it was handed, so a
# patch naming /tmp could write anywhere on disk, e.g. ~/.zshrc through a
# symlink ("Overpatch", reported 2026-08-12, fixed in CLI 0.149.0). The
# locked nixpkgs ships 0.146.0.
#
# Only version, src, cargoDeps and the prebuilt V8 artifacts change; the
# nixpkgs build recipe, the ripgrep/bubblewrap wrapper and its
# versionCheckHook are kept. The version check guards against editing
# `version` without `src`: the built binary must print the version
# declared here.
#
# Bump: change `version`, set the four hashes to lib.fakeHash, build
# `.#nixosConfigurations.dellan.pkgs.codex`, paste each reported hash.
# The rusty_v8 version must match `v8 = "=<x>"` in codex-rs/Cargo.toml
# of the new tag. Drop this overlay once nixpkgs ships >= 0.149.0.
final: prev:
let
  version = "0.160.1";
  # rusty_v8 prebuilt artifacts. Since 0.147 codex builds v8 with
  # `v8_enable_sandbox` (code-mode-runtime), which selects the
  # pointer-compression + sandbox variant of BOTH the static library and
  # the generated Rust binding. build.rs would download them; the Nix
  # sandbox has no network, so they are fetched here and handed over via
  # RUSTY_V8_ARCHIVE / RUSTY_V8_SRC_BINDING_PATH.
  v8Version = "150.4.0";
  v8Variant = "ptrcomp_sandbox_release_${prev.stdenv.hostPlatform.rust.rustcTarget}";
  # Codex-built pair (openai/codex release rusty-v8-v<x>); denoland does
  # not publish the sandbox variant.
  v8Base = "https://github.com/openai/codex/releases/download/rusty-v8-v${v8Version}";
  librustyV8 = prev.fetchurl {
    name = "librusty_v8-${v8Version}";
    url = "${v8Base}/librusty_v8_${v8Variant}.a.gz";
    # Matches upstream's rusty_v8_<variant>.sha256 release manifest.
    hash = "sha256-o1x10fJuapg4haRbM0kKTr5U8FBQVosyuJz7QhswtYM="; # pragma: allowlist secret
  };
  v8Binding = prev.fetchurl {
    name = "rusty_v8-src-binding-${v8Version}.rs";
    url = "${v8Base}/src_binding_${v8Variant}.rs";
    hash = "sha256-dyeCauR5vbZF6Acjn7EtH44uI956bPFvXuWSaQ0dhQY="; # pragma: allowlist secret
  };
in
{
  codex = (prev.codex.override { librusty_v8 = librustyV8; }).overrideAttrs (finalAttrs: old: {
    inherit version;
    src = prev.fetchFromGitHub {
      owner = "openai";
      repo = "codex";
      tag = "rust-v${version}";
      hash = "sha256-9oXMysQ+v4txGIhPsgh45xAAqWYglZjhdS50uxMPHz4="; # pragma: allowlist secret
    };
    cargoDeps = final.rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src sourceRoot;
      name = "codex-${version}";
      hash = "sha256-DMRbIOynO0wGXjBxaXZJNKorD9YQv3fAoRTZ4iZEIE4="; # pragma: allowlist secret
    };
    env = old.env // { RUSTY_V8_SRC_BINDING_PATH = v8Binding; };
    # Disk: cargoInstallPostBuildHook copies the WHOLE release dir to
    # release-tmp, then installs only its top-level binaries. codex's
    # release dir is tens of GB (deps, build scripts, thin-LTO + line
    # tables), so the copy doubles it and ran the CI runner's 60G /nix
    # loop out of space (run 37184584292). The implicit postBuild runs
    # before postBuildHooks, so prune everything below the top level
    # first; the top-level binaries are hardlinks and survive.
    postBuild = (old.postBuild or "") + ''
      releaseDir=target/${prev.stdenv.hostPlatform.rust.rustcTarget}/$cargoBuildType
      rm -rf "$releaseDir"/{deps,build,incremental,.fingerprint,examples}
    '';
  });
}
