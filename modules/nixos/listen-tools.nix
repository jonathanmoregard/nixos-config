# listen-tools: CLI pipeline that turns Substack articles into MP3s.
#
#   substack-url-tool --format markdown $URL \
#     | prose-decorate \
#     | tts-tool -o out.mp3
#
# All three binaries live in standalone flakes (github:jonathanmoregard/<name>)
# and are exposed on the system via the inline overlay in `flake.nix`.
# `tts-tool` and `prose-decorate` are wrapped here with writeShellApplication
# wrappers that inject `<KEY>_FILE = agenix decrypt path` at runtime — the
# Python CLIs prefer `_FILE` over the bare env var so the raw key never
# transits any process argv/env outside the wrapper.
#
# Why agenix `owner = "jonathan"` (Fish key only — Anthropic key already
# declared in hosts/dellan/default.nix with the same shape): the binaries
# are user-launched at the shell, NOT systemd units. No `LoadCredential`
# path; instead, agenix decrypts to `/run/agenix/<name>` owned by jonathan
# so the user shell can `cat` it via the wrapper without sudo.
{ config, pkgs, lib, ... }:
{
  age.secrets.fish-audio-api-key = {
    rekeyFile = ../../secrets/fish-audio-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  # Auphonic API key. Used by `tts-tool clone --enhance auphonic` to send
  # raw mic samples through Auphonic's breath/mouth-noise removal before
  # the bytes hit Fish's `voices.create`. Same owner/mode shape as
  # fish-audio-api-key — user-launched binary, decrypted to /run/agenix.
  age.secrets.auphonic-api-key = {
    rekeyFile = ../../secrets/auphonic-api-key.age;
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
    (pkgs.writeShellApplication {
      name = "prose-decorate";
      runtimeInputs = [ pkgs.prose-decorate ];
      text = ''
        if [ -r "${config.age.secrets.anthropic-api-key.path}" ]; then
          export ANTHROPIC_API_KEY_FILE="${config.age.secrets.anthropic-api-key.path}"
        fi
        exec prose-decorate "$@"
      '';
    })
    pkgs.substack-url-tool
  ];
}
