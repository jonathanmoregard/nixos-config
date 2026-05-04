# modules/nixos/actions-runner.nix
#
# Self-hosted GHA runner registered to the nixos-config repo. Runs as a
# dedicated NixOS-managed system user `actions-runner` with no shell.
# Resource-scoped via systemd cgroup attributes so CI work yields to
# interactive load on dellan.
#
# This module wraps nixpkgs' built-in services.github-runner with the
# spec's resource profile + the actions-runner-ssh-key hook for cloning
# private flake inputs.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.actionsRunner;
in
{
  options.services.actionsRunner = {
    enable = lib.mkEnableOption "self-hosted GHA runner";

    name = lib.mkOption {
      type = lib.types.str;
      default = "dellan-runner";
      description = "Display name registered with GitHub.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      description = "Repo or org URL (e.g. https://github.com/jonathanmoregard/nixos-config).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to GitHub registration token file (agenix).";
    };

    sshKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to actions-runner SSH private key (agenix). Cloned from this path into /var/lib/actions-runner/.ssh/id_ed25519 mode 0400.";
    };

    extraLabels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "x86_64-linux" "dellan" "kvm" ];
      description = "Runner labels for matrix targeting (e.g. self-hosted,x86_64-linux).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.github-runners."${cfg.name}" = {
      enable = true;
      url = cfg.url;
      tokenFile = cfg.tokenFile;
      ephemeral = false;
      replace = true;
      extraLabels = cfg.extraLabels;
      user = "actions-runner";
      group = "actions-runner";
    };

    users.users.actions-runner = {
      isSystemUser = true;
      group = "actions-runner";
      home = "/var/lib/actions-runner";
      createHome = true;
      shell = "/run/current-system/sw/bin/nologin";
    };
    users.groups.actions-runner = { };

    # Resource scoping. CPUWeight only kicks in under contention; under low
    # load the runner gets all available cores.
    systemd.slices.actions-runner = {
      description = "Resource scope for self-hosted GHA runner work";
      sliceConfig = {
        CPUWeight = 50;
        MemoryHigh = "20G";
      };
    };

    systemd.services."github-runner-${cfg.name}".serviceConfig = {
      Slice = "actions-runner.slice";
    };

    # SSH key for cloning private repos. agenix decrypts to a path that
    # we copy into the runner's .ssh dir mode 0400 (agenix's own mode is
    # 0400 owned by root by default).
    systemd.services."actions-runner-ssh-setup" = {
      description = "Place actions-runner SSH key into runner's home";
      wantedBy = [ "github-runner-${cfg.name}.service" ];
      before = [ "github-runner-${cfg.name}.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "actions-runner-ssh-setup" ''
          install -d -m 0700 -o actions-runner -g actions-runner /var/lib/actions-runner/.ssh
          install -m 0400 -o actions-runner -g actions-runner ${cfg.sshKeyFile} /var/lib/actions-runner/.ssh/id_ed25519
          # known_hosts for github.com — pinned to avoid prompts.
          # printf used (not heredoc) so Nix indentation doesn't get baked in.
          printf '%s\n' \
            'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' \
            > /var/lib/actions-runner/.ssh/known_hosts
          chmod 0644 /var/lib/actions-runner/.ssh/known_hosts
          chown actions-runner:actions-runner /var/lib/actions-runner/.ssh/known_hosts
        '';
      };
    };
  };
}
