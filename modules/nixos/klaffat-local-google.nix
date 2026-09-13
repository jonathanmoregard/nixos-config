# Local Klaffat development server with real Google Calendar OAuth.
#
# The user-facing launcher never reads OAuth credentials. Root decrypts the
# existing agenix-compatible ciphertext during ExecStartPre, extracts only the
# Google client pair, and systemd gives those values to a dedicated service
# account. See docs/superpowers/specs/2026-09-12-klaffat-local-google-capability-design.md.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.klaffatLocalGoogle;
  serviceName = "klaffat-local-google";
  serviceUser = serviceName;
  runtimeDir = "/run/${serviceName}";
  preparedDir = "${runtimeDir}/prepared";
  stateDir = "/var/lib/${serviceName}";
  databaseName = serviceName;
  expectedBinary = "target/local-google/debug/klaffat";
  expectedStatic = "crates/klaffat-web/static";
  expectedKek = "tests/e2e/fixtures/test-kek";
  endpointOverrideNames = [
    "KLAFFAT_GOOGLE_AUTH_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_TOKEN_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_JWKS_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_FREEBUSY_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_EVENTS_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_REVOKE_URL_OVERRIDE"
    "KLAFFAT_MS_AUTH_URL_OVERRIDE"
    "KLAFFAT_MS_TOKEN_URL_OVERRIDE"
    "KLAFFAT_MS_JWKS_URL_OVERRIDE"
    "KLAFFAT_MS_EVENTS_URL_OVERRIDE"
    "KLAFFAT_MS_FREEBUSY_URL_OVERRIDE"
    "KLAFFAT_MS_CALENDAR_VIEW_URL_OVERRIDE"
  ];

  acceptedOriginPatterns = lib.concatStringsSep "|" (
    map lib.escapeShellArg cfg.acceptedOrigins
  );

  buildKlaffat = pkgs.writeShellApplication {
    name = "klaffat-local-google-build";
    runtimeInputs = [ pkgs.coreutils pkgs.nix ];
    text = ''
      set -euo pipefail
      if [ "$#" -ne 1 ]; then
        echo "klaffat-local-google-build: expected one worktree path" >&2
        exit 2
      fi
      worktree=$1
      cd "$worktree"
      export CARGO_TARGET_DIR="$worktree/target/local-google"
      exec nix develop --command cargo build -p klaffat-web --features test-endpoints
    '';
  };

  extractGoogleEnvironment = pkgs.writeText "extract-klaffat-google-environment.py" ''
    import pathlib
    import re
    import sys

    allowed = {
        "KLAFFAT_GOOGLE_CLIENT_ID",
        "KLAFFAT_GOOGLE_CLIENT_SECRET",
    }
    values = {}
    assignment = re.compile(r"^(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
    safe_value = re.compile(r"^[A-Za-z0-9._~+:/=-]+$")

    try:
        source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
        destination = pathlib.Path(sys.argv[2])
    except (OSError, UnicodeError, IndexError):
        raise SystemExit("Google OAuth environment could not be read")

    for raw_line in source.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = assignment.fullmatch(line)
        if match is None or match.group(1) not in allowed:
            continue
        name, value = match.groups()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if name in values:
            raise SystemExit(f"duplicate {name} assignment")
        if not value or safe_value.fullmatch(value) is None:
            raise SystemExit(f"invalid {name} assignment")
        values[name] = value

    missing = sorted(allowed - values.keys())
    if missing:
        raise SystemExit("missing required Google OAuth assignment")

    try:
        with destination.open("w", encoding="ascii", newline="\n") as output:
            for name in sorted(allowed):
                output.write(f"{name}={values[name]}\n")
    except OSError:
        raise SystemExit("Google OAuth environment could not be written")
  '';

  prepare = pkgs.writeShellApplication {
    name = "klaffat-local-google-prepare";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.python3 ];
    text = ''
      set -euo pipefail
      umask 077

      refuse() {
        echo "klaffat-local-google: $1 — refusing" >&2
        exit 2
      }

      cleanup() {
        if [ -n "''${plaintext:-}" ]; then
          rm -f -- "$plaintext"
        fi
        if [ -n "''${environment_tmp:-}" ]; then
          rm -f -- "$environment_tmp"
        fi
      }
      trap cleanup EXIT

      # Never let a failed restart leave the previous credential file as an
      # apparently current artifact.
      rm -f -- ${lib.escapeShellArg "${runtimeDir}/google.env"}

      selector=${lib.escapeShellArg cfg.selectionFile}
      [ -f "$selector" ] && [ ! -L "$selector" ] \
        || refuse "selection file is missing or not a regular file"
      mapfile -t selections < "$selector"
      [ "''${#selections[@]}" -eq 1 ] && [ -n "''${selections[0]}" ] \
        || refuse "selection file must contain exactly one path"

      worktree=$(readlink -e -- "''${selections[0]}") \
        || refuse "selected worktree does not exist"
      worktree_root=$(readlink -e -- ${lib.escapeShellArg cfg.worktreeRoot}) \
        || refuse "configured worktree root does not exist"
      relative="''${worktree#"$worktree_root"/}"
      case "$worktree" in
        "$worktree_root"/klaffat-*) ;;
        *) refuse "selected path is outside the Klaffat worktree root" ;;
      esac
      [[ "$relative" != */* ]] \
        || refuse "selected worktree must be an immediate child of the worktree root"

      binary="$worktree/${expectedBinary}"
      static="$worktree/${expectedStatic}"
      kek="$worktree/${expectedKek}"
      encrypted="$worktree/${cfg.encryptedEnvironmentRelativePath}"

      [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] \
        || refuse "the expected Klaffat binary is missing, linked, or not executable"
      [ "$(stat -c %U -- "$binary")" = ${lib.escapeShellArg cfg.operator} ] \
        || refuse "the Klaffat binary is not owned by ${cfg.operator}"
      [ -d "$static" ] && [ ! -L "$static" ] \
        || refuse "the Klaffat static directory is missing or linked"
      if find -H "$static" -mindepth 1 \
          \( -type l -o \( ! -type f -a ! -type d \) \) -print -quit \
          | grep -q .; then
        refuse "the Klaffat static directory contains a link or special file"
      fi
      [ -f "$kek" ] && [ ! -L "$kek" ] \
        || refuse "the Klaffat development KEK is missing or linked"
      [ -f "$encrypted" ] && [ ! -L "$encrypted" ] \
        || refuse "the encrypted Klaffat environment is missing or linked"
      [ -r ${lib.escapeShellArg cfg.identityFile} ] \
        || refuse "the host age identity is unavailable"

      rm -rf -- ${lib.escapeShellArg preparedDir}
      install -d -m 0555 -o root -g root ${lib.escapeShellArg preparedDir}
      cp --no-dereference --preserve=mode,ownership -- "$binary" \
        ${lib.escapeShellArg "${preparedDir}/klaffat"}
      [ -f ${lib.escapeShellArg "${preparedDir}/klaffat"} ] \
        && [ ! -L ${lib.escapeShellArg "${preparedDir}/klaffat"} ] \
        && [ "$(stat -c %U -- ${lib.escapeShellArg "${preparedDir}/klaffat"})" = ${lib.escapeShellArg cfg.operator} ] \
        || refuse "the copied Klaffat binary changed type or owner during preparation"
      chown root:root ${lib.escapeShellArg "${preparedDir}/klaffat"}
      chmod 0555 ${lib.escapeShellArg "${preparedDir}/klaffat"}
      cp -a --no-preserve=ownership -- "$static" ${lib.escapeShellArg "${preparedDir}/static"}
      if find -H ${lib.escapeShellArg "${preparedDir}/static"} -mindepth 1 \
          \( -type l -o \( ! -type f -a ! -type d \) \) -print -quit \
          | grep -q .; then
        refuse "the prepared static directory contains a link or special file"
      fi
      chown -R root:root ${lib.escapeShellArg "${preparedDir}/static"}
      find ${lib.escapeShellArg "${preparedDir}/static"} -type d -exec chmod 0555 {} +
      find ${lib.escapeShellArg "${preparedDir}/static"} -type f -exec chmod 0444 {} +
      cp --no-dereference --preserve=mode,ownership -- "$kek" \
        ${lib.escapeShellArg "${preparedDir}/kek"}
      [ -f ${lib.escapeShellArg "${preparedDir}/kek"} ] \
        && [ ! -L ${lib.escapeShellArg "${preparedDir}/kek"} ] \
        || refuse "the copied Klaffat development KEK changed type during preparation"
      chown ${lib.escapeShellArg serviceUser}:${lib.escapeShellArg serviceUser} \
        ${lib.escapeShellArg "${preparedDir}/kek"}
      chmod 0400 ${lib.escapeShellArg "${preparedDir}/kek"}

      encrypted_copy=${lib.escapeShellArg "${preparedDir}/klaffat-env.age"}
      cp --no-dereference --preserve=mode,ownership -- "$encrypted" "$encrypted_copy"
      [ -f "$encrypted_copy" ] && [ ! -L "$encrypted_copy" ] \
        || refuse "the copied encrypted environment changed type during preparation"
      chown root:root "$encrypted_copy"
      chmod 0400 "$encrypted_copy"

      plaintext=$(mktemp ${lib.escapeShellArg "${runtimeDir}/decrypted.XXXXXX"})
      if ! timeout --signal=KILL ${toString cfg.decryptTimeoutSeconds} \
          ${lib.escapeShellArg cfg.decryptProgram} --decrypt \
          --identity ${lib.escapeShellArg cfg.identityFile} -- "$encrypted_copy" \
          > "$plaintext" 2>/dev/null; then
        refuse "the encrypted Klaffat environment could not be decrypted"
      fi

      environment_tmp=$(mktemp ${lib.escapeShellArg "${runtimeDir}/google.env.XXXXXX"})
      if ! python3 ${extractGoogleEnvironment} "$plaintext" "$environment_tmp" 2>/dev/null; then
        refuse "the decrypted environment does not contain one valid Google OAuth pair"
      fi
      chown root:root "$environment_tmp"
      chmod 0400 "$environment_tmp"
      mv -f -- "$environment_tmp" ${lib.escapeShellArg "${runtimeDir}/google.env"}
      environment_tmp=""
      rm -f -- "$plaintext"
      plaintext=""

      printf '%s\n' "$worktree" > ${lib.escapeShellArg "${preparedDir}/source-worktree"}
      chmod 0444 ${lib.escapeShellArg "${preparedDir}/source-worktree"}
    '';
  };

  runServer = pkgs.writeShellApplication {
    name = "klaffat-local-google-server";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      export BASE_URL=http://localhost:${toString cfg.port}
      export DATABASE_URL='postgresql:///${databaseName}?host=/run/postgresql'
      export KLAFFAT_BIND=127.0.0.1:${toString cfg.port}
      export KLAFFAT_BUS=inprocess
      export KLAFFAT_COOKIE_SECURE=0
      export KLAFFAT_DEV_AUTH_TOKEN=klaffat-local-google-dev-auth-token
      export KLAFFAT_DEV_MAILBOX=1
      export KLAFFAT_ENV=development
      export KLAFFAT_KEK_PATH=${preparedDir}/kek
      export KLAFFAT_LOCAL_GOOGLE_STATE_DIR=${stateDir}
      export KLAFFAT_MAILER=memory
      export KLAFFAT_STATIC_DIR=${preparedDir}/static
      export PORT=${toString cfg.port}
      export RUST_LOG=info
      unset ${lib.concatStringsSep " " (map lib.escapeShellArg endpointOverrideNames)}

      ${preparedDir}/klaffat migrate
      exec ${preparedDir}/klaffat
    '';
  };

  launcher = pkgs.writeShellApplication {
    name = "klaffat-local-google";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.git pkgs.systemd ];
    text = ''
      set -euo pipefail
      usage() {
        echo "usage: klaffat-local-google start <klaffat-worktree> | status | stop" >&2
        exit 2
      }
      [ "$#" -ge 1 ] || usage
      action=$1
      shift
      case "$action" in
        start)
          [ "$#" -eq 1 ] || usage
          requested=$1
          worktree=$(readlink -e -- "$requested") || {
            echo "klaffat-local-google: worktree does not exist: $requested" >&2
            exit 2
          }
          root=$(readlink -e -- ${lib.escapeShellArg cfg.worktreeRoot}) || {
            echo "klaffat-local-google: worktree root does not exist" >&2
            exit 2
          }
          relative="''${worktree#"$root"/}"
          case "$worktree" in
            "$root"/klaffat-*) ;;
            *)
              echo "klaffat-local-google: expected an immediate klaffat-* child of $root" >&2
              exit 2
              ;;
          esac
          if [[ "$relative" == */* ]]; then
            echo "klaffat-local-google: expected an immediate klaffat-* child of $root" >&2
            exit 2
          fi
          origin=$(git -C "$worktree" config --get remote.origin.url 2>/dev/null || true)
          case "$origin" in
            ${acceptedOriginPatterns}) ;;
            *)
              echo "klaffat-local-google: '$worktree' is not a Klaffat worktree (unexpected origin)" >&2
              exit 2
              ;;
          esac
          ${lib.escapeShellArg cfg.buildProgram} "$worktree"
          [ -x "$worktree/${expectedBinary}" ] || {
            echo "klaffat-local-google: build did not produce ${expectedBinary}" >&2
            exit 1
          }
          selector=${lib.escapeShellArg cfg.selectionFile}
          install -d -m 0700 "$(dirname "$selector")"
          selector_tmp=$(mktemp "$(dirname "$selector")/worktree.XXXXXX")
          trap 'rm -f -- "$selector_tmp"' EXIT
          printf '%s\n' "$worktree" > "$selector_tmp"
          chmod 0600 "$selector_tmp"
          mv -f -- "$selector_tmp" "$selector"
          trap - EXIT
          # A never-started static unit is discoverable but not yet loaded;
          # reset-failed returns non-zero in that healthy first-start state.
          # Restart below remains mandatory and carries the real auth/error
          # signal.
          systemctl reset-failed ${serviceName}.service 2>/dev/null || true
          systemctl restart ${serviceName}.service
          for _attempt in $(seq 1 ${toString cfg.healthAttempts}); do
            if curl --fail --silent --show-error --max-time 2 \
                http://localhost:${toString cfg.port}/healthz >/dev/null; then
              echo "Klaffat with real Google Calendar is ready: http://localhost:${toString cfg.port}"
              exit 0
            fi
            sleep 1
          done
          echo "klaffat-local-google: service did not become healthy; run: systemctl status ${serviceName}.service" >&2
          exit 1
          ;;
        status)
          [ "$#" -eq 0 ] || usage
          systemctl --no-pager status ${serviceName}.service
          ;;
        stop)
          [ "$#" -eq 0 ] || usage
          systemctl stop ${serviceName}.service
          ;;
        *) usage ;;
      esac
    '';
  };
