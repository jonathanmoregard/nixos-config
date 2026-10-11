# Kill disposable build descendants before memory pressure reaches desktop.
#
# Two disposable cgroups share one policy: the system nix-daemon (builders)
# and jonathan's ram-heavy.slice (interactive eval/build clients and feature
# VMs, see build-coordination.nix). MemoryHigh throttles them first; OOMD
# kills inside them if pressure persists. Nothing else is enrolled.
#
# MemoryHigh is a share of the host's RAM, so it fits any host. A workload
# that claims a large fixed amount while it runs (offline-ai's model) declares
# a reservation; while one is active each cgroup is capped at half of what is
# left (a `nix build` runs its evaluator in the slice and its builders in the
# daemon at once, so the two must share the remainder):
#
#   share = (MemTotal - active reservations - desktopReserve) / 2  (>= minBudget)
#   cap   = min(heavyMemoryPercent of MemTotal, share)
#
# Each reservation is a oneshot system unit, memory-reserve-<name>.service,
# which the owning workload starts before it allocates and stops after it
# exits. Starting one writes the cap as a runtime drop-in under /run/systemd,
# which survives daemon-reload and restarts and is gone after reboot.
# Stopping the last one removes that drop-in and reloads, so the configured
# value returns exactly. While a reservation is active, /run/memory-reserve/<name>
# exists, for units that must not start into the reserved memory.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.memoryPressure;
  gib = 1024 * 1024 * 1024;

  disposablePolicy = {
    MemoryAccounting = true;
    MemoryHigh = "${toString cfg.heavyMemoryPercent}%";
    ManagedOOMSwap = "kill";
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "40%";
    ManagedOOMMemoryPressureDurationSec = "10s";
  };

  reserveUnit = name: "memory-reserve-${name}.service";

  applyBudget = pkgs.writeShellApplication {
    name = "memory-budget-apply";
    runtimeInputs = with pkgs; [ coreutils gawk systemd ];
    text = ''
      total=$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) * 1024 ))

      # A reservation counts from the moment its unit starts until it has
      # stopped, so the unit being started or stopped right now is counted
      # correctly from inside its own ExecStart/ExecStopPost.
      reserved=0
      ${lib.concatStrings (lib.mapAttrsToList (name: bytes: ''
        case "$(systemctl show -P ActiveState ${reserveUnit name})" in
          active|activating|reloading) reserved=$(( reserved + ${toString bytes} )) ;;
        esac
      '') cfg.reservations)}

      share=$(( (total - reserved - ${toString cfg.desktopReserve}) / 2 ))
      if [ "$share" -lt ${toString cfg.minBudget} ]; then
        share=${toString cfg.minBudget}
      fi
      value=$(( total * ${toString cfg.heavyMemoryPercent} / 100 ))
      if [ "$share" -lt "$value" ]; then
        value=$share
      fi

      # Our own runtime drop-in, named to sort after NixOS's overrides.conf:
      # drop-ins apply in filename order across directories, so a
      # `set-property --runtime` file (50-*.conf) loses to overrides.conf on
      # the next daemon-reload. Only this one file is written or removed.
      # $1: runtime unit dir, $2: unit, $3: section, rest: systemctl scope.
      cap() {
        local dir=$1/$2.d unit=$2 section=$3
        shift 3
        if [ "$reserved" -gt 0 ]; then
          mkdir -p "$dir"
          printf '[%s]\nMemoryHigh=%s\n' "$section" "$value" > "$dir/zz-memory-reserve.conf.tmp"
          mv -f "$dir/zz-memory-reserve.conf.tmp" "$dir/zz-memory-reserve.conf"
        else
          rm -f "$dir/zz-memory-reserve.conf"
        fi
        # daemon-reload writes the resulting MemoryHigh to the live cgroup.
        if systemctl "$@" daemon-reload; then
          echo "$unit: MemoryHigh=$(systemctl "$@" show -P MemoryHigh -- "$unit") (reserved=$reserved)"
        else
          echo "$unit: manager not reachable; the drop-in applies when it starts" >&2
        fi
      }

      cap /run/systemd/system nix-daemon.service Service
      cap /run/systemd/user ram-heavy.slice Slice --user --machine=${cfg.user}@
    '';
  };
in
{
  options.services.memoryPressure = {
    heavyMemoryPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 50;
      description = ''
        MemoryHigh for nix-daemon and ram-heavy.slice, as a percentage of
        physical RAM, so one value fits every host.
      '';
    };

    reservations = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = { };
      example = { offline-ai = 45 * gib; };
      description = ''
        Bytes a named workload holds while memory-reserve-<name>.service is
        active. The workload starts that unit before allocating and stops it
        afterwards; ${cfg.user} may do both without authentication.
      '';
    };

    desktopReserve = lib.mkOption {
      type = lib.types.ints.unsigned;
      # Desktop, Chrome and a few Claude sessions measured ~12-15 GiB on
      # tuxedo 2026-09-30. Builds get what remains beyond this.
      default = 12 * gib;
      description = "Bytes kept for everything else while a reservation is active.";
    };

    minBudget = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1 * gib;
      description = "Floor for the shrunk cap, so evaluation can still make progress.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "jonathan";
      description = "Owner of ram-heavy.slice and of the reservation units.";
    };
  };

  config = {
    systemd.oomd = {
      enable = true;
      enableRootSlice = false;
      enableSystemSlice = false;
      enableUserSlices = false;
      settings.OOM.SwapUsedLimit = "80%";
    };

    # use-cgroups=true puts each derivation below this daemon cgroup. OOMD
    # monitors ancestor but selects offending build descendant; daemon survives
    # to serve next build.
    systemd.services = {
      nix-daemon.serviceConfig = disposablePolicy;
    } // lib.mapAttrs' (name: bytes: lib.nameValuePair "memory-reserve-${name}" {
      description = "Memory reservation: ${name} (${toString (bytes / gib)} GiB)";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${applyBudget}/bin/memory-budget-apply";
        # ExecStopPost, not ExecStop: it also runs when the start failed, so a
        # half-applied cap is always withdrawn.
        ExecStopPost = "${applyBudget}/bin/memory-budget-apply";
        # /run/memory-reserve/<name> exists exactly while the reservation is
        # active (created at start, removed at stop, gone after reboot): a
        # path any unit, system or user, can test with ConditionPathExists=.
        # offline-ai hangs its evicted services on it, so a deploy or a timer
        # cannot start them back into the memory the model is holding.
        RuntimeDirectory = "memory-reserve/${name}";
        RuntimeDirectoryPreserve = false;
      };
    }) cfg.reservations;

    systemd.user.slices.ram-heavy = {
      description = "Memory-heavy disposable workloads";
      documentation = [ "man:systemd-oomd.service(8)" ];
      # Half a default sibling's CPU share: an interactive eval or build
      # client here yields to the rest of the session under contention
      # (dictation carries CPUWeight=1000, modules/nixos/local-stt.nix).
      sliceConfig = disposablePolicy // { CPUWeight = 50; };
      wantedBy = [ "default.target" ];
    };

    security.polkit.extraConfig = lib.mkIf (cfg.reservations != { }) ''
      polkit.addRule(function (action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == ${builtins.toJSON cfg.user} &&
            ${builtins.toJSON (map reserveUnit (lib.attrNames cfg.reservations))}.indexOf(action.lookup("unit")) >= 0 &&
            ["start", "stop"].indexOf(action.lookup("verb")) >= 0) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
