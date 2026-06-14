# Bump beeper to a newer upstream release than nixpkgs ships.
# Beeper's server enforces a minimum client version; the nixpkgs-pinned build
# was lagging by 6+ weeks and refused to start with "outdated" at first launch.
#
# Updates are automated:
#   * Daily GitHub Actions workflow (.github/workflows/update-beeper.yml) runs
#     `nix run .#update-beeper`, which rewrites `version` + `hash` below and
#     opens a PR. The risk classifier should land it on `risk:trivial` so it
#     auto-merges, the webhook redeploys, and dellan gets the new client
#     without manual intervention.
#   * Manual bump (rarely needed): `nix run .#update-beeper` from the repo
#     root, then commit the diff to a branch and open a PR.
final: prev:
let
  pname = "beeper";
  version = "4.2.923";
  src = prev.fetchurl {
    url = "https://beeper-desktop.download.beeper.com/builds/Beeper-${version}-x86_64.AppImage";
    hash = "sha256-zx6V+UQSdY3GBLarJ/4znyfPSS84OpvTFbkVhHFiv/U="; # pragma: allowlist secret
  };
  appimageContents = prev.appimageTools.extract {
    inherit pname version src;
    postExtract = ''
      linuxConfigFilename=$out/resources/app/build/main/linux-*.mjs
      echo "export function registerLinuxConfig() {}" > $linuxConfigFilename
      sed -i 's/auto_update_disabled:[^,}]*/auto_update_disabled:true/g' $out/resources/app/build/main/main-entry-*.mjs
      sed -i -E 's/executeDownload\([^)]+\)\{/executeDownload(){return;/g' $out/resources/app/build/main/main-entry-*.mjs
      # NOTE: nixpkgs 4.2.630 patched PrefsPanes-*.css to hide the "outdated"
      # warning on the about page. Beeper 4.2.742 ships PrefsPanes as .js
      # (no matching .css), and on a current build the warning shouldn't
      # appear at all. If a future bump needs to hide a UI warning again,
      # target the renderer CSS bundle that contains `.subview-prefs-about`.
    '';
  };
in
{
  # In-place version/hash bumper for overlays/beeper.nix. Resolves the latest
  # Beeper build by following the redirect from api.beeper.com's "stable"
  # endpoint (same source nixpkgs uses), then rewrites the let-bindings above
  # with sed. Invoked via `nix run .#update-beeper`. Self-contained: no
  # dependency on the `beeper` derivation evaluating, which matters when
  # we're racing ahead of a broken upstream release.
  #
  # writeShellScriptBin (not writeShellApplication) so curl/coreutils/grep/
  # sed/nix come from caller PATH instead of the closure. GitHub runners and
  # NixOS dev shells already have them; including them in runtimeInputs
  # triggers from-source coreutils rebuilds whenever the nixpkgs revision
  # drifts ahead of the binary cache, which would make the auto-update
  # workflow itself flaky.
  beeper-update = prev.writeShellScriptBin "update-beeper" ''
    set -euo pipefail
    file="''${BEEPER_NIX_FILE:-overlays/beeper.nix}"
    if [[ ! -f "$file" ]]; then
      echo "update-beeper: $file not found (run from repo root)" >&2
      exit 1
    fi

    redirect="$(curl --silent --output /dev/null --write-out '%{redirect_url}' \
      https://api.beeper.com/desktop/download/linux/x64/stable/com.automattic.beeper.desktop)"
    new_version="$(echo "$redirect" | grep --only-matching --extended-regexp '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -z "$new_version" ]]; then
      echo "update-beeper: could not parse version from redirect '$redirect'" >&2
      exit 1
    fi

    cur_version="$(grep --only-matching --perl-regexp '(?<=version = ")[0-9.]+' "$file" | head -1)"
    if [[ "$new_version" = "$cur_version" ]]; then
      echo "update-beeper: already at $cur_version"
      exit 0
    fi

    new_url="https://beeper-desktop.download.beeper.com/builds/Beeper-''${new_version}-x86_64.AppImage"
    raw="$(nix-prefetch-url --type sha256 "$new_url")"
    sri="$(nix hash convert --hash-algo sha256 --to sri "$raw")"

    sed -i "s|version = \"$cur_version\"|version = \"$new_version\"|" "$file"
    sed -i -E "s|hash = \"sha256-[A-Za-z0-9+/=]+\"|hash = \"$sri\"|" "$file"

    echo "update-beeper: bumped $cur_version -> $new_version ($sri)"
  '';

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
    passthru = {
      updateScript = "${final.beeper-update}/bin/update-beeper";
      inherit src;
    };
    meta = prev.beeper.meta;
  };
}
