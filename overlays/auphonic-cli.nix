# auphonic-cli: official Auphonic command-line client.
#
# Used by tts-tool's `--enhance` flag to send recorded voice samples
# through Auphonic's breath / mouth-noise removal before they hit Fish
# Audio's voices.create. Auphonic has a dedicated --debreath-amount
# flag and was chosen over Adobe Podcast Enhance v2 for this preprocess
# step because Adobe's general denoise underperforms on breaths per
# practitioner reviews.
#
# Why fetchurl + a single binary instead of buildGoModule: upstream
# ships v1.1.3 as a pre-built static Go binary with no public source
# tarball (the install script downloads exactly this tarball). Pin
# version + SRI hash; bump on release. No automation today — the
# enhance pipeline tolerates a missing binary by falling back to raw.
#
# Pinned to linux/amd64 because dellan is x86_64 and the upstream
# release artifacts don't include arm64-linux yet for the version this
# project pins. Meta.platforms reflects the actual artifact, not Auphonic
# CLI's general support matrix.
final: prev:
let
  pname = "auphonic-cli";
  version = "1.1.3";
in
{
  auphonic-cli = prev.stdenvNoCC.mkDerivation {
    inherit pname version;

    src = prev.fetchurl {
      url = "https://auphonic.com/media/cli/auphonic-cli_${version}_linux_amd64.tar.gz";
      hash = "sha256-wxS4zTgBtfrFfGjFybi2ee98f3RF9pSKTcFOTA8WhsE="; # pragma: allowlist secret
    };

    sourceRoot = ".";

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 auphonic $out/bin/auphonic
      runHook postInstall
    '';

    meta = with prev.lib; {
      description = "Auphonic CLI for audio post-processing (denoise, debreath, leveling)";
      homepage = "https://auphonic.com/cli";
      license = licenses.unfree;
      platforms = [ "x86_64-linux" ];
      mainProgram = "auphonic";
    };
  };
}
