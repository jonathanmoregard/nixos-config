# modules/nixos/nixos-auto-deploy.nix
#
# Single module subsuming github-webhook + nixos-deploy. Pull-based, with
# webhook as latency optimization. See spec at the top of the PR for the
# design + state-machine rationale (poison-latch + ancestor auto-clear,
# manual-hold, generation-tag halt-on-human-touch).
#
# - Idempotent: re-running deploy is no-op if origin/main is unchanged.
# - No re-attempt loop: failed SHAs latched until origin/main advances
#   past them (verified via `git merge-base --is-ancestor`).
# - No fight with human: if current generation lacks the
#   automated-deploy-* tag (from a manual rebuild or rollback), service
#   halts until manually cleared.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.nixos-auto-deploy;

  deployScript = pkgs.writeShellApplication {
    name = "nixos-deploy";
    runtimeInputs = with pkgs; [
      git
      nixos-rebuild
      util-linux
      openssh
      coreutils
      gnugrep
      gnused
    ];
    text = ''
      set -euo pipefail
      STATE=/var/lib/nixos-deploy
      mkdir -p "$STATE"
      touch "$STATE/poison-latch"

      exec {lock_fd}>"$STATE/lock"
      flock -n "$lock_fd" || { echo "another run in progress; exiting"; exit 0; }

      if [ -e "$STATE/manual-hold" ]; then
        echo "manual-hold present; halting"
        echo "  to clear: sudo rm $STATE/manual-hold"
        exit 1
      fi

      # Halt-on-human-touch via sidecar provenance file.
      # `nixos-rebuild` doesn't accept a --tag flag (research-Claude
      # extrapolated incorrectly), and templating system.nixos.tags into
      # the flake per-build is gnarly. Sidecar file is the pragmatic path.
      #
      # Invariant: after a successful auto-deploy, last-deployed-sha
      # records the SHA we switched to AND the resulting toplevel store
      # path. On each run, if /run/current-system's toplevel doesn't
      # match the recorded one, a human switched the system between runs
      # (manual rebuild or rollback). Halt until cleared.
      current_toplevel=$(readlink -f /run/current-system)
      recorded_toplevel=$(awk 'NR==2 {print}' "$STATE/last-deployed-sha" 2>/dev/null || true)

      if [ -e "$STATE/has-deployed" ] && [ "$current_toplevel" != "$recorded_toplevel" ]; then
        echo "current generation does not match last auto-deploy; halting"
        echo "  current  : $current_toplevel"
        echo "  recorded : $recorded_toplevel"
        echo "  (manual rebuild or rollback detected; refusing to fight a human)"
        echo "  to override: run a manual deploy via this service"
        echo "    sudo systemctl start nixos-deploy.service  (no — reads stale state)"
        echo "  or: clear by hand:"
        echo "    sudo rm $STATE/last-deployed-sha $STATE/has-deployed"
        echo "    then sudo systemctl start nixos-deploy.service"
        exit 1
      fi

      cd "${cfg.workingDir}"
      ${lib.optionalString (cfg.sshKeyFile != null) ''
        export GIT_SSH_COMMAND="ssh -i ${cfg.sshKeyFile} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
      ''}
      git fetch --quiet origin "${cfg.branch}"
      target_sha=$(git rev-parse "origin/${cfg.branch}")

      # Step 5: poison-latch check + auto-clear.
      if grep -qFx "$target_sha" "$STATE/poison-latch"; then
        echo "$target_sha is poisoned; skipping"
        exit 0
      fi
      if [ -s "$STATE/poison-latch" ]; then
        all_ancestors=true
        while read -r poisoned; do
          [ -z "$poisoned" ] && continue
          if ! git merge-base --is-ancestor "$poisoned" "$target_sha" 2>/dev/null; then
            all_ancestors=false
            break
          fi
        done < "$STATE/poison-latch"
        if $all_ancestors; then
          echo "all latched SHAs are ancestors of $target_sha; clearing poison-latch"
          : > "$STATE/poison-latch"
        fi
      fi

      # Step 6: idempotency.
      recorded_sha=$(awk 'NR==1 {print}' "$STATE/last-deployed-sha" 2>/dev/null || true)
      if [ -n "$recorded_sha" ] && [ "$target_sha" = "$recorded_sha" ]; then
        echo "already at $target_sha; no-op"
        exit 0
      fi

      # Step 7: deploy.
      echo "deploying $target_sha"
      git reset --hard "$target_sha"
      if nixos-rebuild switch --flake ".#${cfg.flakeAttr}"; then
        # Record both the SHA and the resulting toplevel store path.
        # On the next run, if /run/current-system's toplevel doesn't
        # match this recorded path, we know a human touched it.
        new_toplevel=$(readlink -f /run/current-system)
        printf '%s\n%s\n' "$target_sha" "$new_toplevel" > "$STATE/last-deployed-sha"
        touch "$STATE/has-deployed"
        echo "deploy success: $target_sha ($new_toplevel)"
        exit 0
      else
        echo "$target_sha" >> "$STATE/poison-latch"
        echo "deploy FAILED: $target_sha latched as poisoned"
        exit 1
      fi
    '';
  };
