{ config, pkgs, lib, ... }:
# Calibre third-party plugins, installed declaratively.
#
# Calibre stores installed plugins in ~/.config/calibre/plugins/ (mutable
# user state — not Nix-managed). For each plugin we pin a Nix-store zip,
# then call `calibre-customize -a <zip>` from a Home-Manager activation
# hook. Each plugin has its own marker file holding the source store
# path; any rebuild that produces a new store path (plugin version bump
# OR transitive dependency upgrade) triggers a re-install of just that
# plugin.
let
  # -------------------------------------------------------------------
  # DeACSM — Adobe ACSM -> EPUB/PDF conversion.
  #
  # Upstream: https://github.com/Leseratte10/acsm-calibre-plugin
  #
  # Doesn't work out-of-the-box on NixOS: the plugin bundles oscrypto,
  # which uses `ctypes.util.find_library('crypto')` to discover
  # libcrypto. `find_library` on Linux relies on ldconfig + gcc, neither
  # of which finds Nix-store openssl (no global ldconfig cache for it).
  # Calibre import / runtime then dies with
  # `oscrypto.errors.LibraryNotFoundError: The library libcrypto could
  # not be found`.
  #
  # Fix: patch the plugin's __init__.py to call
  # `oscrypto.use_openssl(<abs libcrypto>, <abs libssl>)` right after the
  # asn1crypto sys.path insert and before the libadobe imports that pull
  # oscrypto submodules. `use_openssl()` pins backend config so the
  # ctypes loader skips its broken auto-discovery path.
  # -------------------------------------------------------------------
  deacsmVersion = "v0.0.16";

  deacsmUpstream = pkgs.fetchurl {
    url = "https://github.com/Leseratte10/acsm-calibre-plugin/releases/download/${deacsmVersion}/DeACSM_0.0.16.zip";
    sha256 = "0l0bhx8kdvmvfn9z0fpkl488kgf1rcv3vchzgjjwwnwzgfi1pxmm";
  };

  deacsmPatched = pkgs.runCommand "DeACSM-${deacsmVersion}-nixos.zip" {
    nativeBuildInputs = [ pkgs.unzip pkgs.zip pkgs.python3 ];
    libcrypto = "${pkgs.openssl.out}/lib/libcrypto.so.3";
    libssl    = "${pkgs.openssl.out}/lib/libssl.so.3";
  } ''
    cp ${deacsmUpstream} input.zip
    mkdir unpacked && cd unpacked
    unzip -q ../input.zip

    python3 <<'PYEOF'
    import os
    p = "__init__.py"
    src = open(p).read()
    needle = 'sys.path.insert(0, os.path.join(self.moddir, "asn1crypto"))'
    inject = (
        needle + "\n"
        + " " * 12 + "# NIX_PATCH: oscrypto's ctypes loader can't find libcrypto on NixOS;\n"
        + " " * 12 + "# pin absolute libcrypto/libssl paths before the libadobe imports\n"
        + " " * 12 + "# below pull in oscrypto submodules.\n"
        + " " * 12 + "import oscrypto as _osc\n"
        + " " * 12 + f'_osc.use_openssl({os.environ["libcrypto"]!r}, {os.environ["libssl"]!r})'
    )
    new = src.replace(needle, inject, 1)
    assert new != src, "NIX_PATCH anchor not found in DeACSM __init__.py"
    open(p, "w").write(new)
    PYEOF

    zip -qr $out *
  '';

  # -------------------------------------------------------------------
  # DeDRM — DRM removal for Adobe ADEPT (EPUB/PDF), Kindle, Nook, etc.
  #
  # Upstream: https://github.com/noDRM/DeDRM_tools (release bundle
  # contains DeDRM_plugin.zip + Obok_plugin.zip; we install only the
  # main DeDRM_plugin — Kobo support via Obok would be a separate
  # opt-in).
  #
  # Crypto deps are pure-Python via PyCryptodome (`from Cryptodome…`),
  # which calibre bundles. No libcrypto patching needed; the
  # Windows-only CDLL paths in adobekey.py / kindlekey.py are gated
  # behind `windll` (which doesn't exist on Linux ctypes).
  # -------------------------------------------------------------------
  dedrmVersion = "v10.0.9";

  dedrmBundle = pkgs.fetchurl {
    url = "https://github.com/noDRM/DeDRM_tools/releases/download/${dedrmVersion}/DeDRM_tools_10.0.9.zip";
    sha256 = "1nmb38jrrgai7zahbmx9sly850qqvbk3krmpp4g8gp269bwpyvnl";
  };

  dedrmInner = pkgs.runCommand "DeDRM_plugin-${dedrmVersion}.zip" {
    nativeBuildInputs = [ pkgs.unzip ];
  } ''
    unzip -p ${dedrmBundle} DeDRM_plugin.zip > $out
  '';

  # -------------------------------------------------------------------
  # KFX Input — read/convert Amazon KFX (the format Kindle for PC and
  # newer Kindles store books in).
  #
  # Upstream "official" plugin is jhowell's, hosted on MobileRead
  # (login-walled attachments). kluyg/calibre-kfx-input is a GitHub
  # mirror of the same source. Pinned by commit SHA (the mirror has no
  # tags/releases). Plain-Python plugin, no native crypto deps.
  # -------------------------------------------------------------------
  kfxInputRev = "44db6b6ee8c0094a98c33770575a9070ddb90fda"; # 2025-07-29

  kfxInputSrc = pkgs.fetchFromGitHub {
    owner = "kluyg";
    repo  = "calibre-kfx-input";
    rev   = kfxInputRev;
    hash  = "sha256-wO+dsF23c6p8jPpHKWHrSnFNpo92lHxLGNX+NYYZnHE=";
  };

  kfxInputZip = pkgs.runCommand "KFXInput-${builtins.substring 0 7 kfxInputRev}.zip" {
    nativeBuildInputs = [ pkgs.zip ];
  } ''
    cd ${kfxInputSrc}
    zip -qr $out . -x '.gitignore' -x '*/.git/*'
  '';

  # Plugin name -> zip in nix store. Activation iterates, marker-compares
  # per plugin, installs only when the source store path changed.
  plugins = {
    DeACSM   = deacsmPatched;
    DeDRM    = dedrmInner;
    KFXInput = kfxInputZip;
  };
in
{
  # Activation: re-install a plugin whenever its source store path
  # changes (plugin bump OR transitive dep bump). Adobe ACSM
  # authorization (DeACSM) and DRM key import (DeDRM) are still
  # one-time GUI steps inside calibre — the plugin install itself
  # is fully declarative.
  home.activation.installCalibrePlugins = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p "$HOME/.config/calibre/plugins"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: src: ''
      marker="$HOME/.config/calibre/plugins/.${name}-source"
      want=${src}
      if [ "$(cat "$marker" 2>/dev/null)" != "$want" ]; then
        if ${pkgs.calibre}/bin/calibre-customize -a "$want"; then
          printf '%s' "$want" > "$marker"
        fi
      fi
    '') plugins)}
  '';
}
