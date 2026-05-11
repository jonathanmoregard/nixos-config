{ config, lib, pkgs, ... }:
# Feature VM overrides for the dellan host. Active ONLY when building
# `config.system.build.vm` (i.e. `nix build .#nixosConfigurations.dellan.config.system.build.vm`
# or `nixos-rebuild build-vm --flake .#dellan`). Prod toplevel on the
# real laptop is unaffected — `virtualisation.vmVariant.*` lives in a
# sub-config that the QEMU VM builder merges in, not the regular system.
#
# Usage:
#   1. Boot the VM (headless, snapshot mode = clean state per launch):
#        nix run .#feature-vm
#      (defined in flake.nix; wraps the underlying QEMU launch script
#      with `-snapshot -display none` and a fresh $TMPDIR.)
#   2. SSH in from the host in another terminal:
#        ssh -p 2222 -o StrictHostKeyChecking=no \
#            -o UserKnownHostsFile=/dev/null \
#            -i ~/.ssh/id_ed25519 jonathan@localhost
#   3. The host worktrees dir is mounted at /mnt/worktrees inside the
#      VM, so edits on the host show up live without rebooting the VM.
#
# Persistent qcow2 + graphics window (rarely needed):
#   nix build .#nixosConfigurations.dellan.config.system.build.vm
#   ./result/bin/run-dellan-vm
#
# Agenix: a copy of the host's `jonathan@dellan` SSH private key is
# 9p-mounted read-only into the VM at /mnt/host-ssh/id_ed25519, and
# `age.identityPaths` is pointed at it. jonathan@dellan is already a
# recipient of every `.age` file (see secrets/secrets.nix), so agenix
# activation inside the VM decrypts successfully and the runtime
# secrets dir is populated.
#
# The host-side export points at `~/.cache/feature-vm/host-ssh/`
# rather than `~/.ssh/` so the VM only sees the one file it needs —
# not `known_hosts`, agent sockets, or other key material that might
# live in `~/.ssh/`. The launcher (`apps.feature-vm` in flake.nix)
# populates the cache dir from `~/.ssh/id_ed25519` before booting
# the VM and refuses to start if the host key is missing.
#
# Trust model: the 9p mount uses `security_model=none`, so the 9p
# server runs filesystem ops as the host user that launched QEMU
# (jonathan, uid 1000). Root inside the VM thus reads the privkey via
# the server's host-jonathan credentials. This adds no new
# decryption capability — `jonathan@dellan`'s privkey is already an
# age recipient of every `.age` file, so any process that can read
# that key on the host can already decrypt every secret today. The
# 9p export reproduces that same trust level inside the VM, no new
# capability granted.
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

      # Extra 9p export for jonathan@dellan's SSH private key, so the
      # in-VM agenix activation can decrypt secrets without baking a
      # long-lived feature-VM identity into the recipient set.
      #
      # `security_model=none` (not the default `mapped-xattr`) so root
      # inside the VM reads the file via host-jonathan's credentials
      # — required because the privkey is mode 0600 jonathan-only and
      # `mapped-xattr` would enforce VM-side uid checks.
      #
      # The source path is a launcher-managed cache dir, not `~/.ssh/`,
      # so the VM only sees the one file it needs. The launcher
      # (`apps.feature-vm` in flake.nix) populates it before boot. If
      # this module is used outside the launcher (`run-dellan-vm`
      # directly), populate `~/.cache/feature-vm/host-ssh/id_ed25519`
      # manually first or agenix decryption will silently produce
      # empty secrets.
      #
      # The matching mount entry below lives in
      # `virtualisation.fileSystems` (qemu-vm.nix overrides the
      # top-level `fileSystems` wholesale with `mkVMOverride`, but
      # merges siblings of `virtualisation.fileSystems` at the same
      # priority).
      qemu.options = [
        "-virtfs"
        "local,path=/home/jonathan/.cache/feature-vm/host-ssh,security_model=none,mount_tag=host-ssh"
      ];

      # Mount the host-ssh 9p export read-only at /mnt/host-ssh.
      # `neededForBoot = true` ensures it lands in initrd before
      # agenix activation (stage-1) reads the privkey. The
      # `x-systemd.requires=modprobe@9pnet_virtio.service` option
      # mirrors what qemu-vm.nix injects for its own 9p mounts, so
      # the mount waits for the kernel module to load.
      fileSystems."/mnt/host-ssh" = {
        device = "host-ssh";
        fsType = "9p";
        options = [
          "trans=virtio"
          "version=9p2000.L"
          "msize=16384"
          "ro"
          "x-systemd.requires=modprobe@9pnet_virtio.service"
        ];
        neededForBoot = true;
      };
    };

    # Point agenix at the host privkey 9p-mounted above. jonathan@dellan
    # is already a recipient of every `.age` in secrets/secrets.nix, so
    # decryption succeeds without any rekey.
    age.identityPaths = [ "/mnt/host-ssh/id_ed25519" ];

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

      # Let jonathan `ls /run/agenix/` inside the VM. The agenix
      # generation dir is mode 0750 root:keys; individual secrets
      # owned by jonathan are still mode 0400, so this only widens
      # *directory listing*, not file reads.
      extraGroups = [ "keys" ];
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

    # Autologin into Cinnamon so interactive smoke tests can drive the
    # desktop session via QMP send-key without typing credentials at the
    # greeter every boot. Matches `tests/dellan-vm.nix`'s autologin
    # override — both are test/smoke contexts and never reach prod.
    services.xserver.displayManager.autoLogin = {
      enable = lib.mkForce true;
      user = "jonathan";
    };
  };
}
