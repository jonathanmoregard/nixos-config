# vm-keyring: gnome-keyring PAM wiring.
#
# Guarantees `passwd` re-keys the login keyring instead of leaving
# Chrome stuck on the old encryption pw. lightdm substacks login,
# so login is the load-bearing file. `use_authtok` on the password
# line is what propagates the new pw into the keyring at passwd time.
#
# Run: nix build .#checks.x86_64-linux.vm-keyring -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-keyring";
  testScript = ''
    dellan.wait_for_unit("multi-user.target")

    dellan.succeed(
        "grep -q 'password.*pam_gnome_keyring.*use_authtok' /etc/pam.d/login"
    )
    dellan.succeed("grep -q 'auth.*pam_gnome_keyring' /etc/pam.d/login")
    dellan.succeed("grep -q 'session.*pam_gnome_keyring' /etc/pam.d/login")
  '';
}
