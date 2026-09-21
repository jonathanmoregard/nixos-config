# smarthome-auto-deploy: direct Git pull, cache hydration, activation, replay,
# and rollback-latch contract.
#
# Run: nix build --no-link .#checks.x86_64-linux.smarthome-auto-deploy -L
{ pkgs, inputs }:

let
  inherit (pkgs) lib;

  v1 = pkgs.writeShellScriptBin "house-automationd" ''
    echo v1
  '';
  v2 = pkgs.writeShellScriptBin "house-automationd" ''
    echo v2
  '';

  fakeNix = pkgs.writeShellScriptBin "nix" ''
    set -euo pipefail
    [ "$HOME" = "$STATE_DIRECTORY" ] || exit 85
    [ "$XDG_CACHE_HOME" = "$STATE_DIRECTORY/cache" ] || exit 85
    [ -d "$XDG_CACHE_HOME" ] && [ -w "$XDG_CACHE_HOME" ] || exit 85
    printf 'NIX' >> "$SMARTHOME_DEPLOY_TEST_LOG"
    printf ' %q' "$@" >> "$SMARTHOME_DEPLOY_TEST_LOG"
    printf '\n' >> "$SMARTHOME_DEPLOY_TEST_LOG"
    [ "$#" -eq 12 ] || exit 86
    [ "$1" = eval ] || exit 86
    [ "$2" = --raw ] || exit 86
    [ "$3" = --option ] && [ "$4" = max-jobs ] && [ "$5" = 0 ] || exit 86
    [ "$6" = --option ] && [ "$7" = fallback ] && [ "$8" = false ] || exit 86
    [ "$9" = --option ] && [ "''${10}" = builders ] && [ -z "''${11}" ] || exit 86
    reference=''${12}
    source_dir=''${reference%%#*}
    attribute=''${reference#*#}
    [ "$attribute" = packages.x86_64-linux.default.outPath ] || exit 86
    cat "$source_dir/release-path"
  '';

  fakeHydrator = pkgs.writeShellScriptBin "smarthome-hydrate-release-paths" ''
    set -euo pipefail
    printf 'HYDRATE' >> "$SMARTHOME_DEPLOY_TEST_LOG"
    printf ' %q' "$@" >> "$SMARTHOME_DEPLOY_TEST_LOG"
    printf '\n' >> "$SMARTHOME_DEPLOY_TEST_LOG"
    [ "$#" -eq 9 ] || exit 87
    [ "$1" = --from ] && [ "$2" = https://jonathanmoregard.cachix.org ] || exit 87
    [ "$3" = --trusted-key ] && \
      [ "$4" = 'jonathanmoregard.cachix.org-1:Qzksr/c2ciAaV4j/U2mGFd1HTgOAicks8gJNs1Ztxo8=' ] || exit 87
    [ "$5" = --timeout-seconds ] && [ "$6" = 300 ] || exit 87
    [ "$7" = --interval ] && [ "$8" = 5 ] || exit 87
    case "$9" in
      ${v1}|${v2}) ;;
      *) exit 87 ;;
    esac
  '';

  fakeActivator = pkgs.writeShellScriptBin "smarthome-activate-package" ''
    set -euo pipefail
    [ "$#" -eq 6 ] || exit 64
    package_path=$1
    revision=$2
    state_dir=$3
    profile=$4
    printf 'ACTIVATE %s %s\n' "$revision" "$package_path" >> "$SMARTHOME_DEPLOY_TEST_LOG"
    mkdir -p "$state_dir" "$(dirname "$profile")"
    temporary_profile="$profile.tmp.$$"
    ln -s "$package_path" "$temporary_profile"
    mv -Tf "$temporary_profile" "$profile"
    temporary_marker="$state_dir/.last-success.$$"
    printf 'rev=%s\npath=%s\nprevious_path=test\n' \
      "$revision" "$package_path" > "$temporary_marker"
    mv -f "$temporary_marker" "$state_dir/last-success"
  '';

  evaluated = inputs.nixpkgs.lib.nixosSystem {
    inherit pkgs;
    modules = [
      ../modules/nixos/smarthome-auto-deploy.nix
      {
        documentation.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = "25.11";
        services.smarthome-auto-deploy = {
          enable = true;
          repoUrl = "file:///build/smarthome-origin.git";
          sourceDir = "/build/smarthome-source";
          profile = "/build/smarthome-profile";
          deployKeyFile = "/build/smarthome deploy-key;safe";
          nixPackage = fakeNix;
          hydratorPackage = fakeHydrator;
          activatorPackage = fakeActivator;
        };
      }
    ];
  };

  config = evaluated.config;
  unit = config.systemd.services.smarthome-deploy;
  service = unit.serviceConfig;
  timer = config.systemd.timers.smarthome-deploy.timerConfig;
  deployProgram = service.ExecStart;
in
assert service.StateDirectory == "smarthome-deploy";
assert service.StateDirectoryMode == "0700";
assert service.RuntimeDirectory == "smarthome-deploy";
assert service.TimeoutStartSec == "10min";
assert service.User == "root";
assert service.Group == "root";
assert !(unit.environment ? GIT_SSH_COMMAND);
assert !(unit.environment ? SSH_AUTH_SOCK);
assert !(unit.environment ? DEPLOY_KEY);
assert timer.OnUnitActiveSec == "15min";
assert timer.Persistent;
assert config.services.smarthome-auto-deploy.profile == "/build/smarthome-profile";
assert builtins.length (builtins.attrNames config.programs.ssh.knownHosts) == 3;
pkgs.runCommand "smarthome-auto-deploy-contract"
  {
    nativeBuildInputs = with pkgs; [ bash coreutils git gnugrep ];
    inherit deployProgram;
  } ''
    set -euo pipefail
    export HOME="$PWD/protected-home"
    export STATE_DIRECTORY="$PWD/state"
    export RUNTIME_DIRECTORY="$PWD/run"
    export SMARTHOME_DEPLOY_TEST_LOG="$PWD/deploy.log"
    mkdir -p "$HOME" "$STATE_DIRECTORY" "$RUNTIME_DIRECTORY"
    : > "$SMARTHOME_DEPLOY_TEST_LOG"

    grep -F -- '--option max-jobs 0' "$deployProgram"
    grep -F -- '--option fallback false' "$deployProgram"
    grep -F -- '--option builders ""' "$deployProgram"
    grep -F -- 'fetch --depth=1' "$deployProgram"
    grep -F -- 'StrictHostKeyChecking=yes' "$deployProgram"
    grep -F -- 'BatchMode=yes' "$deployProgram"
    grep -F -- 'IdentitiesOnly=yes' "$deployProgram"

    ssh_export=$(grep -m1 '^export GIT_SSH_COMMAND=' "$deployProgram")
    eval "$ssh_export"
    eval "set -- $GIT_SSH_COMMAND"
    [ "$#" -eq 13 ]
    [ "$1" = ${pkgs.openssh}/bin/ssh ]
    [ "$2" = -i ]
    [ "$3" = '/build/smarthome deploy-key;safe' ]
    [ "$4" = -o ] && [ "$5" = IdentitiesOnly=yes ]
    [ "$6" = -o ] && [ "$7" = StrictHostKeyChecking=yes ]
    [ "$8" = -o ] && [ "$9" = BatchMode=yes ]
    [ "''${10}" = -o ] && [ "''${11}" = UserKnownHostsFile=/etc/ssh/ssh_known_hosts ]
    [ "''${12}" = -o ] && [ "''${13}" = ConnectTimeout=15 ]

    WORK="$PWD/work"
    ORIGIN="$PWD/smarthome-origin.git"
    SOURCE="$PWD/smarthome-source"
    PROFILE="$PWD/smarthome-profile"
    KEY="$PWD/smarthome deploy-key;safe"

    git init -q "$WORK"
    git -C "$WORK" config user.email test@example.invalid
    git -C "$WORK" config user.name smarthome-test
    printf '%s\n' ${v1} > "$WORK/release-path"
    git -C "$WORK" add release-path
    git -C "$WORK" commit -qm v1
    git init -q --bare "$ORIGIN"
    git -C "$WORK" branch -M main
    git -C "$WORK" remote add origin "file://$ORIGIN"
    git -C "$WORK" push -q -u origin main
    REV1=$(git -C "$WORK" rev-parse HEAD)
    chmod 000 "$HOME"

    if "$deployProgram" > missing-key.log 2>&1; then
      echo 'FAIL(missing-key): deploy unexpectedly succeeded' >&2
      exit 1
    fi
    grep -qF 'deploy key is missing' missing-key.log
    [ ! -e "$SOURCE" ] || {
      echo 'FAIL(missing-key): source checkout was touched' >&2
      exit 1
    }

    printf 'fixture-key\n' > "$KEY"
    chmod 0644 "$KEY"
    if "$deployProgram" > wrong-mode.log 2>&1; then
      echo 'FAIL(wrong-mode): deploy unexpectedly succeeded' >&2
      exit 1
    fi
    grep -qF 'expected mode 400' wrong-mode.log
    [ ! -e "$SOURCE" ] || {
      echo 'FAIL(wrong-mode): source checkout was touched' >&2
      exit 1
    }

    chmod 0400 "$KEY"
    "$deployProgram"
    chmod 0700 "$HOME"
    [ "$(git -C "$SOURCE" rev-parse HEAD)" = "$REV1" ]
    [ "$(readlink -f "$PROFILE")" = ${v1} ]
    grep -qxF "rev=$REV1" "$STATE_DIRECTORY/last-success"
    grep -qxF "path=${v1}" "$STATE_DIRECTORY/last-success"
    [ "$(grep -c '^ACTIVATE ' "$SMARTHOME_DEPLOY_TEST_LOG")" -eq 1 ]
    [ "$(grep -c '^HYDRATE ' "$SMARTHOME_DEPLOY_TEST_LOG")" -eq 1 ]
    [ "$(awk '$1 == "HYDRATE" { print $NF }' "$SMARTHOME_DEPLOY_TEST_LOG")" = ${v1} ]

    chmod 000 "$HOME"
    "$deployProgram"
    chmod 0700 "$HOME"
    [ "$(grep -c '^ACTIVATE ' "$SMARTHOME_DEPLOY_TEST_LOG")" -eq 1 ] || {
      cat "$SMARTHOME_DEPLOY_TEST_LOG"
      echo 'FAIL(replay): identical release activated twice' >&2
      exit 1
    }
    [ "$(grep -c '^HYDRATE ' "$SMARTHOME_DEPLOY_TEST_LOG")" -eq 1 ]

    printf '%s\n' ${v2} > "$WORK/release-path"
    git -C "$WORK" commit -qam v2
    git -C "$WORK" push -q origin main
    REV2=$(git -C "$WORK" rev-parse HEAD)
    chmod 000 "$HOME"
    "$deployProgram"
    chmod 0700 "$HOME"
    [ "$(git -C "$SOURCE" rev-parse HEAD)" = "$REV2" ]
    [ "$(readlink -f "$PROFILE")" = ${v2} ]
    [ "$(grep -c '^ACTIVATE ' "$SMARTHOME_DEPLOY_TEST_LOG")" -eq 2 ]
    [ "$(grep -c '^HYDRATE ' "$SMARTHOME_DEPLOY_TEST_LOG")" -eq 2 ]
    [ "$(awk '$1 == "HYDRATE" { print $NF }' "$SMARTHOME_DEPLOY_TEST_LOG")" = \
      $'${v1}\n${v2}' ]

    temporary_profile="$PROFILE.rollback"
    ln -s ${v1} "$temporary_profile"
    mv -Tf "$temporary_profile" "$PROFILE"
    chmod 000 "$HOME"
    if "$deployProgram" > rollback-latch.log 2>&1; then
      echo 'FAIL(rollback-latch): deploy clobbered manual rollback' >&2
      exit 1
    fi
    chmod 0700 "$HOME"
    grep -qF 'rollback in effect; refusing to clobber' rollback-latch.log
    [ "$(readlink -f "$PROFILE")" = ${v1} ]
    [ "$(grep -c '^ACTIVATE ' "$SMARTHOME_DEPLOY_TEST_LOG")" -eq 2 ]

    echo 'ok: key guards, first deploy, replay, branch advance, and rollback latch'
    touch "$out"
  ''
