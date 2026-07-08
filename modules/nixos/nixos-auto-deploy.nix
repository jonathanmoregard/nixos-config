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
# - Respects rollbacks: if the active system profile generation is older
#   than the newest known generation, the service halts. Cleared by
#   running `nixos-rebuild switch` forward (advances the profile to a
#   new latest, drift gone, auto-deploy resumes on next tick).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.nixos-auto-deploy;

  deployScript = pkgs.writeShellApplication {
    name = "nixos-deploy";
    runtimeInputs = with pkgs; [
      git
      nix
      nixos-rebuild
      util-linux
      openssh
      coreutils
      gnugrep
      gnused
      gawk
    ];
    text = ''
      set -euo pipefail
      STATE=/var/lib/nixos-deploy
      mkdir -p "$STATE"
      touch "$STATE/poison-latch"

      exec {lock_fd}>"$STATE/lock"
      flock -n "$lock_fd" || { echo "another run in progress; exiting"; exit 0; }

      # One-shot migration: the pull-based rewrite (4ad9306, 2026-05-06)
      # renamed the previous module's `last-good` state file to
      # `last-deployed-sha`, orphaning the on-disk `last-good` the docs
      # advertise — it froze at the old module's final deploy while
      # deploys kept succeeding. The record lives at `last-good` again;
      # carry a pre-rename value forward (clobbering the frozen copy)
      # so the first post-fix tick stays a no-op, and remove the old
      # name so no second stale file is left behind.
      if [ -e "$STATE/last-deployed-sha" ]; then
        mv "$STATE/last-deployed-sha" "$STATE/last-good"
      fi

      if [ -e "$STATE/manual-hold" ]; then
        echo "manual-hold present; halting"
        echo "  to clear: sudo rm $STATE/manual-hold"
        exit 1
      fi

      # Rollback guard: respect explicit user rollbacks.
      #
      # When the user runs `nixos-rebuild switch --rollback` (or
      # `nix-env --switch-generation N`), the system profile symlink
      # points at gen N-1 even though gen N still exists. That's the
      # canonical "I want to stay on this older generation" signal.
      # Auto-deploy must not clobber it by re-applying origin/main.
      #
      # nix-env --list-generations marks the active generation with
      # "(current)"; the highest-numbered line is the newest. If active
      # < latest, the user pinned an older gen — halt.
      #
      # The previous design compared /run/current-system store-hash to
      # a recorded toplevel path; that fired on any local rebuild,
      # including identical-source rebuilds that just happened to
      # produce a different drv hash, and required manual state-file
      # deletion to recover. Generation comparison is what Nix already
      # uses to model rollback, so the check costs nothing extra.
      #
      # Resume path: `sudo nixos-rebuild switch` forward — that
      # advances the profile to a new latest, active==latest again,
      # auto-deploy proceeds on the next tick.
      gens=$(nix-env --list-generations -p /nix/var/nix/profiles/system)
      active_gen=$(echo "$gens" | awk '/\(current\)/ {print $1}')
      latest_gen=$(echo "$gens" | awk 'END {print $1}')
      if [ -n "$active_gen" ] && [ -n "$latest_gen" ] && [ "$active_gen" -lt "$latest_gen" ]; then
        echo "active system generation $active_gen < latest $latest_gen; halting"
        echo "  (rollback in effect; refusing to clobber)"
        echo "  to resume: sudo nixos-rebuild switch"
        exit 0
      fi

      # Idempotency input: SHA of the last successfully-deployed commit.
      recorded_sha=""
      { IFS= read -r recorded_sha || true; } < "$STATE/last-good" 2>/dev/null || true

      cd "${cfg.workingDir}"
      # Bound every network op so a stalled TCP/ssh connection (DNS
      # hang, half-open socket, GitHub blip) ABORTS instead of wedging
      # the deploy forever while holding the flock. Incident 2026-06-14:
      # a fetch stall left nixos-deploy "activating" for 17h, and every
      # later timer tick hit `flock -n` and silently no-op'd, so merged
      # PRs never reached the host. ConnectTimeout caps the handshake;
      # ServerAlive* tears down a connection that goes silent
      # mid-transfer (3 missed 15s probes -> abort).
      export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4${lib.optionalString (cfg.sshKeyFile != null) " -i ${cfg.sshKeyFile} -o IdentitiesOnly=yes"}"
      # Belt-and-braces over the ssh keepalives: bound the whole fetch
      # so a connected-but-stalled upload-pack still can't run unbounded.
      # On failure: release the flock (exit) and let the next timer tick
      # retry — a transient network blip is NOT a poisoned commit, so we
      # must not fall through to the poison-latch path below.
      if ! timeout 120 git fetch --quiet origin "${cfg.branch}"; then
        echo "git fetch failed or timed out (120s); releasing lock, will retry next tick"
        exit 1
      fi
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

      # Step 6: idempotency. recorded_sha was read at the top of the script.
      if [ -n "$recorded_sha" ] && [ "$target_sha" = "$recorded_sha" ]; then
        echo "already at $target_sha; no-op"
        exit 0
      fi

      # Step 7: deploy.
      echo "deploying $target_sha"
      git reset --hard "$target_sha"
      if nixos-rebuild switch --flake ".#${cfg.flakeAttr}"; then
        # Record the deployed SHA in `last-good` — both the idempotency
        # input for the next tick AND the operator-facing "what's on the
        # box" record documented in CLAUDE.md's Deploy workflow. The
        # generation comparison above is what catches a human-driven
        # rollback — toplevel-hash tracking is no longer needed.
        printf '%s\n' "$target_sha" > "$STATE/last-good"
        touch "$STATE/has-deployed"
        # Trigger desktop notification (path-watcher in user systemd
        # picks this up; notify-send in the user service).
        touch "$STATE/notify-success"
        echo "deploy success: $target_sha"
        exit 0
      else
        echo "$target_sha" >> "$STATE/poison-latch"
        touch "$STATE/notify-failure"
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

    notifyUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "jonathan";
      description = ''
        Username whose session bus receives `notify-send` calls on
        deploy success/failure. The user gets `linger` enabled so the
        notification path-watcher works even when the desktop session
        hasn't been opened yet (e.g. immediately after boot, before
        first login). Set null to disable notifications entirely.
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
        # Hard backstop independent of the in-script `timeout` on the
        # fetch: bounds the ENTIRE run, so a hang anywhere downstream
        # (a `nixos-rebuild switch` wedged on an unreachable substituter,
        # say) can't hold the deploy lock indefinitely the way the
        # 2026-06-14 fetch stall did (17h "activating"). 60min
        # comfortably exceeds any real cached/semi-cached switch; a
        # truly cold full rebuild that needs longer is retried on the
        # next timer tick (more in cache by then).
        #
        # Conscious tradeoff (the alternative — no backstop — reopens the
        # unbounded-wedge hole for every non-fetch hang): on expiry
        # systemd SIGTERMs then SIGKILLs the run. Almost always that
        # lands in the long build phase (harmless — no system change).
        # The narrow risk is a cold build that burns ~59min then gets
        # killed mid `switch-to-configuration`, leaving a half-applied
        # generation. That is recoverable, not bricking:
        # switch-to-configuration is re-entrant, last-good is
        # only written on SUCCESS, so the next tick re-runs switch to the
        # SAME target_sha and re-converges. Net: bounded-wedge +
        # self-healing beats unbounded-wedge.
        TimeoutStartSec = "60min";
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
    security.sudo.extraRules = lib.optional cfg.webhook.enable {
      users = [ "webhook" ];
      commands = [{
        command = "/run/current-system/sw/bin/systemctl start --no-block nixos-deploy.service";
        options = [ "NOPASSWD" ];
      }];
    };

    # Linger so the notification user-bus is alive at boot, before any
    # graphical login — otherwise the very first deploy after a reboot
    # has no D-Bus session to send to.
    users.users.${cfg.notifyUser}.linger = lib.mkIf (cfg.notifyUser != null) true;

    # User-bus notification chain. PathChanged fires once per deploy on
    # close-after-write (the deploy script's `touch`), so the flag file
    # can persist between runs without retriggering. PathExists would
    # busy-loop while the file exists.
    systemd.user.paths = lib.mkIf (cfg.notifyUser != null) {
      nixos-deploy-notify-success = {
        wantedBy = [ "default.target" ];
        pathConfig.PathChanged = "/var/lib/nixos-deploy/notify-success";
      };
      nixos-deploy-notify-failure = {
        wantedBy = [ "default.target" ];
        pathConfig.PathChanged = "/var/lib/nixos-deploy/notify-failure";
      };
    };

    systemd.user.services = lib.mkIf (cfg.notifyUser != null) {
      nixos-deploy-notify-success = {
        description = "Desktop notification: nixos-deploy success";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "deploy-notify-success" ''
            set -e
            SHA=$(${pkgs.coreutils}/bin/head -1 /var/lib/nixos-deploy/last-good 2>/dev/null || echo unknown)
            ${pkgs.libnotify}/bin/notify-send -u low "nixos-deploy" "Applied $SHA"
          '';
        };
      };
      nixos-deploy-notify-failure = {
        description = "Desktop notification: nixos-deploy failure";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "deploy-notify-failure" ''
            set -e
            SHA=$(${pkgs.coreutils}/bin/tail -1 /var/lib/nixos-deploy/poison-latch 2>/dev/null || echo unknown)
            ${pkgs.libnotify}/bin/notify-send -u critical "nixos-deploy FAILED" \
              "Commit $SHA failed activation. Recovery: sudo nixos-rebuild switch --rollback"
          '';
        };
      };
    };
  };
}
