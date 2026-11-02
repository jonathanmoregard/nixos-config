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
#
# FETCH / APPLY SPLIT (issue #389)
#
# Applying a configuration needs root; downloading one does not. The
# network-facing half (pack negotiation, pack parsing, object writing)
# runs as the `nixos-fetch` system user in its own sandboxed unit,
# `nixos-deploy-fetch.service`, into a bare repo nobody else writes. Root
# keeps every decision: lock, hold, rollback guard, poison latch,
# last-good, notifications, and the switch itself.
#
# The split only buys anything if root does not apply whatever the fetch
# user hands it, so root never reads a ref, a SHA or a checkout from the
# fetch stage. It works like this:
#
#   1. root reads ONE ref from the remote itself (`git ls-remote`,
#      validated as a 40-hex SHA). That SHA is the deploy decision, and it
#      rests on the same thing today's deploy rests on: TLS to the remote.
#   2. root starts the fetch unit and waits for it.
#   3. root imports exactly that SHA from the fetch user's repo into the
#      root-owned working tree's own object store. The upload-pack on the
#      far end of that local transport runs as nixos-fetch (setpriv), so
#      the fetch user's repo and its config are only ever opened by the
#      fetch user. Git's content addressing binds the SHA to the whole
#      tree and history: the fetch user can withhold objects (a failed
#      tick, retried, never poisoned) but cannot change what the SHA
#      names.
#   4. root refuses to build a working tree that any other uid owns or
#      that is group/world-writable.
#
# Rejected: have root trust the fetch stage's branch tip and check it
# with ancestry plus commit signatures. Commits on main are signed only
# by GitHub's web-flow key, which signs ANY web-made commit on GitHub,
# forks included, so a fork commit on top of main would pass both
# checks. A pinned signing key root could verify offline would let root
# skip step 1's network read entirely; none exists today.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.nixos-auto-deploy;
  memoryRunner = config.services.buildCoordination.runnerPackage;

  fetchUser = "nixos-fetch";
  fetchStateDir = "/var/lib/nixos-deploy-fetch";
  # The fetch user's bare repo. Only ever opened by the fetch user.
  stagingRepo = "${fetchStateDir}/source.git";

  # Both halves bound their network op the same way. ssh options only
  # apply to an ssh remote; the production remote is HTTPS.
  gitSshCommand = "ssh -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4${lib.optionalString (cfg.sshKeyFile != null) " -i ${cfg.sshKeyFile} -o IdentitiesOnly=yes"}";

  # Root's side of the import runs this as the "remote" upload-pack. It
  # ignores the path git passes and serves only the pinned staging repo,
  # as the fetch user, with no capabilities, so root's git never opens
  # that repo or reads its config.
  #
  # GIT_PROTOCOL is carried across the env reset on purpose: root's own
  # git sets it (version=2), and v2 is what lets root want a SHA that is
  # not the staging repo's advertised tip. Dropping it (found by the VM
  # lane) falls back to v0, where a hostile or merely raced tip makes the
  # import fail. That fails closed, but it breaks the honest path.
  uploadPackAsFetchUser = pkgs.writeShellScript "nixos-deploy-upload-pack-as-fetch-user" ''
    exec ${pkgs.util-linux}/bin/setpriv \
      --reuid=${fetchUser} --regid=${fetchUser} --clear-groups \
      --no-new-privs --inh-caps=-all --bounding-set=-all --reset-env \
      ${pkgs.coreutils}/bin/env GIT_CONFIG_GLOBAL=/dev/null GIT_PROTOCOL="''${GIT_PROTOCOL:-}" \
      ${pkgs.git}/bin/git-upload-pack --strict --timeout=60 ${stagingRepo}
  '';

  fetchScript = pkgs.writeShellApplication {
    name = "nixos-deploy-fetch";
    runtimeInputs = with pkgs; [ git openssh coreutils ];
    text = ''
      set -euo pipefail
      umask 077
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_TERMINAL_PROMPT=0
      export HOME=${fetchStateDir}
      export GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt
      repo=${stagingRepo}
      if [ ! -e "$repo/HEAD" ]; then
        git init --quiet --bare "$repo"
      fi
      # Bound every network op so a stalled TCP/ssh connection (DNS
      # hang, half-open socket, GitHub blip) ABORTS instead of wedging
      # the deploy forever while root holds the deploy flock. Incident
      # 2026-06-14: a fetch stall left nixos-deploy "activating" for 17h,
      # and every later timer tick hit `flock -n` and silently no-op'd.
      # ConnectTimeout caps the handshake; ServerAlive* tears down a
      # connection that goes silent mid-transfer (3 missed 15s probes ->
      # abort). StrictHostKeyChecking=yes against the pinned github.com
      # keys (programs.ssh.knownHosts below).
      export GIT_SSH_COMMAND=${lib.escapeShellArg gitSshCommand}
      # Belt-and-braces over the keepalives: bound the whole fetch.
      if ! timeout 120 git --git-dir="$repo" fetch --quiet --no-tags \
          ${lib.escapeShellArg cfg.remote} \
          ${lib.escapeShellArg "+refs/heads/${cfg.branch}:refs/heads/${cfg.branch}"}; then
        echo "git fetch failed or timed out (120s)"
        exit 1
      fi
    '';
  };

  rebuildStarter = pkgs.writeShellApplication {
    name = "nixos-deploy-rebuild-starter";
    text = ''
      set -euo pipefail
      marker=$1
      shift
      printf 'started\n' > "$marker"
      exec "$@"
    '';
  };

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
      findutils
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

      # Step 4: decide WHAT to deploy. Root reads the branch's SHA from
      # the remote itself: one ref, no objects, and the only network
      # input root acts on. Everything bulk comes from the fetch stage,
      # which cannot change what this SHA names (see the header).
      # Same bounds as the fetch stage (incident 2026-06-14: an unbounded
      # network op wedged this unit for 17h holding the flock). On
      # failure: release the flock (exit) and let the next tick retry —
      # a transient network blip is NOT a poisoned commit.
      export GIT_SSH_COMMAND=${lib.escapeShellArg gitSshCommand}
      export GIT_TERMINAL_PROMPT=0
      if ! ls_remote=$(timeout 60 git ls-remote --exit-code \
          ${lib.escapeShellArg cfg.remote} ${lib.escapeShellArg "refs/heads/${cfg.branch}"}); then
        echo "git ls-remote failed or timed out (60s); releasing lock, will retry next tick"
        exit 1
      fi
      target_sha=$(printf '%s\n' "$ls_remote" | awk -v ref=${lib.escapeShellArg "refs/heads/${cfg.branch}"} '$2 == ref {print $1}')
      if ! printf '%s' "$target_sha" | grep -qxE '[0-9a-f]{40}'; then
        echo "git ls-remote returned no usable SHA for ${cfg.branch}: ''${ls_remote@Q}; will retry next tick"
        exit 1
      fi

      # Step 5a: exact poison match needs no objects; skip before fetching.
      if grep -qFx "$target_sha" "$STATE/poison-latch"; then
        echo "$target_sha is poisoned; skipping"
        exit 0
      fi

      # Step 5b: the unprivileged fetch stage downloads the objects.
      if ! ${config.systemd.package}/bin/systemctl start nixos-deploy-fetch.service; then
        echo "fetch stage failed (nixos-deploy-fetch.service); releasing lock, will retry next tick"
        exit 1
      fi

      # Step 5c: import exactly target_sha from the fetch stage into this
      # root-owned repo. The upload-pack end runs as ${fetchUser}; the lock
      # fd is closed for it so it cannot hold or grow the lock file.
      # fsckObjects rejects malformed objects (e.g. `.git` tree entries)
      # before they land. A missing object is a retry, not a poisoned SHA.
      if ! git -c fetch.fsckObjects=true -c protocol.version=2 \
          fetch --quiet --no-tags --no-write-fetch-head \
          --upload-pack=${uploadPackAsFetchUser} \
          "file://${stagingRepo}" "+$target_sha:refs/nixos-deploy/incoming" \
          {lock_fd}>&-; then
        echo "import of $target_sha from the fetch stage failed; releasing lock, will retry next tick"
        exit 1
      fi
      if [ "$(git rev-parse --verify --quiet 'refs/nixos-deploy/incoming^{commit}')" != "$target_sha" ]; then
        echo "imported ref does not name $target_sha; refusing, will retry next tick"
        exit 1
      fi
      # Keep `git log origin/${cfg.branch}` in this tree truthful for humans.
      git update-ref "refs/remotes/origin/${cfg.branch}" "$target_sha"

      # Step 5d: poison-latch auto-clear (needs the imported history).
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

      # Step 7: deploy — but only from a tree no other uid can modify.
      # Checked, not assumed: if anything in the working tree (or a
      # directory above it) is owned by a non-root uid or is group/world
      # writable, that uid could change what root evaluates between this
      # reset and the build. Not the commit's fault, so no poison.
      foreign=$(find "$PWD" -xdev \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print -quit)
      dir=$PWD
      while [ -z "$foreign" ] && [ "$dir" != / ]; do
        dir=$(dirname "$dir")
        if [ "$(stat -c %u "$dir")" != 0 ] || [ $((8#$(stat -c %a "$dir") & 8#022)) -ne 0 ]; then
          foreign=$dir
        fi
      done
      if [ -n "$foreign" ]; then
        echo "refusing to build $target_sha: $foreign is owned by a non-root uid or group/world-writable"
        echo "  fix ownership/modes under $PWD (expected root-owned, no g/o write); next tick retries"
        exit 1
      fi
      echo "deploying $target_sha"
      git reset --hard "$target_sha"
      rebuild_marker=$(mktemp "$STATE/rebuild-started.XXXXXX")
      trap 'rm -f "$rebuild_marker"' EXIT
      set +e
      ${memoryRunner}/bin/nix-memory-run --nonblock -- \
        ${rebuildStarter}/bin/nixos-deploy-rebuild-starter "$rebuild_marker" \
        nixos-rebuild switch --flake ".#${cfg.flakeAttr}"
      deploy_rc=$?
      set -e
      rebuild_started=0
      if [ -s "$rebuild_marker" ]; then
        rebuild_started=1
      fi
      if [ "$deploy_rc" -eq 0 ]; then
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
      elif [ "$deploy_rc" -eq 75 ] && [ "$rebuild_started" -eq 0 ]; then
        echo "deploy deferred: another memory-heavy job is active"
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
        Local clone of the deploy repo that root builds from. Must
        already exist as a git repo, entirely root-owned with no
        group/world write: the deploy refuses to build it otherwise.
        Never fetched into from the network; root imports the target
        commit from the unprivileged fetch stage.
      '';
    };

    remote = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/jonathanmoregard/nixos-config.git";
      description = ''
        Git remote both halves read: root resolves `branch` here
        (`git ls-remote`, one ref), the fetch user downloads objects
        from it. Store-pinned, so nothing on the host can repoint it.
        HTTPS needs no credential because the repo is public.
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
        SSH private key, used only when `remote` is an ssh URL (the
        default HTTPS remote ignores it). Both halves pass it to ssh, so
        for an ssh remote it must be readable by the `nixos-fetch` user
        as well as root; a root-only key makes the fetch stage fail
        loudly rather than fall back to anything.
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
    assertions = [{
      assertion = config.services.buildCoordination.enable;
      message = "services.nixos-auto-deploy requires services.buildCoordination.enable";
    }];

    # GitHub's published SSH host keys
    # (docs.github.com "GitHub's SSH key fingerprints"). Written to
    # /etc/ssh/ssh_known_hosts, which root's deploy fetch checks with
    # StrictHostKeyChecking=yes. If GitHub rotates a key, the fetch fails
    # loudly; update the key here.
    programs.ssh.knownHosts = {
      github-ed25519 = {
        hostNames = [ "github.com" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
      };
      github-ecdsa = {
        hostNames = [ "github.com" ];
        publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
      };
      github-rsa = {
        hostNames = [ "github.com" ];
        publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=";
      };
    };

    systemd.services.nixos-deploy = {
      description = "NixOS automated deploy from git";
      # The service runs switch-to-configuration itself. Restarting it because
      # its candidate unit changed kills the parent deploy before bookkeeping
      # can record success, then a timer retry collides with the still-running
      # transient switch unit. Let this invocation finish; daemon-reload still
      # installs the candidate unit for the next timer or webhook run.
      restartIfChanged = false;
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

    # The network half. Same shape as claude-runtime-deploy's
    # claude-deploy user: a system user with no home, owning only its own
    # state. It can write nothing root builds from (DAC: /etc/nixos is
    # root-owned; sandbox: ProtectSystem=strict besides).
    users.groups.${fetchUser} = { };
    users.users.${fetchUser} = {
      isSystemUser = true;
      group = fetchUser;
      home = "/var/empty";
    };

    # No timer and no wantedBy: only nixos-deploy starts this, while
    # holding its lock, after it has decided which SHA it wants.
    systemd.services.nixos-deploy-fetch = {
      description = "nixos-deploy fetch stage (unprivileged)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = fetchUser;
        Group = fetchUser;
        ExecStart = "${fetchScript}/bin/nixos-deploy-fetch";
        StateDirectory = "nixos-deploy-fetch";
        StateDirectoryMode = "0700";
        # The in-script fetch is bounded at 120s; this backstops the rest.
        TimeoutStartSec = 300;
        Nice = 10;
        IOSchedulingClass = "idle";

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        MemoryMax = "1G";
        TasksMax = 64;
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

    # Public ingress for the webhook: Tailscale Funnel on the webhook port,
    # so GitHub reaches https://<host>.<tailnet>.ts.net/hooks/github-deploy.
    # Previously set once by hand (scripts/install.sh phase 6), which left
    # a new host (tuxedo) with a listening webhook nobody could reach —
    # deploys fell back to the hourly timer. Serve config persists in
    # tailscaled state; re-applying it each boot is idempotent.
    #
    # Waits out tailscaled startup. A host that was never
    # `tailscale up`'d (VM, fresh install) is skipped, not failed: there is
    # no ingress to configure until a human authenticates the node.
    systemd.services.nixos-deploy-funnel = lib.mkIf (cfg.webhook.enable && config.services.tailscale.enable) {
      description = "Tailscale Funnel ingress for the deploy webhook";
      after = [ "tailscaled.service" "network-online.target" ];
      wants = [ "tailscaled.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ config.services.tailscale.package pkgs.jq pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "6min";
      };
      script = ''
        state=""
        for _ in $(seq 60); do
          state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)
          # Only the transient startup states are worth waiting on;
          # NeedsLogin/Stopped won't change without a human.
          case "$state" in
            ""|NoState|Starting) sleep 5 ;;
            *) break ;;
          esac
        done
        if [ "$state" != Running ]; then
          echo "tailscale not running (state: ''${state:-unknown}); skipping funnel"
          exit 0
        fi
        tailscale funnel --bg ${toString cfg.webhook.port}
        tailscale funnel status
      '';
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
