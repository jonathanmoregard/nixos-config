# Serialize memory-heavy Nix/feature-VM work across interactive sessions and
# root's auto-deploy while keeping lightweight Nix commands concurrent.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.buildCoordination;
  coordinationDir = "/home/jonathan/.nix-memory-pressure";
  lockPath = "${coordinationDir}/lock";

  memoryRunner = pkgs.writeShellApplication {
    name = "nix-memory-run";
    runtimeInputs = with pkgs; [ coreutils util-linux ];
    text = ''
      set -euo pipefail

      nonblock=0
      if [ "''${1:-}" = "--nonblock" ]; then
        nonblock=1
        shift
      fi
      if [ "''${1:-}" != "--" ]; then
        echo "usage: nix-memory-run [--nonblock] -- command [args...]" >&2
        exit 2
      fi
      shift
      if [ "$#" -eq 0 ]; then
        echo "nix-memory-run: command is required after --" >&2
        exit 2
      fi

      # A coordinated parent (feature-VM launcher, nixos-rebuild) may call Nix
      # again. Re-locking here would deadlock on our own open-file-description.
      if [ "''${NIX_MEMORY_COORDINATION_HELD:-}" = "1" ]; then
        exec "$@"
      fi

      lock_dir=${lib.escapeShellArg coordinationDir}
      lock_path=${lib.escapeShellArg lockPath}
      if [ ! -d "$lock_dir" ]; then
        if [ "$(id -u)" -eq 0 ]; then
          echo "nix-memory-run: coordination directory missing; deploy tmpfiles first" >&2
          exit 1
        fi
        install -d -m 0700 "$lock_dir"
      fi
      if [ ! -e "$lock_path" ]; then
        if [ "$(id -u)" -eq 0 ]; then
          echo "nix-memory-run: coordination lock missing; deploy tmpfiles first" >&2
          exit 1
        fi
        umask 077
        : > "$lock_path"
      fi

      exec {memory_lock_fd}>"$lock_path"
      if [ "$nonblock" -eq 1 ]; then
        if ! flock -n "$memory_lock_fd"; then
          echo "nix-memory-run: memory-heavy job active; deferred" >&2
          exit 75
        fi
      elif ! flock -n "$memory_lock_fd"; then
        echo "nix-memory-run: waiting for active memory-heavy job" >&2
        flock "$memory_lock_fd"
      fi

      export NIX_MEMORY_COORDINATION_HELD=1
      exec "$@"
    '';
  };

  coordinatedNix = pkgs.writeShellApplication {
    name = "nix";
    runtimeInputs = with pkgs; [ coreutils systemd ];
    text = ''
      set -euo pipefail

      real_nix=${lib.escapeShellArg "${config.nix.package}/bin/nix"}
      coordinate=0
      previous=""
      for argument in "$@"; do
        case "$argument" in
          build|eval)
            coordinate=1
            ;;
          check)
            if [ "$previous" = "flake" ]; then
              coordinate=1
            fi
            ;;
          *#feature-vm|*#feature-vm-headful)
            coordinate=1
            ;;
          *#feature-vm-screencap)
            coordinate=0
            break
            ;;
        esac
        previous="$argument"
      done

      if [ "$coordinate" -eq 0 ] || [ "''${NIX_MEMORY_COORDINATION_HELD:-}" = "1" ]; then
        exec "$real_nix" "$@"
      fi

      runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      if [ -S "$runtime_dir/bus" ]; then
        exec ${memoryRunner}/bin/nix-memory-run -- \
          systemd-run --user --scope --quiet --collect \
          --unit="nix-memory-$PPID-$$" \
          --slice=ram-heavy.slice \
          --property=OOMPolicy=kill \
          -- "$real_nix" "$@"
      fi

      echo "nix: coordinated without user scope (no bus at $runtime_dir/bus)" >&2
      exec ${memoryRunner}/bin/nix-memory-run -- "$real_nix" "$@"
    '';
  };
in
{
  options.services.buildCoordination = {
    enable = lib.mkEnableOption "memory coordination for Nix and feature-VM jobs";

    runnerPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "Shared memory-admission helper package.";
    };

    nixPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "Nix wrapper that coordinates memory-heavy subcommands.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.buildCoordination = {
      runnerPackage = memoryRunner;
      nixPackage = coordinatedNix;
    };

    # Stable across deployment generations. Jonathan can create this exact
    # path before first activation; tmpfiles fixes ownership/mode before any
    # root deploy timer runs. Root can open Jonathan's file without widening
    # access to other local users.
    systemd.tmpfiles.rules = [
      "d ${coordinationDir} 0700 jonathan users -"
      "f ${lockPath} 0600 jonathan users -"
    ];

    environment.systemPackages = [
      memoryRunner
      (lib.hiPrio coordinatedNix)
    ];

    nix.settings = {
      experimental-features = [ "cgroups" ];
      max-jobs = 1;
      cores = 4;
      use-cgroups = true;
    };
  };
}
