# vm-listen-tools: substack-url-tool + tts-tool reach the system PATH,
# respond to --help, and the tts-tool wrapper points
# FISH_AUDIO_API_KEY_FILE at the agenix decrypt path.
#
# Run: nix build .#checks.x86_64-linux.vm-listen-tools -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-listen-tools";
  testScript = ''
    dellan.wait_for_unit("multi-user.target")

    # Both binaries on system PATH (so user-shell `tts-tool` and
    # `substack-url-tool` resolve without any sourcing dance).
    dellan.succeed("command -v substack-url-tool")
    dellan.succeed("command -v tts-tool")

    # --help exits cleanly for both. tts-tool depends on argparse +
    # spaCy import; if the en_core_web_sm wheel didn't land in the
    # uv-built venv, the entrypoint can still parse args because the
    # model is lazy-loaded — so --help is a thin but real signal.
    dellan.succeed("substack-url-tool --help")
    dellan.succeed("tts-tool --help")

    # Source-level verification of the wrapper: it must reference the
    # agenix path so the user-shell binary picks up FISH_AUDIO_API_KEY_FILE
    # at runtime once the secret is decrypted. We don't `test -r` the
    # decrypted file here: agenix needs the host SSH key matching one of
    # the recipients in secrets/secrets.nix to decrypt, and the
    # nixosTest VM is intentionally identity-less (matches existing lanes
    # vm-base / vm-desktop / etc., which all import hosts/dellan/default.nix
    # with its many `age.secrets.*` declarations and likewise see
    # "[agenix] WARNING: no readable identities found!" during activation).
    # The wrapper's `if [ -r ... ]` guard makes it non-fatal.
    wrapper_src = dellan.succeed("readlink -f $(command -v tts-tool)")
    wrapper_text = dellan.succeed(f"cat {wrapper_src.strip()}")
    assert "FISH_AUDIO_API_KEY_FILE=" in wrapper_text, (
        f"tts-tool wrapper does not set FISH_AUDIO_API_KEY_FILE:\n{wrapper_text}"
    )
    assert "/run/agenix/fish-audio-api-key" in wrapper_text, (
        f"tts-tool wrapper does not reference the agenix path:\n{wrapper_text}"
    )
  '';
}
