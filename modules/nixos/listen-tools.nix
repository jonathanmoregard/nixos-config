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

  # Gemini API key. Will be consumed by an upcoming `prose-decorate
  # --audio` path that uses Gemini 2.5 Pro as a multimodal LLM to
  # annotate transcripts with Fish s2-pro prosody tags by listening to
  # the actual podcast / interview audio. Wrapper plumbing (export
  # GEMINI_API_KEY in the prose-decorate wrapper) ships in the follow-up
  # PR that wires the new code path; this PR only declares the secret
  # so the rekey loop can run independently.
  age.secrets.gemini-api-key = {
    rekeyFile = ../../secrets/gemini-api-key.age;
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
        # Gemini API key for the `--audio` multimodal path
        # (`prose-decorate --audio FILE -i transcript.txt`). The Python
        # tool reads GEMINI_API_KEY from env; we export it from the
        # agenix decrypt path so the raw key never transits any process
        # argv. Guarded by `[ -r ... ]` so the wrapper still launches
        # on hosts where the secret hasn't been rekeyed yet — the
        # text-only `prose-decorate` path keeps working in that case.
        if [ -r "${config.age.secrets.gemini-api-key.path}" ]; then
          GEMINI_API_KEY="$(< "${config.age.secrets.gemini-api-key.path}")"
          export GEMINI_API_KEY
        fi
        exec prose-decorate "$@"
      '';
    })
    pkgs.substack-url-tool
  ];
}
