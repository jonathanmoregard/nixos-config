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
  '';
}
