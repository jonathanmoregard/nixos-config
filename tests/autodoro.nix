# vm-autodoro: launcher + shared pre-push reload hook.
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
#   - shared hook composed by home/git-hooks.nix carries dispatches
#     for BOTH consumers currently registered:
#       - autodoro-reload (from home/autodoro.nix)
#       - claude-mcp-sync (from home/claude-mcp-sync.nix)
#   - hook guards by repo toplevel (no-op for unrelated pushes)
#   - autodoro dispatch fires the right systemctl restart
#   - claude-mcp-sync dispatch runs the export script
#   - hook exits 0 unconditionally so a per-dispatch error never
#     blocks the push itself
#   - hook body is syntactically valid bash
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

    # Both registered dispatches must appear by name in a comment.
    dellan.succeed(f"grep -q '^# autodoro-reload$' {hook}")
    dellan.succeed(f"grep -q '^# claude-mcp-sync$' {hook}")

    # Repo-toplevel guards for each consumer.
    dellan.succeed(f'grep -q "Repos/autodoro" {hook}')
    dellan.succeed(f'grep -q "\\.claude" {hook}')

    # autodoro restart body present.
    dellan.succeed(
        f"grep -q 'systemctl --user restart autodoro.service' {hook}"
    )
    # claude-mcp-sync export invocation present.
    dellan.succeed(f"grep -q 'sync-mcp-servers.sh. export' {hook}")

    # Unconditional exit 0 so any dispatch failure never blocks the push.
    dellan.succeed(f"grep -q '^exit 0$' {hook}")

    # Syntax gate: bash must parse the composed hook.
    dellan.succeed(f"${pkgs.bash}/bin/bash -n {hook}")
  '';
}
