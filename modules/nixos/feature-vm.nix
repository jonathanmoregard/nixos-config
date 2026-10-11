{ config, lib, pkgs, ... }:
# Feature VM overrides for every workstation host (dellan, tuxedo).
# Active ONLY when building `config.system.build.vm`. Prod toplevel on
# the real laptop is unaffected — `virtualisation.vmVariant.*` lives in a
# sub-config that the QEMU VM builder merges in, not the regular system.
#
# Drive it with the launcher (scripts/feature-vm.sh, `nix run
# .#feature-vm -- --help`): `up`, `run`, `apply`, `reset`, `down`. The
# host shares below are exported by that launcher, not baked in here, so
# it decides per boot what the guest may see:
#
#   locked (default)  worktrees + research-agent read-only (enforced by
#                     QEMU on the host, so root in the guest cannot write
#                     through them); guest network `restrict=on` (the ssh
#                     port forward still works).
#   --trusted         worktrees share read-write, guest internet on.
#   --agent           locked, except api.anthropic.com:443 (forwarded by
#                     QEMU on the host) and a Claude token in guest tmpfs,
#                     so Claude Code can run inside the VM.
#
# The research-agent checkout is always read-only: the guest copies it to
# local disk (feature-vm-research-agent-copy) and the inner microvms work
# on that copy.
#
# Secrets, in both modes: the VM never receives a host or user key. Every
# agenix secret is replaced by a throwaway fixture (see below). The real
# ones could not be opened in here anyway: agenix-rekey encrypts them to
# each machine's HOST key, which only root on the laptop can read.
let
  # Throwaway recipient + ciphertexts for the klaffat provisioning
  # secrets — see the `age.identityPaths` block below for why the feature
  # VM cannot use the real ones. Shared with the vm-klaffat-infra lane so
  # the smoke and the gate seed identical values.
  klaffatFixtures = import ../../tests/lib/klaffat-fixtures.nix { inherit pkgs; };
  klaffatSecretNames = [
    "klaffat-hcloud-token"
    "klaffat-cloudflare-api-token"
    "klaffat-state-passphrase"
    "klaffat-aws-access-key-id"
    "klaffat-aws-secret-access-key"
    "klaffat-demo-host-key"
    "klaffat-nix-signing-key"
    "klaffat-github-token"
  ];

  # Every other secret gets a throwaway ciphertext encrypted to an identity
  # minted here, the same pattern as klaffatFixtures. agenix then activates
  # cleanly and services find a file where they expect one, instead of
  # every boot and `feature-vm apply` failing on "no identity matched".
  # The plaintexts are the literal strings below; the identity is
  # world-readable in /nix/store and opens nothing else.
  fixtureSecretNames = lib.subtractLists klaffatSecretNames (builtins.attrNames config.age.secrets);
  fixtures = pkgs.runCommand "feature-vm-secrets"
    {
      nativeBuildInputs = [ pkgs.age pkgs.openssh ];
      names = fixtureSecretNames;
    } ''
      mkdir -p "$out"
      ssh-keygen -q -t ed25519 -N "" -C "feature-vm fixture identity" -f "$out/id_ed25519"
      pub="$(cat "$out/id_ed25519.pub")"
      for n in $names; do
        printf 'feature-vm-fixture-%s' "$n" | age -r "$pub" -o "$out/$n.age"
      done
    '';

  # A fixed sshd host key for the VM, so the launcher can pin it
  # (StrictHostKeyChecking=yes against its own known_hosts) instead of
  # trusting whatever answers on localhost:2222. World-readable in the
  # store, which is fine: it identifies a throwaway VM and nothing else.
  sshHostKey = pkgs.runCommand "feature-vm-ssh-host-key"
    { nativeBuildInputs = [ pkgs.openssh ]; } ''
      mkdir -p "$out"
      ssh-keygen -q -t ed25519 -N "" -C "feature-vm" -f "$out/ssh_host_ed25519_key"
    '';
