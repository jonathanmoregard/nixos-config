# vm-listen-tools: substack-url-tool + prose-decorate + tts-tool start
# and answer --help on the deployed system (argparse + module imports run
# before any provider call).
#
# Run: nix build .#checks.x86_64-linux.vm-listen-tools -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-listen-tools";
  testScript = ''
    tuxedo.wait_for_unit("multi-user.target")

    # --help exits cleanly for all three. For tts-tool/prose-decorate
    # this is a thin but real signal — argparse + module imports run
    # before any provider call.
    tuxedo.succeed("substack-url-tool --help")
    tuxedo.succeed("prose-decorate --help")
    tuxedo.succeed("tts-tool --help")
  '';
}
