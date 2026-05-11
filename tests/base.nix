# vm-base: boot + HM activation smoke test.
#
# Asserts the absolute minimum every other lane inherits:
#   - multi-user.target reached
#   - home-manager activation completed for jonathan
#   - systemd --user (via linger) reached default.target for jonathan
#   - X server up (autoLogin path; catches LightDM regressions in
#     the lightest lane before they trip the heavier ones)
#
# Run: nix build .#checks.x86_64-linux.vm-base -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-base";
  testScript = ''
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    # systemd --user for jonathan comes up via linger
    dellan.wait_for_unit("default.target", "jonathan")
    # X session must come up too — every lane inherits autoLogin from
    # tests/lib/common.nix, so a LightDM regression should fail here
    # rather than masquerade as a kitty/desktop-lane failure later.
    dellan.wait_for_x()
  '';
}
