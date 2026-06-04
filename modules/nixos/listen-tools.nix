# listen-tools: CLI pipeline that turns Substack articles into MP3s.
#
#   substack-url-tool --format markdown $URL \
#     | prose-decorate \
#     | tts-tool -o out.mp3
#
# All three binaries live in standalone flakes (github:jonathanmoregard/<name>)
# and are exposed on the system via the inline overlay in `flake.nix`.
# `tts-tool` and `prose-decorate` are wrapped here with writeShellApplication
# wrappers that inject the relevant API-key env vars at runtime. The Python
# CLIs prefer `<KEY>_FILE` indirection (Fish, Anthropic) so the raw key
# never transits any process argv/env outside the wrapper. Auphonic's CLI
# does not support `_FILE` indirection, so the tts-tool wrapper reads its
# agenix secret into `AUPHONIC_API_KEY` directly — still scoped to the
# wrapper's process, not the user shell.
#
# Why agenix `owner = "jonathan"` on the Fish + Auphonic keys (Anthropic
# key already declared in hosts/dellan/default.nix with the same shape):
# the binaries are user-launched at the shell, NOT systemd units. No
# `LoadCredential` path; instead, agenix decrypts to `/run/agenix/<name>`
# owned by jonathan so the user shell can `cat` it via the wrapper
# without sudo.
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
      # auphonic-cli on PATH so the clone subcommand's `--enhance` flag
      # (default on) can shell out for breath / mouth-noise removal
      # before uploading samples to Fish. tts-tool falls back to raw
      # bytes if the binary or AUPHONIC_API_KEY is missing, so wiring
      # both as soft prerequisites is safe.
      runtimeInputs = [ pkgs.tts-tool pkgs.auphonic-cli ];
      text = ''
        if [ -r "${config.age.secrets.fish-audio-api-key.path}" ]; then
          export FISH_AUDIO_API_KEY_FILE="${config.age.secrets.fish-audio-api-key.path}"
        fi
        # auphonic CLI reads AUPHONIC_API_KEY from env (no _FILE
        # indirection support). Read the agenix secret here so it lives
        # only in this process's env, not the user's shell.
        if [ -r "${config.age.secrets.auphonic-api-key.path}" ]; then
          AUPHONIC_API_KEY="$(< "${config.age.secrets.auphonic-api-key.path}")"
          export AUPHONIC_API_KEY
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
