# Direct smarthome application delivery. The host pulls one merged Git commit,
# evaluates only its package outPath with builders disabled, hydrates the
# signed closure, then delegates profile switching/rollback to the activator.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.smarthome-auto-deploy;
  stateDir = "/var/lib/smarthome-deploy";
  runtimeDir = "/run/smarthome-deploy";

  defaultHydrator = pkgs.writeShellApplication {
    name = "smarthome-hydrate-release-paths";
    runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.jq config.nix.package ];
    text = ''exec ${./smarthome-hydrate-release-paths.sh} "$@"'';
  };

  defaultActivator = pkgs.writeShellApplication {
    name = "smarthome-activate-package";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.systemd
      config.nix.package
    ];
    text = ''exec ${./smarthome-activate-package.sh} "$@"'';
  };

  serviceArg = if cfg.serviceName == null then "-" else cfg.serviceName;
  healthArg = if cfg.healthUrl == null then "-" else cfg.healthUrl;
  gitSshCommand =
    "${pkgs.openssh}/bin/ssh -i ${lib.escapeShellArg cfg.deployKeyFile}"
    + " -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o BatchMode=yes"
    + " -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o ConnectTimeout=15";

  deployProgram = pkgs.writeShellApplication {
    name = "smarthome-deploy";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.git
      pkgs.openssh
      pkgs.util-linux
      cfg.nixPackage
    ];
    text = ''
      set -f
      umask 077

      key=${lib.escapeShellArg cfg.deployKeyFile}
      source=${lib.escapeShellArg cfg.sourceDir}
      repo=${lib.escapeShellArg cfg.repoUrl}
      branch=${lib.escapeShellArg cfg.branch}
      profile=${lib.escapeShellArg cfg.profile}
      package_attr=${lib.escapeShellArg cfg.packageAttr}
      cache_url=${lib.escapeShellArg cfg.cache.url}
      cache_key=${lib.escapeShellArg cfg.cache.publicKey}
      state="''${STATE_DIRECTORY:-${stateDir}}"
      runtime="''${RUNTIME_DIRECTORY:-${runtimeDir}}"
      lock="$runtime/deploy.lock"
      new=

      die() {
        printf 'smarthome-deploy:' >&2
        printf ' %s' "$@" >&2
        printf '\n' >&2
        exit 1
      }

      record_pre_activation_failure() {
        local attempted_path=$1 reason=$2 previous_path marker
        previous_path=$(readlink -f "$profile" 2>/dev/null || printf 'none')
        marker=$(mktemp "$state/.last-failure.XXXXXXXX") || return 1
        if ! printf 'rev=%s\npath=%s\nprevious_path=%s\nreason=%s\nrollback=not-started\n' \
          "$new" "$attempted_path" "$previous_path" "$reason" > "$marker" || \
           ! chmod 0600 "$marker" || \
           ! mv -f -- "$marker" "$state/last-failure"; then
          rm -f -- "$marker"
          return 1
        fi
      }

      [ -d "$state" ] || die "state directory is unavailable: $state"
      [ -d "$runtime" ] || die "runtime directory is unavailable: $runtime"
      exec {deploy_lock_fd}>"$lock"
      flock --exclusive "$deploy_lock_fd"
      # ProtectHome hides /root. Give Git/Nix a private writable cache root in
      # StateDirectory without exposing any credential through unit env.
      export HOME="$state"
      export XDG_CACHE_HOME="$state/cache"
      mkdir -p -- "$XDG_CACHE_HOME"

      [ -e "$key" ] || die "deploy key is missing: $key"
      key_mode=$(stat -L -c '%a' "$key")
      [ "$key_mode" = 400 ] || die "deploy key has mode $key_mode; expected mode 400"
      expected_uid=$(id -u)
      key_uid=$(stat -L -c '%u' "$key")
      [ "$key_uid" = "$expected_uid" ] || \
        die "deploy key has uid $key_uid; expected uid $expected_uid"

      export GIT_SSH_COMMAND=${lib.escapeShellArg gitSshCommand}
      export GIT_TERMINAL_PROMPT=0

      if [ ! -d "$source/.git" ]; then
        mkdir -p -- "$source"
        git -C "$source" init -q
        git -C "$source" remote add origin "$repo"
      else
        git -C "$source" remote set-url origin "$repo"
      fi
      git -C "$source" fetch --depth=1 --prune origin \
        "+refs/heads/$branch:refs/remotes/origin/$branch"
      new=$(git -C "$source" rev-parse "refs/remotes/origin/$branch")
      [[ "$new" =~ ^[0-9a-f]{40}$ ]] || die 'fetched revision is not a full commit id'
      git -C "$source" reset --hard "refs/remotes/origin/$branch" > /dev/null
      git -C "$source" reflog expire --expire=now --all
      git -C "$source" gc --prune=now

      deployed_revision=
      deployed_path=
      if [ -s "$state/last-success" ]; then
        while IFS='=' read -r marker_key marker_value; do
          case "$marker_key" in
            rev) deployed_revision=$marker_value ;;
            path) deployed_path=$marker_value ;;
          esac
        done < "$state/last-success"
      fi

      if [ "$deployed_revision" = "$new" ]; then
        active_path=$(readlink -f "$profile" 2>/dev/null || true)
        if [ -n "$deployed_path" ] && [ "$active_path" = "$deployed_path" ]; then
          printf 'smarthome-deploy: already deployed %s at %s\n' "$new" "$active_path"
          exit 0
        fi
        die 'rollback in effect; refusing to clobber'
      fi

      package_path="$(${lib.getExe cfg.nixPackage} eval --raw \
        --option max-jobs 0 \
        --option fallback false \
        --option builders "" \
        "$source#$package_attr.outPath")" || {
          record_pre_activation_failure invalid 'package path evaluation failed' || true
          die 'could not evaluate release package path'
        }
      [[ "$package_path" =~ ^${builtins.storeDir}/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]{1,211}$ ]] || {
        record_pre_activation_failure invalid 'evaluated package path is invalid' || true
        die "invalid evaluated package path: $package_path"
      }

      if ! ${lib.getExe cfg.hydratorPackage} \
        --from "$cache_url" \
        --trusted-key "$cache_key" \
        --timeout-seconds 300 \
        --interval 5 \
        "$package_path"; then
        record_pre_activation_failure "$package_path" 'release hydration failed' || true
        die 'release hydration failed'
      fi

      ${lib.getExe cfg.activatorPackage} \
        "$package_path" \
        "$new" \
        "$state" \
        "$profile" \
        ${lib.escapeShellArg serviceArg} \
        ${lib.escapeShellArg healthArg}
      printf 'smarthome-deploy: deployed %s at %s\n' "$new" "$package_path"
    '';
  };

  failureProgram = pkgs.writeShellScript "smarthome-deploy-failed" ''
    echo 'smarthome-deploy failed; application release unchanged or rolled back.' >&2
    echo 'Inspect: journalctl -u smarthome-deploy -n 200' >&2
    if [ -f ${stateDir}/last-failure ]; then
      ${pkgs.coreutils}/bin/cat ${stateDir}/last-failure >&2
    fi
  '';
