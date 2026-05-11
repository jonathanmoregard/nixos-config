{ config, lib, pkgs, ... }:
# Feature VM overrides for the dellan host. Active ONLY when building
# `config.system.build.vm` (i.e. `nix build .#nixosConfigurations.dellan.config.system.build.vm`
# or `nixos-rebuild build-vm --flake .#dellan`). Prod toplevel on the
# real laptop is unaffected — `virtualisation.vmVariant.*` lives in a
# sub-config that the QEMU VM builder merges in, not the regular system.
#
# Usage:
#   1. From a worktree:
#        nix build .#nixosConfigurations.dellan.config.system.build.vm
#   2. Run the VM (foreground, graphics window):
#        ./result/bin/run-dellan-vm
#   3. SSH in from the host (in another terminal):
#        ssh -p 2222 -o StrictHostKeyChecking=no \
#            -o UserKnownHostsFile=/dev/null \
#            -i ~/.ssh/id_ed25519 jonathan@localhost
#   4. The host worktrees dir is mounted at /mnt/worktrees inside the
#      VM, so edits on the host show up live without rebooting the VM.
#
# Agenix caveat: the VM boots with a freshly-generated ssh host key,
# which is NOT a recipient of any .age file in `secrets/`. Activation
# attempts decryption, fails, and the dependent services fail to
# start. Boot still reaches multi-user.target (same behavior as the
# existing `tests/dellan-vm.nix` gate). If a change under test needs a
# real secret, stage plaintext into /tmp from the host:
#   scp -P 2222 /tmp/anthropic-key.env jonathan@localhost:/tmp/
# rather than rekeying every .age against a long-lived VM identity.
{
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 20000;

      # Keep the QEMU graphics window so the user can interact directly
      # with a tty / X session inside the VM. Pass `-display none` at
      # invocation time for headless runs (Claude Code background use).
      graphics = true;

      # Expose the VM's sshd on host port 2222 so both the user and
      # Claude Code can drive the VM with plain `ssh -p 2222`.
      forwardPorts = [
        {
          from = "host";
          host.port = 2222;
          guest.port = 22;
        }
      ];

      # 9p-mount the host worktrees tree read-write into the VM so
      # edits on the host are visible immediately. Mapping is by host
      # UID — host `jonathan` (1000) maps to VM `jonathan` (1000).
      sharedDirectories.worktrees = {
        source = "/home/jonathan/Repos/nixos-config-worktrees";
        target = "/mnt/worktrees";
      };
    };

    # Add jonathan@dellan as an authorized SSH key inside the VM so
    # the user/CC on dellan can ssh in without copying keys around.
    users.users.jonathan = {
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan"
      ];

      # Pin UID to match the host's jonathan (1000). Without this, the
      # claude-agent-* users (declared first by claudeAgentUsers) claim
      # 1000-1002 and jonathan ends up at 1003, breaking write access
      # on the /mnt/worktrees 9p share whose host-side files are owned
      # by host uid 1000.
      uid = lib.mkForce 1000;
    };

    # Console login fallback — same password regardless of the prod
    # `initialPassword` so the QEMU graphics window is usable on first
    # boot before SSH is up.
    users.users.jonathan.initialPassword = lib.mkForce "featurevm"; # pragma: allowlist secret

    # Disable production-only services that either need real secrets,
    # depend on the dellan host's identity, or just slow the VM boot.
    # The point of the feature VM is to smoke-test config changes, not
    # to mirror prod end-to-end (`tests/dellan-vm.nix` is the
    # prod-parity gate).
    services.nixos-auto-deploy.enable = lib.mkForce false;
    services.tailscale.enable = lib.mkForce false;
  };
}
