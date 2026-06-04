# vm-microvm: research-agent microvm unit installation + agenix wiring.
#
# Asserts:
#   - install-microvm-research-agent.service exists and runs
#   - microvm@research-agent.service template lands in /etc/systemd/system
#   - /var/lib/research-agent/vm-ssh (host-side persisted ssh-host-keys
#     share) is created via systemd.tmpfiles, owner root mode 700
#   - agenix activation script references research-agent-host-key
#
# Nested-VM gate: starting microvm@research-agent.service would require
# nested KVM in the outer test QEMU. Some CI / dev hosts don't expose
# /dev/kvm to nested guests, so this lane asserts that the module
# evaluates and its systemd unit landed. Full boot+ssh+egress smoke
# lives in interactive `nix run .#feature-vm` per the SessionStart
# HARD RULE.
#
# Run: nix build .#checks.x86_64-linux.vm-microvm -L
{ pkgs, inputs }:

let
  lib = pkgs.lib;
in
pkgs.testers.runNixOSTest {
  name = "vm-microvm";
  skipTypeCheck = true;

  nodes.dellan = { config, ... }: {
    imports = [
      inputs.agenix.nixosModules.default
      inputs.agenix-rekey.nixosModules.default
      inputs.home-manager.nixosModules.home-manager
      inputs.microvm.nixosModules.host
      ../hosts/dellan/default.nix
      ../modules/common.nix
    ];

    # Strip the laptop's real hardware/disk config — virtualisation module
    # provides a virtio rootfs and the test framework boots without a
    # bootloader.
    disabledModules = [ ../hosts/dellan/hardware-configuration.nix ];

    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.jonathan = import ../home/jonathan-linux.nix;
    };

    users.users.jonathan = {
      linger = true;
      initialPassword = lib.mkForce "test";
    };

    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 8192;
    };

    # microvm.nix test-mode overrides. The production dellan config tells
    # microvm.vms.research-agent to virtiofs-share three host dirs that
    # don't exist inside this nested test VM. Without stubs, virtiofsd
    # blocks ~5min waiting for sources and pushes multi-user.target
    # behind its timeout. We also disable the inner VM start: this lane
    # asserts unit *installation*, not boot. Full boot lives in
    # `nix run .#feature-vm`.
    systemd.tmpfiles.rules = [
      "d /home/jonathan/Repos 0755 jonathan users -"
      "d /home/jonathan/Repos/research-agent 0755 jonathan users -"
      "d /home/jonathan/Repos/research-agent/reports 0755 jonathan users -"
    ];
    systemd.services."install-microvm-research-agent".wantedBy =
      lib.mkForce [ ];
    systemd.services."microvm@research-agent".wantedBy = lib.mkForce [ ];
    systemd.services."microvm-virtiofsd@research-agent".wantedBy =
      lib.mkForce [ ];
    # Same stubs for the scraper sibling VM. This lane asserts unit
    # installation only; interactive boot lives in `nix run .#feature-vm`.
    systemd.services."install-microvm-scraper".wantedBy = lib.mkForce [ ];
    systemd.services."microvm@scraper".wantedBy = lib.mkForce [ ];
    systemd.services."microvm-virtiofsd@scraper".wantedBy = lib.mkForce [ ];
  };

  testScript = ''
    dellan.wait_for_unit("multi-user.target")

    # microvm.nix install-microvm-<name> oneshot exists and runs cleanly.
    # We disabled `wantedBy = [ multi-user.target ]` in the test
    # overrides, so trigger it explicitly to materialize the per-VM
    # files under /var/lib/microvms/<name>.
    dellan.succeed(
        "systemctl cat install-microvm-research-agent.service "
        "| grep -q 'Description='"
    )
    dellan.succeed("systemctl start install-microvm-research-agent.service")
    dellan.succeed("test -d /var/lib/microvms/research-agent")
    dellan.succeed(
        "systemctl cat microvm@research-agent.service "
        "| grep -q 'Description='"
    )

    # Persisted vm-ssh state dir must be in place before the VM boots.
    # The host module's systemd.tmpfiles.rules are the load-bearing piece.
    dellan.succeed("test -d /var/lib/research-agent/vm-ssh")
    perms = dellan.succeed(
        "stat -c '%a %U' /var/lib/research-agent/vm-ssh"
    ).strip()
    assert perms == "700 root", (
        f"vm-ssh dir perms expected '700 root', got {perms!r}"
    )

    # Health-check watchdog: timer and oneshot service must be installed,
    # the script must defer to operator-stopped state cleanly, and the
    # systemctl-restart command name must appear in the script body (a
    # rename of the microvm unit would silently break the watchdog).
    dellan.succeed(
        "systemctl cat research-agent-healthcheck.timer "
        "| grep -q 'OnUnitActiveSec=1min'"
    )
    dellan.succeed(
        "systemctl cat research-agent-healthcheck.service "
        "| grep -q 'Description='"
    )
    script_path = dellan.succeed(
        "systemctl cat research-agent-healthcheck.service "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    # Match the literal command issued on restart. --no-block keeps the
    # oneshot bounded (the unit's TimeoutStartSec is 30s); a regression
    # back to synchronous restart would let stuck activations stack
    # behind the 1-min timer.
    dellan.succeed(
        f"grep -q 'systemctl restart --no-block microvm@research-agent.service' {script_path}"
    )
    # Probe should treat operator-stopped microvm as a no-op (exit 0
    # silently) — otherwise an admin `systemctl stop microvm@...` would
    # be fought by the watchdog. The microvm unit is stopped in this
    # test (wantedBy mkForce []), so a fresh run must exit 0.
    dellan.succeed("systemctl start research-agent-healthcheck.service")

    # Count-file corruption MUST NOT brick the watchdog. Under `set -u`
    # without sanitization, non-numeric input would crash the
    # arithmetic and leave the script aborting forever each tick.
    # read_int must clamp garbage back to 0.
    dellan.succeed(
        "mkdir -p /run/research-agent-healthcheck "
        "&& printf 'abc\\n0\\n5garbage' > /run/research-agent-healthcheck/fail-count"
    )
    dellan.succeed("systemctl start research-agent-healthcheck.service")
    # Service must reach 'inactive' (oneshot exited 0), not 'failed'.
    rc = dellan.succeed(
        "systemctl is-failed research-agent-healthcheck.service || true"
    ).strip()
    assert rc != "failed", (
        f"watchdog must survive corrupted state file; got is-failed={rc!r}"
    )

    # agenix entry for the host-to-VM SSH private key is wired.
    # agenix declares per-secret install snippets in the system's
    # activation script — `grep` finds the secret name there. The file
    # itself doesn't materialize in this test because the test VM's SSH
    # host keys aren't in secrets.nix's recipient list, so decryption
    # fails. The reference in the activation snippet is the right
    # plumbing check.
    dellan.succeed(
        "grep -rq research-agent-host-key /run/current-system/activate "
        "/run/current-system/etc/ "
        "|| grep -rq research-agent-host-key /nix/store/*activate* 2>/dev/null"
    )

    # ---------------------------------------------------------------
    # scraper microvm — same shape of assertions as research-agent,
    # plus the bearer-token init service that gates both VMs.
    # ---------------------------------------------------------------
    dellan.succeed(
        "systemctl cat install-microvm-scraper.service "
        "| grep -q 'Description='"
    )
    dellan.succeed("systemctl start install-microvm-scraper.service")
    dellan.succeed("test -d /var/lib/microvms/scraper")
    dellan.succeed(
        "systemctl cat microvm@scraper.service | grep -q 'Description='"
    )

    # Persisted scraper state dirs must be in place before the VM boots.
    dellan.succeed("test -d /var/lib/scraper/vm-ssh")
    perms = dellan.succeed(
        "stat -c '%a %U' /var/lib/scraper/vm-ssh"
    ).strip()
    assert perms == "700 root", (
        f"scraper vm-ssh dir perms expected '700 root', got {perms!r}"
    )

    # Bearer-token init service must exist and produce a token file when
    # invoked. The token is regenerated on every boot; consumers read it
    # via virtiofs on demand, so rotation = a single `systemctl restart`.
    dellan.succeed(
        "systemctl cat scraper-bearer-init.service | grep -q 'Description='"
    )
    dellan.succeed("test -d /var/lib/scraper-bearer")
    perms = dellan.succeed(
        "stat -c '%a %U' /var/lib/scraper-bearer"
    ).strip()
    assert perms == "755 root", (
        f"scraper-bearer dir perms expected '755 root', got {perms!r}"
    )
    dellan.succeed("systemctl start scraper-bearer-init.service")
    dellan.succeed("test -s /var/lib/scraper-bearer/token")
    token_perms = dellan.succeed(
        "stat -c '%a %U' /var/lib/scraper-bearer/token"
    ).strip()
    assert token_perms == "444 root", (
        f"scraper token file perms expected '444 root', got {token_perms!r}"
    )
    # Token shape: base64url, ~43 ASCII chars, no '=' / '+' / '/'.
    token_body = dellan.succeed(
        "cat /var/lib/scraper-bearer/token"
    ).strip()
    assert len(token_body) >= 32, (
        f"scraper token too short: got {len(token_body)} chars"
    )
    assert all(
        c.isalnum() or c in "-_" for c in token_body
    ), f"scraper token contains non-base64url chars: {token_body!r}"

    # Research-agent ↔ scraper egress allow rule is structurally inside
    # the guest VM's nftables ruleset, not visible from this outer test
    # node. The interactive `nix run .#feature-vm` lane covers end-to-end
    # reachability (render_shim posting to the scraper); skip a brittle
    # grep here.

    # ---------------------------------------------------------------
    # scraper healthcheck — mirror of research-agent watchdog.
    # ---------------------------------------------------------------
    dellan.succeed(
        "systemctl cat scraper-healthcheck.timer "
        "| grep -q 'OnUnitActiveSec=1min'"
    )
    dellan.succeed(
        "systemctl cat scraper-healthcheck.service | grep -q 'Description='"
    )
    scraper_script = dellan.succeed(
        "systemctl cat scraper-healthcheck.service "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    # Must restart the scraper unit (not research-agent's) on persistent
    # failure. A rename of the microvm unit would silently break this.
    dellan.succeed(
        f"grep -q 'systemctl restart --no-block microvm@scraper.service' {scraper_script}"
    )
    # Probe operator-stopped microvm as a no-op (the scraper unit is
    # stopped in this test via wantedBy mkForce []), exit 0 silently.
    dellan.succeed("systemctl start scraper-healthcheck.service")
    rc = dellan.succeed(
        "systemctl is-failed scraper-healthcheck.service || true"
    ).strip()
    assert rc != "failed", (
        f"scraper watchdog must survive operator-stopped VM; got is-failed={rc!r}"
    )
    # Corrupted state file must NOT brick the watchdog (read_int clamp).
    dellan.succeed(
        "mkdir -p /run/scraper-healthcheck "
        "&& printf 'abc\\n0\\n5garbage' > /run/scraper-healthcheck/fail-count"
    )
    dellan.succeed("systemctl start scraper-healthcheck.service")
    rc = dellan.succeed(
        "systemctl is-failed scraper-healthcheck.service || true"
    ).strip()
    assert rc != "failed", (
        f"scraper watchdog must survive corrupted state; got is-failed={rc!r}"
    )
  '';
}
