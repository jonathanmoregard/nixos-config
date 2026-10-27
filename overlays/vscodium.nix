# Bump VSCodium past what the locked nixpkgs ships.
#
# nixpkgs pins 1.126.04524 — VSCodium's 2026-07-07 build — while upstream is
# at 1.143.17183. The gap is not cosmetic: extension manifests gate on the
# editor version, and an extension whose `engines.vscode` is unsatisfied
# never activates. GitHub.vscode-pull-request-github 0.158.0 (the PR review
# surface: inline diff, PR description, review comments) declares
# `engines.vscode ^1.129.0`, so on 1.126 it installs and does nothing.
#
# Only `version` and `src` can change here: `vscodeVersion` is an argument of
# pkgs/applications/editors/vscode/generic.nix, consumed before mkDerivation
# runs, so overrideAttrs cannot reach the real one. It is corrected in
# passthru for anything that reads it back. That is safe for this bump
# because on linux-x64 nothing branches differently between the two
# versions: the `>= 1.129.0` node_modules branch is darwin-only, and the
# ripgrep path branch is the `>= 1.122.0` arm for 1.126 and 1.143 alike. If a
# future tarball moves that path, the build fails loudly on the `rm` of the
# bundled rg rather than producing a broken editor.
#
# Bump: change `version` (and the passthru `vscodeVersion` to the VS Code
# release it tracks), then
#   nix store prefetch-file https://github.com/VSCodium/vscodium/releases/download/<v>/VSCodium-linux-x64-<v>.tar.gz
# and paste the reported hash. Drop this overlay once nixpkgs catches up.
#
# linux-x64 is hardcoded because this flake builds no darwin system.
final: prev: {
  vscodium = prev.vscodium.overrideAttrs (old: rec {
    version = "1.143.17183";
    src = prev.fetchurl {
      url = "https://github.com/VSCodium/vscodium/releases/download/${version}/VSCodium-linux-x64-${version}.tar.gz";
      hash = "sha256-sRPHzFViTwd5/hlBabtsBJeFv6rCAzyEuKTaaERdcq8="; # pragma: allowlist secret
    };
    passthru = old.passthru // { vscodeVersion = "1.143.1"; };
  });
}