in
{
  options.services.nixos-auto-deploy = {
    enable = lib.mkEnableOption "automated NixOS deploy (timer + optional webhook)";

    workingDir = lib.mkOption {
      type = lib.types.path;
      default = "/etc/nixos";
      description = ''
        Local clone of the deploy repo. Must already exist on `branch`,
        owned by root (deploy script writes via `git reset --hard`).
      '';
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Branch to track on origin.";
    };

    flakeAttr = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "nixosConfigurations.<flakeAttr> to switch to.";
    };

    pollInterval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = ''
        systemd OnCalendar expression. With Persistent=true, missed runs
        catch up after suspend/resume or downtime.
      '';
    };

    sshKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        SSH private key for `git fetch`. Required because the working
        dir's origin is git@github.com.
        Typical wiring: `config.age.secrets.deploy-ssh-key.path`.
        If null, falls back to root's ~/.ssh/id_ed25519.
      '';
    };

    webhook = {
      enable = lib.mkEnableOption "GitHub webhook receiver (latency optimization)";

      port = lib.mkOption {
        type = lib.types.port;
        default = 9091;
        description = "Local port the webhook server listens on.";
      };

      secretFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          File containing `WEBHOOK_SECRET=<hex>` (env-format). Loaded
          via systemd `EnvironmentFile`, exposed to the webhook process,
          and templated into the hook's HMAC check at request time.
          Typical: `config.age.secrets.github-webhook-secret.path`.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixos-deploy = {
      description = "NixOS automated deploy from git";
      path = with pkgs; [ git nixos-rebuild util-linux openssh coreutils gnugrep gnused ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${deployScript}/bin/nixos-deploy";
        StateDirectory = "nixos-deploy";
      };
    };

    systemd.timers.nixos-deploy = {
      description = "Hourly poll for new origin/main";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.pollInterval;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # Webhook receiver — adnanh/webhook (pkgs.webhook) via NixOS module.
    # Templates the HMAC secret from $WEBHOOK_SECRET at request time, no
    # secret in /nix/store. Fires `sudo systemctl start nixos-deploy`
    # exactly the same as the timer would.
    services.webhook = lib.mkIf cfg.webhook.enable {
      enable = true;
      enableTemplates = true;
      ip = "127.0.0.1";
      port = cfg.webhook.port;
      hooksTemplated = {
        github-deploy = ''
          {
            "id": "github-deploy",
            "execute-command": "/run/wrappers/bin/sudo",
            "pass-arguments-to-command": [
              { "source": "string", "name": "/run/current-system/sw/bin/systemctl" },
              { "source": "string", "name": "start" },
              { "source": "string", "name": "--no-block" },
              { "source": "string", "name": "nixos-deploy.service" }
            ],
            "trigger-rule": {
              "and": [
                {
                  "match": {
                    "type": "payload-hmac-sha256",
                    "secret": "{{ getenv "WEBHOOK_SECRET" }}",
                    "parameter": { "source": "header", "name": "X-Hub-Signature-256" }
                  }
                },
                {
                  "match": {
                    "type": "value",
                    "value": "refs/heads/${cfg.branch}",
                    "parameter": { "source": "payload", "name": "ref" }
                  }
                }
              ]
            }
          }
        '';
      };
    };

    # EnvironmentFile feeds WEBHOOK_SECRET into the webhook process env so
    # the {{ getenv "WEBHOOK_SECRET" }} template resolves at request time.
    systemd.services.webhook = lib.mkIf cfg.webhook.enable {
      serviceConfig.EnvironmentFile = cfg.webhook.secretFile;
    };

    # Sudoers grant: the `webhook` system user (created by services.webhook)
    # can start nixos-deploy.service NOPASSWD. Pinned to exact argv so the
    # grant doesn't widen.
    security.sudo.extraRules = lib.mkIf cfg.webhook.enable [{
      users = [ "webhook" ];
      commands = [{
        command = "/run/current-system/sw/bin/systemctl start --no-block nixos-deploy.service";
        options = [ "NOPASSWD" ];
      }];
    }];
  };
}
