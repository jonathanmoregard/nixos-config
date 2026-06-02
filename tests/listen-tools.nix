# vm-listen-tools: substack-url-tool + prose-decorate + tts-tool reach
# the system PATH, respond to --help, and the tts-tool / prose-decorate
# wrappers point their respective `<KEY>_FILE` env vars at the agenix
# decrypt path.
#
# Run: nix build .#checks.x86_64-linux.vm-listen-tools -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-listen-tools";
  testScript = ''
    dellan.wait_for_unit("multi-user.target")

    # All three binaries on system PATH (so user-shell `tts-tool`,
    # `prose-decorate`, `substack-url-tool` resolve without any
    # sourcing dance).
    dellan.succeed("command -v substack-url-tool")
    dellan.succeed("command -v prose-decorate")
    dellan.succeed("command -v tts-tool")

    # --help exits cleanly for all three. For tts-tool/prose-decorate
    # this is a thin but real signal — argparse + module imports run
    # before any provider call.
    dellan.succeed("substack-url-tool --help")
    dellan.succeed("prose-decorate --help")
    dellan.succeed("tts-tool --help")

    # Source-level verification of each wrapper: it must reference the
    # agenix path so the user-shell binary picks up <KEY>_FILE at
    # runtime once the secret is decrypted. We don't `test -r` the
    # decrypted file here: agenix needs the host SSH key matching one
    # of the recipients in secrets/secrets.nix to decrypt, and the
    # nixosTest VM is intentionally identity-less (matches existing
    # lanes vm-base / vm-desktop / etc., which all import
    # hosts/dellan/default.nix with its many `age.secrets.*`
    # declarations and likewise see "[agenix] WARNING: no readable
    # identities found!" during activation). The wrappers' `if [ -r
    # ... ]` guards make this non-fatal.
    def assert_wrapper_references(cli_name, env_var, secret_name):
        wrapper_src = dellan.succeed(
            f"readlink -f $(command -v {cli_name})"
        ).strip()
        wrapper_text = dellan.succeed(f"cat {wrapper_src}")
        assert env_var + "=" in wrapper_text, (
            f"{cli_name} wrapper does not set {env_var}:\n{wrapper_text}"
        )
        expected_path = f"/run/agenix/{secret_name}"
        assert expected_path in wrapper_text, (
            f"{cli_name} wrapper does not reference {expected_path}:\n{wrapper_text}"
        )

    assert_wrapper_references(
        "tts-tool", "FISH_AUDIO_API_KEY_FILE", "fish-audio-api-key"
    )
    assert_wrapper_references(
        "prose-decorate", "ANTHROPIC_API_KEY_FILE", "anthropic-api-key"
    )
    # prose-decorate also handles the multimodal --audio path against
    # Gemini 2.5 Pro; the wrapper must EXPORT GEMINI_API_KEY (not just
    # assign it locally) from the agenix-decrypted path so the Python
    # CLI's read_gemini_api_key picks it up via env. Same wrapper,
    # second secret reference. The bare assert_wrapper_references
    # matches the substring `GEMINI_API_KEY=`, so we additionally
    # anchor on the literal `export GEMINI_API_KEY` to reject a
    # half-finished refactor that loses the export.
    assert_wrapper_references(
        "prose-decorate", "GEMINI_API_KEY", "gemini-api-key"
    )
    prose_wrapper_src = dellan.succeed(
        "readlink -f $(command -v prose-decorate)"
    ).strip()
    prose_wrapper_text = dellan.succeed(f"cat {prose_wrapper_src}")
    assert "export GEMINI_API_KEY" in prose_wrapper_text, (
        "prose-decorate wrapper assigns GEMINI_API_KEY but never exports it:\n"
        + prose_wrapper_text
    )
  '';
}
