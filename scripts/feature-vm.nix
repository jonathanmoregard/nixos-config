# Builds the `feature-vm` control tool (scripts/feature-vm.sh).
#
# `memoryRunner` is nix-memory-run from modules/nixos/build-coordination.nix;
# the check in flake.nix passes a pass-through fake instead.
{ pkgs, memoryRunner, name ? "feature-vm", display ? null }:
let
  screencap = pkgs.writeShellApplication {
    name = "feature-vm-screencap";
    runtimeInputs = with pkgs; [ socat netpbm ];
    text = ''
      if [ $# -lt 2 ]; then
        echo "usage: feature-vm-screencap <qmp-sock> <output.png>" >&2
        exit 2
      fi
      sock="$1"
      out="$2"
      if [ ! -S "$sock" ]; then
        echo "[feature-vm-screencap] no QMP socket at $sock — is the VM running?" >&2
        exit 1
      fi
      # QEMU writes the screendump to a path it can access.
      # Drop it next to the socket so the path is already
      # under the launcher's run dir.
      ppm="$(dirname "$sock")/screenshot.ppm"
      rm -f "$ppm"
      {
        printf '{"execute":"qmp_capabilities"}\n'
        printf '{"execute":"screendump","arguments":{"filename":"%s"}}\n' "$ppm"
        # Give QEMU time to render + write before EOF closes the socket.
        sleep 2
      } | socat -t 10 - UNIX-CONNECT:"$sock" >/dev/null
      if [ ! -s "$ppm" ]; then
        echo "[feature-vm-screencap] screendump produced no PPM output" >&2
        exit 1
      fi
      pnmtopng "$ppm" > "$out"
      rm -f "$ppm"
      echo "$out"
    '';
  };

  tool = pkgs.writeShellApplication {
    inherit name;
    # `nix`, `ssh`/`scp` and `systemd-run`/`systemctl` deliberately come from the host
    # PATH: the host's `nix` is the memory-coordinating wrapper, and the
    # user systemd instance must match the host's systemd.
    runtimeInputs = with pkgs; [ coreutils git ];
    text = ''
      MEMORY_RUNNER=${memoryRunner}/bin/nix-memory-run
      SCREENCAP=${screencap}/bin/feature-vm-screencap
      TARGET=${./feature-vm-target.nix}
      SELF="$(readlink -f "$0")"
      ${pkgs.lib.optionalString (display != null) ''
        export FEATURE_VM_DISPLAY=${pkgs.lib.escapeShellArg display}
      ''}
      ${builtins.readFile ./feature-vm.sh}
    '';
  };
in
tool // { inherit screencap; }
