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

    # ── A failing scheduled GC must reach Claude, not stay in the journal ──
    #
    # The pin step fails closed, so broken `nix path-info` output (a Nix
    # bump) stops every scheduled GC. The failure must leave a durable
    # record that ~/.claude's SessionStart hook reads, and a healthy run
    # must clear it and notify nobody.
    import json

    record = "/var/lib/unit-failures/nix-gc.json"
    marker = "nix-gc-failure-notify: recorded"

    def notifier_runs():
        out = dellan.succeed(
            "journalctl -u nix-gc-failure-notify.service --no-pager || true"
        )
        return out.count(marker)

    # The healthy runs above notified nobody and left no record.
    assert notifier_runs() == 0, "notifier fired on a healthy run"
    dellan.fail(f"test -e {record}")

    # Stub the exact nix binary the pin step runs (bind-mounted over the
    # store path inside nix-gc.service only), once failing outright and
    # once emitting garbage instead of JSON.
    nix_bin = dellan.succeed("readlink -f /run/current-system/sw/bin/nix").strip()
    stubs = {
        "exit1": "#!/bin/sh\necho 'stub nix: simulated failure' >&2\nexit 1\n",
        "garbage": "#!/bin/sh\necho 'this is not path-info json'\n",
    }
    for kind, body in stubs.items():
        protected = add_unrooted(f"protected-{kind}")
        dellan.succeed(
            f"printf %s {shlex.quote(body)} > /etc/nix-stub-{kind} && chmod 0755 /etc/nix-stub-{kind}"
        )
        dellan.succeed(
            "mkdir -p /run/systemd/system/nix-gc.service.d && "
            "printf '[Service]\\nBindReadOnlyPaths=/etc/nix-stub-"
            + kind + ":" + nix_bin
            + "\\n' > /run/systemd/system/nix-gc.service.d/stub-nix.conf && "
            "systemctl daemon-reload"
        )
        before = notifier_runs()
        dellan.fail("systemctl start nix-gc.service")
        dellan.succeed("systemctl is-failed nix-gc.service")
        dellan.wait_until_succeeds(
            f"journalctl -u nix-gc-failure-notify.service --no-pager | grep -c '{marker}' "
            f"| grep -qx {before + 1}",
            timeout=60,
        )
        log = dellan.succeed("journalctl -u nix-gc-failure-notify.service --no-pager")
        assert "nix-gc FAILED (result=exit-code" in log, log

        # The record is valid JSON, names the unit, and an unprivileged
        # user (the Claude session) can read it.
        raw = dellan.succeed(f"su jonathan -s /bin/sh -c 'cat {record}'")
        print("[diag] nix-gc failure record: " + raw)
        rec = json.loads(raw)
        assert rec["unit"] == "nix-gc.service", rec
        assert rec["result"] == "exit-code", rec
        assert rec["failed_at"] and rec["inspect"], rec

        # Root owns record and directory, nobody else can write either
        # (the hook trusts the record as root-authored), and no in-flight
        # temp file is left behind.
        perms = dellan.succeed(
            f"stat -c '%U:%G %a' /var/lib/unit-failures {record}"
        ).split("\n")
        assert perms[:2] == ["root:root 755", "root:root 644"], perms
        dellan.fail(f"su jonathan -s /bin/sh -c 'echo x >> {record}'")
        dellan.fail("su jonathan -s /bin/sh -c 'touch /var/lib/unit-failures/x.json'")
        dellan.succeed("test -z \"$(ls -A /var/lib/unit-failures | grep -v '^nix-gc.json$')\"")

        # Fail closed: nothing was collected without its pins.
        dellan.succeed(f"test -e {protected}")

        dellan.succeed(
            "rm /run/systemd/system/nix-gc.service.d/stub-nix.conf && "
            "systemctl daemon-reload && systemctl reset-failed nix-gc.service"
        )

    # Recovery: the next healthy run clears the record and notifies nobody.
    before = notifier_runs()
    dellan.succeed("systemctl start nix-gc.service")
    dellan.fail(f"test -e {record}")
    assert notifier_runs() == before, "notifier fired on the healthy recovery run"
  '';
}