in
{
  virtualisation.vmVariant = {
    services.openssh.hostKeys = lib.mkForce [
      { path = "/etc/ssh/feature-vm_host_ed25519_key"; type = "ed25519"; }
    ];
    # `mode` makes etc copy the file (root-owned 0600, as sshd requires)
    # rather than symlink into the store.
    environment.etc."ssh/feature-vm_host_ed25519_key" = {
      source = "${sshHostKey}/ssh_host_ed25519_key";
      mode = "0600";
    };
    # The launcher builds this to write its known_hosts entry.
    system.build.featureVmHostKey = sshHostKey;

    # Physical-host pressure thresholds exceed this disposable VM's entire
    # disk. Scale them so a normal build does not trigger GC immediately.
    nix.settings = {
      min-free = 128 * 1024 * 1024;
      max-free = 1024 * 1024 * 1024;
    };

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
          # Loopback only. Unset, QEMU's hostfwd listens on every
          # interface; the guest holds a copy of the host user's ssh key.
          host.address = "127.0.0.1";
          host.port = 2222;
          guest.port = 22;
        }
      ];

      # qemu-vm.nix always exports two more 9p shares, xchg and shared,
      # backed by a writable directory under the launcher's run dir and
      # with no read-only option. Point both at an empty store path: the
      # host user cannot write there, so the guest cannot either, in any
      # mode.
      sharedDirectories.xchg.source = lib.mkForce "${pkgs.emptyDirectory}";
      sharedDirectories.shared.source = lib.mkForce "${pkgs.emptyDirectory}";

      # Host shares, exported by the launcher's QEMU_OPTS (mount tags
      # worktrees, research-agent) so it can make them read-only.
      # The mounts live in `virtualisation.fileSystems` because qemu-vm.nix
      # overrides the top-level `fileSystems` wholesale with `mkVMOverride`.
      # Mapping is by host UID — host `jonathan` maps to VM `jonathan`.
      fileSystems."/mnt/worktrees" = {
        device = "worktrees";
        fsType = "9p";
        options = [
          "trans=virtio"
          "version=9p2000.L"
          "msize=131072"
          "x-systemd.requires=modprobe@9pnet_virtio.service"
        ];
      };

      # research-agent worktree, 9p-exported by the launcher. Mounted
      # read-only at a staging path and copied to local disk by
      # feature-vm-research-agent-copy below: the inner microvms share
      # /home/jonathan/Repos/research-agent over virtiofs, and virtiofs
      # stacked on a 9p mount fails every open() with EOPNOTSUPP, so the
      # scraper could not read scraper/server.py and crash-looped.
      fileSystems."/mnt/research-agent-src" = {
        device = "research-agent";
        fsType = "9p";
        options = [
          "trans=virtio"
          "version=9p2000.L"
          "msize=131072"
          "ro"
          "x-systemd.requires=modprobe@9pnet_virtio.service"
        ];
      };
    };

    # Local copy of the research-agent checkout for the inner microvms.
    # Reports they write land in this copy, not on the host. To pick up
    # host-side edits without a reboot, `sudo systemctl restart` this unit.
    systemd.services.feature-vm-research-agent-copy = {
      description = "Copy the 9p research-agent checkout to local disk for the microvms";
      wantedBy = [ "multi-user.target" ];
      requiredBy = [
        "microvm-virtiofsd@research-agent.service"
        "microvm-virtiofsd@scraper.service"
      ];
      before = [
        "microvm-virtiofsd@research-agent.service"
        "microvm-virtiofsd@scraper.service"
      ];
      unitConfig.RequiresMountsFor = [ "/mnt/research-agent-src" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Root, not jonathan: the 9p export is mapped-xattr, so the VM
        # sees host ownership. Host jonathan is uid 1003 on tuxedo while
        # the VM's jonathan is uid 1000, and most reports are mode 0600 —
        # as jonathan the copy failed with exit 23 on every one of them.
        # Root bypasses the VM-side check; the host side still reads as
        # the qemu process's own user. --chown hands the copy to jonathan.
        User = "root";
      };
      path = [ pkgs.rsync ];
      # reports/_quarantine/ is kept as an EMPTY directory (its contents
      # are never copied into the VM). The anchored exclude matches the
      # directory itself, so rsync never opendir()s it — an include-dir +
      # exclude-contents pair still lists it. The mkdir recreates it.
      script = ''
        dest=/home/jonathan/Repos/research-agent
        mkdir -p "$dest"
        rsync -a --delete --chown=jonathan:users \
          --exclude=.venv --exclude=__pycache__ \
          --exclude=/reports/_quarantine/ \
          /mnt/research-agent-src/ "$dest/"
        mkdir -p "$dest/reports/_quarantine"
        chown jonathan:users "$dest" "$dest/reports" "$dest/reports/_quarantine"
      '';
    };

    # agenix opens only fixtures here: the klaffat ones (a real-shaped
    # set shared with the vm-klaffat-infra lane) and the generic ones above.
    age.identityPaths = lib.mkForce [
      "${fixtures}/id_ed25519"
      "${klaffatFixtures}/id_ed25519"
    ];
    age.secrets = lib.genAttrs klaffatSecretNames (n: {
      file = lib.mkForce "${klaffatFixtures}/${n}.age";
    }) // lib.genAttrs fixtureSecretNames (n: {
      file = lib.mkForce "${fixtures}/${n}.age";
    });

    # Add jonathan@dellan as an authorized SSH key inside the VM so
    # the user/CC on dellan can ssh in without copying keys around.
    users.users.jonathan = {
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINy+08a1zu6ndn5RQ5TDV2uNrXJ+4lPmlcmmWXI8XH/8 jonathan@tuxedo"
      ];

      # No uid override: vmVariant re-evaluates the host config, so the
      # VM's jonathan keeps the host's pinned uid and writes on the
      # /mnt/worktrees 9p share land as the host-side owner.

      # Let jonathan `ls /run/agenix/` inside the VM. The agenix
      # generation dir is mode 0750 root:keys; individual secrets
      # owned by jonathan are still mode 0400, so this only widens
      # *directory listing*, not file reads.
      extraGroups = [ "keys" ];
    };

    # The launcher's guestfwd (--agent, --trusted) answers on 10.0.2.100:443
    # and connects to the real api.anthropic.com, so pin the name there.
    # In locked mode nothing listens and the connection is refused.
    networking.hosts."10.0.2.100" = [ "api.anthropic.com" ];

    # `feature-vm --agent up` copies a Claude token here (tmpfs) after
    # boot. /etc/zshenv runs for every zsh, including `feature-vm run`'s
    # non-interactive ssh commands. Non-essential traffic (telemetry, error
    # reports, auto-update) is off: api.anthropic.com is the only route out.
    environment.shellInit = ''
      if [ -r /run/feature-vm-agent/token ]; then
        CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/feature-vm-agent/token)"
        export CLAUDE_CODE_OAUTH_TOKEN
        export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
      fi
    '';

    # Console login fallback — same password regardless of the prod
    # `initialPassword` so the QEMU graphics window is usable on first
    # boot before SSH is up.
    users.users.jonathan.initialPassword = lib.mkForce "featurevm"; # pragma: allowlist secret

    # `feature-vm run` / `apply` drive the VM over non-interactive ssh, and
    # the VM is disposable (-snapshot), so sudo needs no password here.
    security.sudo.wheelNeedsPassword = lib.mkForce false;

    # Disable production-only services that either need real secrets,
    # depend on the dellan host's identity, or just slow the VM boot.
    # The point of the feature VM is to smoke-test config changes, not
    # to mirror prod end-to-end (the `tests/*.nix` lanes via
    # `tests/lib/common.nix` are the prod-parity gate).
    services.nixos-auto-deploy.enable = lib.mkForce false;
    services.tailscale.enable = lib.mkForce false;

    # /home/jonathan/Repos needs to exist before the 9p mount lands.
    systemd.tmpfiles.rules = [
      "d /home/jonathan/Repos 0755 jonathan users -"
    ];

    # Autologin into Cinnamon so interactive smoke tests can drive the
    # desktop session via QMP send-key without typing credentials at the
    # greeter every boot. Matches `tests/lib/common.nix`'s autologin
    # override — both are test/smoke contexts and never reach prod.
    services.displayManager.autoLogin = {
      enable = lib.mkForce true;
      user = "jonathan";
    };
  };
}
