# modules/nixos/nixos-deploy.nix
#
# Production auto-deploy service. Triggered by the GitHub webhook handler
# on push:main events. Pulls origin/main into /etc/nixos and runs
# nixos-rebuild switch. Tracks last-good and poisoned SHAs to avoid
# re-attempting a known-broken commit. Surfaces success/failure to the
# desktop session via flag-files + a user-bus path-watcher pair.
#
# Bootstrap (one-time, scripts/bootstrap-deploy-target.sh):
#   1. Verify origin/main builds
#   2. Verify existing /etc/nixos has no uncommitted edits
#   3. Snapshot /etc/nixos to /etc/nixos.bak.<timestamp>
#   4. Replace symlink with a real root-owned clone
#   5. Start this service
#
# This module is INERT until imported by hosts/dellan/default.nix and
# user is set in deployTarget.username.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.nixosDeploy;

  deployScript = pkgs.writeShellScript "nixos-deploy" ''
    set -euo pipefail

    STATE=/var/lib/nixos-deploy
    mkdir -p "$STATE"
    LAST_GOOD="$STATE/last-good"
    POISONED_LOG="$STATE/poisoned.log"
    CURRENT_POISON="$STATE/current-poison"

    cd /etc/nixos
    ${lib.optionalString (cfg.sshKeyFile != null) ''
      export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i ${cfg.sshKeyFile} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    ''}
    git fetch origin main
    TARGET=$(git rev-parse origin/main)
    CURRENT=$(git rev-parse HEAD)

    [ "$CURRENT" = "$TARGET" ] && exit 0

    if [ -f "$CURRENT_POISON" ] && [ "$(cat "$CURRENT_POISON")" = "$TARGET" ]; then
      echo "deploy: target $TARGET is poisoned; manual reset required"
      echo "  log:    $POISONED_LOG"
      echo "  clear:  sudo rm $CURRENT_POISON && sudo systemctl reset-failed nixos-deploy"
      exit 1
    fi

    git reset --hard "$TARGET"
    if ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake /etc/nixos#${cfg.hostName}; then
      echo "$TARGET" > "$LAST_GOOD"
      rm -f "$CURRENT_POISON"
      touch "$STATE/notify-success"
    else
      echo "$TARGET" > "$CURRENT_POISON"
      printf '%s\t%s\t%s\n' "$(date -Iseconds)" "$TARGET" "FAILED" >> "$POISONED_LOG"
      touch "$STATE/notify-failure"
      exit 1
    fi
  '';

  notifyFailureScript = pkgs.writeShellScript "deploy-notify-failure" ''
    set -e
    SHA=$(cat /var/lib/nixos-deploy/current-poison 2>/dev/null || echo unknown)
    ${pkgs.libnotify}/bin/notify-send -u critical "nixos-deploy FAILED" \
      "Commit $SHA failed activation. Recovery: sudo nixos-rebuild switch --rollback"
    sudo ${pkgs.coreutils}/bin/rm -f /var/lib/nixos-deploy/notify-failure
  '';

  notifySuccessScript = pkgs.writeShellScript "deploy-notify-success" ''
    set -e
    SHA=$(cat /var/lib/nixos-deploy/last-good)
    ${pkgs.libnotify}/bin/notify-send -u low "nixos-deploy" "Applied $SHA"
    sudo ${pkgs.coreutils}/bin/rm -f /var/lib/nixos-deploy/notify-success
  '';
in
{
  options.services.nixosDeploy = {
    enable = lib.mkEnableOption "auto-deploy from origin/main";

    hostName = lib.mkOption {
      type = lib.types.str;
      default = "dellan";
      description = "nixosConfigurations.<hostName> to switch to.";
    };

    notifyUser = lib.mkOption {
      type = lib.types.str;
      default = "jonathan";
      description = "User whose session bus receives deploy notifications.";
    };

    sshKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to SSH private key for the `git fetch origin main` step.
        Required because /etc/nixos's origin is git@github.com (private repo).
        Typically reused from the actions-runner deploy key:
          sshKeyFile = config.age.secrets.actions-runner-ssh-key.path;
        If null, falls back to root's ~/.ssh/id_ed25519 (must exist).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Linger required so user systemd starts at boot, before login —
    # otherwise the very first deploy after reboot has no session to notify.
    users.users.${cfg.notifyUser}.linger = true;

    # Sudoers entries for the user's notify scripts to remove the flag files.
    # Pinning these explicitly so the notification path doesn't depend on
    # a global passwordless-sudo policy that may tighten later.
    security.sudo.extraRules = [{
      users = [ cfg.notifyUser ];
      commands = [
        { command = "${pkgs.coreutils}/bin/rm -f /var/lib/nixos-deploy/notify-failure"; options = [ "NOPASSWD" ]; }
        { command = "${pkgs.coreutils}/bin/rm -f /var/lib/nixos-deploy/notify-success"; options = [ "NOPASSWD" ]; }
      ];
    }];

    # State directory ownership.
    systemd.tmpfiles.rules = [
      "d /var/lib/nixos-deploy 0755 root root - -"
    ];

    # The deploy service. Triggered manually via systemctl start (typically
    # by the GitHub webhook handler in modules/nixos/github-webhook.nix).
    systemd.services.nixos-deploy = {
      description = "Auto-deploy from origin/main";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${deployScript}";
      };
      # systemd oneshots already serialize naturally — a second `start`
      # while one is running is a no-op. Earlier draft used Conflicts=self
      # which has the opposite effect (stops the running one).
      path = with pkgs; [ git nixos-rebuild openssh ];
    };

    # User-bus notification chain. systemd Path.PathExists watches one path
    # per unit, so we declare two separate (path + service) pairs — one
    # for failure, one for success. Merging into a parent-dir watcher
    # would re-fire on last-good writes (false positives).
    systemd.user.paths.nixos-deploy-notify-failure = {
      description = "Watch for nixos-deploy failure flag";
      pathConfig.PathExists = "/var/lib/nixos-deploy/notify-failure";
      wantedBy = [ "default.target" ];
    };

    systemd.user.services.nixos-deploy-notify-failure = {
      description = "Surface nixos-deploy failure via desktop notification";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${notifyFailureScript}";
      };
    };

    systemd.user.paths.nixos-deploy-notify-success = {
      description = "Watch for nixos-deploy success flag";
      pathConfig.PathExists = "/var/lib/nixos-deploy/notify-success";
      wantedBy = [ "default.target" ];
    };

    systemd.user.services.nixos-deploy-notify-success = {
      description = "Surface nixos-deploy success via desktop notification";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${notifySuccessScript}";
      };
    };
  };
}
