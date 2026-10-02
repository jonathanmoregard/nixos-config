# vm-nix-gc: the scheduled Nix GC keeps recent unrooted build outputs.
#
# Boots modules/nixos/nix-gc.nix — the exact policy every host imports via
# modules/common.nix — and drives the real nix-gc.service, the unit the
# daily timer starts. Invariants:
#
#   unrooted path registered just now        → survives nix-gc.service
#     (the dev-shell / cargoArtifacts eviction the policy exists to stop)
#   unrooted path registered 30 days ago     → collected by nix-gc.service
#     (retention is a window, not "never collect")
#   after the run                            → no keep-recent roots remain,
#     so a plain `nix-store --gc` (what the min-free emergency collector
#     does) still reclaims the recent path: disk pressure beats cache
#   stale keep-recent roots (run killed)     → removed by boot tmpfiles
#
# A path's age is its ValidPaths.registrationTime; the test back-dates one
# path in the VM's own Nix DB because the clock cannot be moved per path.
#
# Run: nix build .#checks.x86_64-linux.vm-nix-gc -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-nix-gc";
  extraModules = [ ../modules/nixos/nix-gc.nix ];
  testScript = ''
    import shlex

    dellan.wait_for_unit("multi-user.target")

    def add_unrooted(name):
        dellan.succeed(f"echo {name}-$RANDOM-$(date +%s%N) > /tmp/{name}")
        return dellan.succeed(f"nix-store --add /tmp/{name}").strip()

    fresh = add_unrooted("fresh-devshell-output")
    old = add_unrooted("month-old-build-output")
    dellan.succeed(
        "${pkgs.sqlite}/bin/sqlite3 /nix/var/nix/db/db.sqlite "
        + shlex.quote(
            "update ValidPaths set registrationTime = strftime('%s','now') - 30*86400 "
            f"where path = '{old}';"
        )
    )

    # Neither path is reachable from any root before the run.
    roots = dellan.succeed("nix-store --gc --print-roots")
    assert fresh not in roots and old not in roots, roots

    dellan.succeed("systemctl start nix-gc.service")
    log = dellan.succeed("journalctl -u nix-gc.service --no-pager")
    assert "nix-gc-pin-recent: rooted" in log, log

    dellan.succeed(f"test -e {fresh}")
    dellan.fail(f"test -e {old}")
    dellan.fail("test -e /nix/var/nix/gcroots/keep-recent")

    # The retention is scoped to the scheduled run: an emergency or manual
    # collection still reclaims the recent path.
    dellan.succeed("nix-store --gc")
    dellan.fail(f"test -e {fresh}")

    # Roots left behind by a run that never reached postStop (power loss)
    # are dropped by the boot-time tmpfiles pass.
    stale = add_unrooted("stale-root-target")
    dellan.succeed(
        f"mkdir -p /nix/var/nix/gcroots/keep-recent && ln -s {stale} /nix/var/nix/gcroots/keep-recent/"
    )
    dellan.succeed("systemd-tmpfiles --remove")
    dellan.fail("test -e /nix/var/nix/gcroots/keep-recent")
  '';
}
