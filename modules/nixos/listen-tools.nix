# listen-tools: CLI pipeline that turns Substack articles into MP3s.
#
#   substack-url-tool $URL | tts-tool -o out.mp3
#
# Both binaries live in standalone flakes (github:jonathanmoregard/<name>)
# and are exposed on the system via the inline overlay in `flake.nix`.
# This module wraps `tts-tool` with a writeShellApplication that injects
# FISH_AUDIO_API_KEY_FILE = the agenix decrypt path at runtime — the
# Python CLI prefers _FILE over the bare env var so the key never
# transits any process argv/env outside the wrapper.
#
# Why agenix `owner = "jonathan"`: the binaries are user-launched at the
# shell, NOT a systemd unit. No `LoadCredential` path; instead, agenix
# decrypts to `/run/agenix/fish-audio-api-key` owned by jonathan so the
# user shell can `cat` it via the wrapper without sudo.
{ config, pkgs, lib, ... }:
{
  age.secrets.fish-audio-api-key = {
    file = ../../secrets/fish-audio-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "tts-tool";
      runtimeInputs = [ pkgs.tts-tool ];
      text = ''
        if [ -r "${config.age.secrets.fish-audio-api-key.path}" ]; then
          export FISH_AUDIO_API_KEY_FILE="${config.age.secrets.fish-audio-api-key.path}"
        fi
        exec tts-tool "$@"
      '';
    })
    pkgs.substack-url-tool
  ];
}