in
{
  options.services.klaffatLocalGoogle = {
    enable = lib.mkEnableOption "the isolated local Klaffat server with real Google Calendar OAuth";

    operator = lib.mkOption {
      type = lib.types.str;
      default = "jonathan";
      description = "The local user allowed to select and operate the fixed service.";
    };

    worktreeRoot = lib.mkOption {
      type = lib.types.str;
      default = "/home/jonathan/worktrees";
      description = "Canonical parent of selectable klaffat-* development worktrees.";
    };

    selectionFile = lib.mkOption {
      type = lib.types.str;
      default = "/home/jonathan/.local/state/klaffat-local-google/worktree";
      description = "Operator-owned file containing the selected canonical worktree path.";
    };

    encryptedEnvironmentRelativePath = lib.mkOption {
      type = lib.types.str;
      default = "deploy/secrets/klaffat-env.age";
      description = "Fixed path, relative to the worktree, of the age-encrypted environment.";
    };

    acceptedOrigins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "https://github.com/jonathanmoregard/klaffat.git"
        "git@github.com:jonathanmoregard/klaffat.git"
        "ssh://git@github.com/jonathanmoregard/klaffat.git"
      ];
      description = "Repository origins accepted by the unprivileged build helper.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3740;
      description = "Loopback port for the local real-Google development server.";
    };

    identityFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssh/ssh_host_ed25519_key";
      description = "Root-only age identity used to decrypt the Klaffat environment.";
    };

    decryptProgram = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.age}/bin/age";
      internal = true;
      description = "Age-compatible decryptor path; overridden only by the VM fixture.";
    };

    decryptTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      internal = true;
      description = "Bound for the root decryption subprocess.";
    };

    buildProgram = lib.mkOption {
      type = lib.types.str;
      default = "${buildKlaffat}/bin/klaffat-local-google-build";
      internal = true;
      description = "Unprivileged Klaffat build helper; overridden only by the VM fixture.";
    };

    healthAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      internal = true;
      description = "One-second health attempts made by the launcher.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.worktreeRoot;
        message = "services.klaffatLocalGoogle.worktreeRoot must be absolute";
      }
      {
        assertion = lib.hasPrefix "/" cfg.selectionFile;
        message = "services.klaffatLocalGoogle.selectionFile must be absolute";
      }
      {
        assertion = !(lib.hasPrefix "/" cfg.encryptedEnvironmentRelativePath)
          && !(lib.hasInfix ".." cfg.encryptedEnvironmentRelativePath);
        message = "services.klaffatLocalGoogle.encryptedEnvironmentRelativePath must be a traversal-free relative path";
      }
    ];

    users.groups.${serviceUser} = { };
    users.users.${serviceUser} = {
      isSystemUser = true;
      group = serviceUser;
      home = stateDir;
      createHome = false;
      shell = pkgs.shadow;
    };

    services.postgresql = {
      enable = true;
      settings.listen_addresses = lib.mkForce "";
      ensureDatabases = [ databaseName ];
      ensureUsers = [
        {
          name = serviceUser;
          ensureDBOwnership = true;
        }
      ];
    };

    environment.systemPackages = [ launcher ];
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        var permittedVerbs = ["start", "stop", "restart", "reset-failed"];
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == ${builtins.toJSON cfg.operator} &&
            action.lookup("unit") == "${serviceName}.service" &&
            permittedVerbs.indexOf(action.lookup("verb")) >= 0) {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.services.${serviceName} = {
      description = "Local Klaffat with real Google Calendar OAuth";
      after = [ "postgresql.service" "postgresql-setup.service" ];
      requires = [ "postgresql.service" "postgresql-setup.service" ];
      environment = {
        BASE_URL = "http://localhost:${toString cfg.port}";
        DATABASE_URL = "postgresql:///${databaseName}?host=/run/postgresql";
        KLAFFAT_BIND = "127.0.0.1:${toString cfg.port}";
      };
      serviceConfig = {
        Type = "simple";
        User = serviceUser;
        Group = serviceUser;
        RuntimeDirectory = serviceName;
        RuntimeDirectoryMode = "0700";
        StateDirectory = serviceName;
        StateDirectoryMode = "0700";
        ExecStartPre = "+${prepare}/bin/klaffat-local-google-prepare";
        EnvironmentFile = "-${runtimeDir}/google.env";
        ExecStart = "${runServer}/bin/klaffat-local-google-server";
        # This is an explicitly operator-launched development service.
        # Automatic retries would repeat the root-only preparation and
        # decryption path after a malformed selector or ciphertext; the
        # launcher is the single deliberate restart path instead.
        Restart = "no";
        TimeoutStartSec = "120s";
        TimeoutStopSec = "30s";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = "read-only";
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        ProcSubset = "pid";
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        SystemCallArchitectures = "native";
      };
    };
  };
}
