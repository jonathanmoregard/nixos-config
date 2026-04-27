# Bump beeper to a newer upstream release than nixpkgs ships.
# Beeper's server enforces a minimum client version; the nixpkgs-pinned build
# was lagging by 6+ weeks and refused to start with "outdated" at first launch.
# Update the `version` + `hash` here when the next bump is needed:
#   nix-prefetch-url https://beeper-desktop.download.beeper.com/builds/Beeper-<NEW>-x86_64.AppImage
#   nix hash convert --hash-algo sha256 --to sri <output>
final: prev:
let
  pname = "beeper";
  version = "4.2.742";
  src = prev.fetchurl {
    url = "https://beeper-desktop.download.beeper.com/builds/Beeper-${version}-x86_64.AppImage";
    hash = "sha256-4UZ9buKCZZFSg9x2in1DmGL+OiClHCj7V+2OB4Msu9U="; # pragma: allowlist secret
  };
  appimageContents = prev.appimageTools.extract {
    inherit pname version src;
    postExtract = ''
      linuxConfigFilename=$out/resources/app/build/main/linux-*.mjs
      echo "export function registerLinuxConfig() {}" > $linuxConfigFilename
      sed -i 's/auto_update_disabled:[^,}]*/auto_update_disabled:true/g' $out/resources/app/build/main/main-entry-*.mjs
      sed -i -E 's/executeDownload\([^)]+\)\{/executeDownload(){return;/g' $out/resources/app/build/main/main-entry-*.mjs
      sed -i '$ a\.subview-prefs-about > div:nth-child(2) {display: none;}' $out/resources/app/build/renderer/PrefsPanes-*.css
    '';
  };
in
{
  beeper = prev.appimageTools.wrapAppImage {
    inherit pname version;
    src = appimageContents;
    extraPkgs = pkgs: [ pkgs.libsecret ];
    extraInstallCommands = ''
      install -Dm 644 ${appimageContents}/beepertexts.png $out/share/icons/hicolor/512x512/apps/beepertexts.png
      install -Dm 644 ${appimageContents}/beepertexts.desktop -t $out/share/applications/
      substituteInPlace $out/share/applications/beepertexts.desktop --replace-fail "AppRun" "beeper"
      . ${prev.makeWrapper}/nix-support/setup-hook
      wrapProgram $out/bin/beeper \
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}} --no-update" \
        --set APPIMAGE beeper \
        --run 'exec >/dev/null'
    '';
    meta = prev.beeper.meta;
  };
}
