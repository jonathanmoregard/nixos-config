# vm-listen-tools: substack-url-tool + prose-decorate + tts-tool reach
# the system PATH, respond to --help, and the wrappers wire each tool to
# its agenix-decrypted API key. Fish and Anthropic use `<KEY>_FILE`
# indirection (Python CLIs reading the file at request time); Auphonic
# CLI only honours bare `AUPHONIC_API_KEY`, so the tts-tool wrapper
# reads the secret into env directly. The tts-tool wrapper also pins
# `auphonic-cli` on PATH so `tts-tool clone --enhance` can shell out.
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
    # Auphonic key is read into AUPHONIC_API_KEY (no _FILE indirection
    # — the auphonic CLI only honours the bare env var). Same `if -r`
    # guard so the binary still launches when the secret is missing
    # (and tts-tool's `--enhance` falls back to raw bytes).
    assert_wrapper_references(
        "tts-tool", "AUPHONIC_API_KEY", "auphonic-api-key"
    )
    assert_wrapper_references(
        "prose-decorate", "ANTHROPIC_API_KEY_FILE", "anthropic-api-key"
    )

    # auphonic-cli must be reachable from the tts-tool wrapper's PATH so
    # `tts-tool clone --enhance` can shell out to it. writeShellApplication
    # bakes `export PATH=<runtimeInputs-store-paths>:$PATH` into the wrapper
    # text. Match against the versioned store-path pattern so a comment or
    # secret-name containing "auphonic" alone wouldn't false-pass — the
    # actual binary derivation lives at /nix/store/<hash>-auphonic-cli-<ver>.
    import re
    tts_wrapper_src = dellan.succeed(
        "readlink -f $(command -v tts-tool)"
    ).strip()
    tts_wrapper_text = dellan.succeed(f"cat {tts_wrapper_src}")
    assert re.search(
        r"/nix/store/[a-z0-9]+-auphonic-cli-[0-9][0-9.]*", tts_wrapper_text
    ), (
        "tts-tool wrapper PATH does not include an auphonic-cli store path:\n"
        + tts_wrapper_text
    )
  '';
}
