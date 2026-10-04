# vm-security-batch: the services.securityBatch module
# (modules/nixos/security-batch.nix) with a fixture runner whose behaviour
# the test sets through /run/sb-fixture/mode. Invariants:
#
#   exit 0                    → no unit-failures record; latest = previous = this run
#   exit 1                    → record, readable by jonathan, summary filtered to
#                               counts/IDs; previous stays on the last pass
#   summary.txt symlinked to a root-only file → its content never reaches the record
#   offline                   → skip, not a failure; record and links untouched
#   next pass                 → record cleared
#   runner past `timeout`     → reaped, record says it did not finish
#   runner exit 75            → reported as a tool error (3), not as a skip
#   runs > 90 days            → pruned, except what latest/previous point at
#   two starts at once        → one run
#   sandbox                   → the runner reaches its credential via
#                               $CREDENTIALS_DIRECTORY but not the root-only
#                               source file; nix-store queries the daemon and
#                               systemd-analyze security reads D-Bus (what the
#                               research-agent runner needs)
#
# Run: nix build .#checks.x86_64-linux.vm-security-batch -L
{ pkgs, inputs }:
let
  fixture = pkgs.writeShellApplication {
    name = "security-batch-fixture";
    runtimeInputs = [ pkgs.coreutils pkgs.nix pkgs.systemd ];
    text = ''
      case "$(cat /run/sb-fixture/mode)" in
        pass)
          sha256sum < "$CREDENTIALS_DIRECTORY/token" | cut -c1-16 > credential-sha
          if cat /etc/sb-token > /dev/null 2>&1; then echo readable; else echo denied; fi > direct-read
          nix-store --query --requisites /run/current-system | wc -l > requisites
          systemd-analyze security --no-pager sb-listener.service | grep 'Overall exposure' > score
          echo "new=0" > summary.txt
          exit 0 ;;
        fail)
          # shellcheck disable=SC2016
          printf 'new=1 CVE-2099-0001 $(touch /tmp/pwned) \033[31m<b>`id`\n' > summary.txt
          exit 1 ;;
        symlink) ln -s /etc/sb-secret summary.txt; exit 1 ;;
        sleep) sleep 600 ;;
        short) sleep 5; echo "new=0" > summary.txt; exit 0 ;;
        rc75) exit 75 ;;
      esac
    '';
  };
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-security-batch";
  extraModules = [
    ../modules/nixos/security-batch.nix
    {
      services.securityBatch.fixture = {
        schedule = "Sun 03:00";
        timeout = "20s";
        script = fixture;
        credentials.token = "/etc/sb-token";
        # The VM has no internet; probe a local listener instead of github.
        serviceConfig.Environment = "NETWORK_ONLINE_PROBE=127.0.0.1:8000";
      };
      environment.etc."sb-token" = { text = "s3cret-token"; mode = "0400"; };
      environment.etc."sb-secret" = { text = "TOPSECRET-SHADOW"; mode = "0400"; };
      systemd.services.sb-listener = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --bind 127.0.0.1";
      };
    }
  ];
  testScript = ''
    import json

    m = dellan
    unit = "security-batch-fixture.service"
    state = "/var/lib/security-batch/fixture"
    record = "/var/lib/unit-failures/security-batch-fixture.json"
    marker = "security-batch-notify: recorded"

    m.wait_for_unit("multi-user.target")
    m.wait_for_unit("sb-listener.service")
    m.wait_until_succeeds("${pkgs.bash}/bin/bash -c ': </dev/tcp/127.0.0.1/8000'")
    m.succeed("systemctl list-timers --all --no-pager | grep -q security-batch-fixture.timer")

    def mode(x):
        m.succeed(f"mkdir -p /run/sb-fixture && echo {x} > /run/sb-fixture/mode")

    def link(name):
        return m.succeed(f"readlink {state}/{name}").strip()

    def notified():
        return m.succeed(
            "journalctl -u security-batch-notify@fixture.service --no-pager || true"
        ).count(marker)

    def failed_run(before):
        m.succeed("systemctl reset-failed " + unit + " || true")
        m.wait_until_succeeds(
            "journalctl -u security-batch-notify@fixture.service --no-pager "
            f"| grep -c '{marker}' | grep -qx {before + 1}",
            timeout=60,
        )
        raw = m.succeed(f"su jonathan -s /bin/sh -c 'cat {record}'")
        print("[diag] record: " + raw)
        return json.loads(raw)

    # ── 1. pass: no record, both links on this run, results readable ──
    mode("pass")
    m.succeed(f"systemctl start {unit}")
    m.fail(f"test -e {record}")
    first = link("latest")
    assert first.startswith("runs/") and link("previous") == first, (first, link("previous"))
    m.succeed(f"su jonathan -s /bin/sh -c 'cat {state}/latest/summary.txt {state}/latest/exit-status'")
    m.fail(f"su jonathan -s /bin/sh -c 'touch {state}/latest/x'")
    perms = m.succeed(f"stat -c '%U:%G %a' {state} {state}/latest/").split()
    print("[diag] perms: " + " ".join(perms))
    assert perms == ["secbatch-fixture:users", "750", "secbatch-fixture:users", "750"], perms

    # Sandbox: credential via LoadCredential only; daemon + D-Bus reachable.
    want = m.succeed("sha256sum < /etc/sb-token | cut -c1-16").strip()
    assert m.succeed(f"cat {state}/latest/credential-sha").strip() == want
    assert m.succeed(f"cat {state}/latest/direct-read").strip() == "denied"
    assert int(m.succeed(f"cat {state}/latest/requisites")) > 10
    m.succeed(f"grep -q 'Overall exposure level for sb-listener.service' {state}/latest/score")

    # ── 2. findings: record for Claude, filtered summary, baseline kept ──
    mode("fail")
    before = notified()
    m.fail(f"systemctl start {unit}")
    rec = failed_run(before)
    assert rec["unit"] == unit and rec["result"] == "exit-code" and rec["exit_status"] == "1", rec
    assert "new=1 CVE-2099-0001" in rec["summary"], rec
    for bad in ["$", "`", "\x1b", "<"]:
        assert bad not in rec["summary"], (bad, rec)
    assert len(rec["summary"]) <= 300 and len(rec["inspect"]) <= 120, rec
    assert link("previous") == first and link("latest") != first
    m.succeed("test ! -e /tmp/pwned")
    perms = m.succeed(f"stat -c '%U:%G %a' {record}").strip()
    assert perms == "root:root 644", perms

    # ── 3. a planted symlink cannot make the root notifier disclose a file ──
    mode("symlink")
    before = notified()
    m.fail(f"systemctl start {unit}")
    rec = failed_run(before)
    assert "TOPSECRET" not in json.dumps(rec), rec
    assert "no summary.txt" in rec["summary"], rec

    # ── 4. offline: skip, nothing changes ──
    m.succeed("systemctl stop sb-listener.service")
    latest = link("latest")
    mode("pass")
    m.succeed(f"systemctl start {unit}")
    m.succeed(f"test -e {record}")
    assert link("latest") == latest
    m.succeed(f"grep -q offline {state}/last-skip")
    m.succeed("systemctl start sb-listener.service")
    m.wait_until_succeeds("${pkgs.bash}/bin/bash -c ': </dev/tcp/127.0.0.1/8000'")

    # ── 5. recovery clears the record ──
    before = notified()
    m.succeed(f"systemctl start {unit}")
    m.fail(f"test -e {record}")
    assert link("previous") == link("latest") != latest
    assert notified() == before

    # ── 6. timeout reaps the runner ──
    mode("sleep")
    before = notified()
    m.fail(f"systemctl start {unit}")
    rec = failed_run(before)
    assert rec["result"] == "timeout" and "did not finish" in rec["summary"], rec
    m.fail("pgrep -u secbatch-fixture sleep")

    # ── 7. the runner cannot fake a skip ──
    mode("rc75")
    before = notified()
    m.fail(f"systemctl start {unit}")
    rec = failed_run(before)
    assert rec["exit_status"] == "3", rec

    # ── 8. retention: >90 days pruned, link targets kept ──
    prev = link("previous")
    m.succeed(
        f"mkdir {state}/runs/20200101T000000Z-old && "
        f"touch -d '100 days ago' {state}/runs/20200101T000000Z-old {state}/{prev}"
    )
    mode("fail")
    before = notified()
    m.fail(f"systemctl start {unit}")
    failed_run(before)
    m.fail(f"test -e {state}/runs/20200101T000000Z-old")
    m.succeed(f"test -d {state}/{prev}")

    # ── 9. no overlapping runs ──
    # Counted in the journal: this pass also prunes the 100-day-old former
    # baseline from step 8, so the runs/ count is no measure.
    def started():
        return m.succeed(f"journalctl -u {unit} --no-pager").count("security-batch fixture: run ")
    mode("short")
    n = started()
    m.succeed(f"systemctl start --no-block {unit} && sleep 1 && systemctl start --no-block {unit}")
    m.wait_until_succeeds(f"systemctl show -p ActiveState --value {unit} | grep -qx inactive", timeout=60)
    assert started() == n + 1, (n, started())
    m.fail(f"test -e {state}/{prev}")
    m.fail(f"test -e {record}")
  '';
}
