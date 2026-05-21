# vm-autodoro: launcher + pre-push reload hook.
#
# File-level assertions only. Probing autodoro.service via
# `systemctl --user` runs into the same user@1000.service / PAM
# session timing issue noted in the earlier monolithic test, so we
# stick to file existence + content greps which are deterministic
# and run before any session is required.
#
# What we check:
#   - autodoro.service unit file rendered by HM
#   - pre-push hook present, executable, in the global hooks dir
#     (matching core.hooksPath set in home/jonathan.nix)
#   - hook guards by repo toplevel (no-op for non-autodoro pushes)
#   - hook fires the right systemctl restart on autodoro pushes
#   - hook exits 0 unconditionally so a systemd transient error
#     doesn't block the push itself
#
# Run: nix build .#checks.x86_64-linux.vm-autodoro -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-autodoro";
  testScript = ''
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")

    dellan.succeed("test -f /home/jonathan/.config/systemd/user/autodoro.service")

    hook = "/home/jonathan/.config/git/hooks/pre-push"
    dellan.succeed(f"test -x {hook}")
    # Repo-toplevel guard so the hook is a no-op for every other repo.
    dellan.succeed(f"grep -q 'Repos/autodoro' {hook}")
    # Restart command present.
    dellan.succeed(
        f"grep -q 'systemctl --user restart autodoro.service' {hook}"
    )
    # Unconditional exit 0 so a systemd error never blocks the push.
    dellan.succeed(f"grep -q '^exit 0$' {hook}")
  '';
}
