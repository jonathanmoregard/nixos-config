{ config, pkgs, lib, ... }:
# Calibre third-party plugins, installed declaratively.
#
# Calibre stores installed plugins in ~/.config/calibre/plugins/ (mutable
# user state — not Nix-managed). We pin each plugin release in the Nix
# store, build a NixOS-patched variant (see DeACSM below), then call
# `calibre-customize -a <zip>` from a Home-Manager activation hook. A
# per-plugin marker file holds the Nix-store path of the source zip;
# any rebuild that produces a new store path (plugin version bump OR
# transitive dependency upgrade) triggers a re-install.
let
  # ---------------------------------------------------------------------
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
  # ---------------------------------------------------------------------
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
in
{
  # Activation: re-install plugin whenever the patched-zip store path
  # changes (plugin bump OR openssl bump). Marker = full store path so
  # any nixpkgs upgrade that produces a new libcrypto path forces a
  # re-install with the new path baked in.
  #
  # Adobe ACSM authorization is still a one-time GUI step inside calibre
  # (Preferences → Plugins → DeACSM → Configure → "Link to an existing
  # ADE account"); the plugin only handles ACSM->EPUB/PDF conversion
  # mechanics, not credential bootstrap.
  home.activation.installDeACSM = lib.hm.dag.entryAfter ["writeBoundary"] ''
    marker="$HOME/.config/calibre/plugins/.deacsm-source"
    want=${deacsmPatched}
    if [ "$(cat "$marker" 2>/dev/null)" != "$want" ]; then
      mkdir -p "$HOME/.config/calibre/plugins"
      if ${pkgs.calibre}/bin/calibre-customize -a "$want"; then
        printf '%s' "$want" > "$marker"
      fi
    fi
  '';
}