in
{
  options.services.smarthome-auto-deploy = {
    enable = lib.mkEnableOption "direct cached smarthome application deployment";

    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "git@github.com:jonathanmoregard/smarthome.git";
      description = "Git repository whose merged branch defines releases.";
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Git branch to poll.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "Delay between completed poll runs.";
    };

    sourceDir = lib.mkOption {
      type = lib.types.str;
      default = "${stateDir}/source";
      description = "Machine-owned shallow checkout.";
    };

    profile = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var/nix/profiles/smarthome";
      description = "Dedicated application profile.";
    };

    packageAttr = lib.mkOption {
      type = lib.types.str;
      default = "packages.x86_64-linux.default";
      description = "Flake package attribute whose outPath is deployed.";
    };

    deployKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Absolute runtime path to a root-owned mode-0400 GitHub deploy key.";
    };

    serviceName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Service restarted after profile activation, or null.";
    };

    healthUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Health URL paired with serviceName, or null.";
    };

    cache = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://jonathanmoregard.cachix.org";
        description = "Signed binary cache containing application releases.";
      };
      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "jonathanmoregard.cachix.org-1:Qzksr/c2ciAaV4j/U2mGFd1HTgOAicks8gJNs1Ztxo8=";
        description = "Exact cache signing public key.";
      };
    };

    nixPackage = lib.mkOption {
      type = lib.types.package;
      default = config.nix.package;
      internal = true;
    };
    hydratorPackage = lib.mkOption {
      type = lib.types.package;
      default = defaultHydrator;
      internal = true;
    };
    activatorPackage = lib.mkOption {
      type = lib.types.package;
      default = defaultActivator;
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.deployKeyFile && !(lib.hasInfix "\n" cfg.deployKeyFile);
        message = "services.smarthome-auto-deploy.deployKeyFile must be an absolute single-line runtime path";
      }
      {
        assertion = lib.hasPrefix "/" cfg.sourceDir && !(lib.hasInfix "\n" cfg.sourceDir);
        message = "services.smarthome-auto-deploy.sourceDir must be an absolute single-line path";
      }
      {
        assertion = lib.hasPrefix "/" cfg.profile && !(lib.hasInfix "\n" cfg.profile);
        message = "services.smarthome-auto-deploy.profile must be an absolute single-line path";
      }
      {
        assertion = builtins.match "[A-Za-z0-9._/-]+" cfg.branch != null;
        message = "services.smarthome-auto-deploy.branch contains unsupported characters";
      }
      {
        assertion = builtins.match "[A-Za-z0-9._-]+(\\.[A-Za-z0-9._-]+)*" cfg.packageAttr != null;
        message = "services.smarthome-auto-deploy.packageAttr must be a dotted attribute path";
      }
      {
        assertion = (cfg.serviceName == null) == (cfg.healthUrl == null);
        message = "services.smarthome-auto-deploy.serviceName and healthUrl must be set together";
      }
    ];

    programs.ssh.knownHosts = {
      "github.com-ed25519" = {
        hostNames = [ "github.com" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
      };
      "github.com-rsa" = {
        hostNames = [ "github.com" ];
        publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=";
      };
      "github.com-ecdsa" = {
        hostNames = [ "github.com" ];
        publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
      };
    };

    systemd.timers.smarthome-deploy = {
      description = "Poll ${cfg.branch} for a smarthome application release";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.interval;
        RandomizedDelaySec = "30s";
        Persistent = true;
        Unit = "smarthome-deploy.service";
      };
    };

    systemd.services.smarthome-deploy = {
      description = "Pull and activate a signed smarthome release";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      onFailure = [ "smarthome-deploy-failed.service" ];
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe deployProgram;
        User = "root";
        Group = "root";
        StateDirectory = "smarthome-deploy";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "smarthome-deploy";
        RuntimeDirectoryMode = "0700";
        TimeoutStartSec = "infinity";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ReadWritePaths = [ stateDir (builtins.dirOf cfg.profile) ];
      };
    };

    systemd.services.smarthome-deploy-failed = {
      description = "Report failed smarthome application deployment";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = failureProgram;
        SyslogIdentifier = "smarthome-deploy";
        SyslogLevel = "err";
      };
    };
  };
}
