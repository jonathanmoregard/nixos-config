# feature-vm — boot and drive a disposable copy of a workstation host.
#
# Sourced into a writeShellApplication by scripts/feature-vm.nix, which
# defines MEMORY_RUNNER and SCREENCAP before this text. See `usage` below
# and home/claude-skills/nixos-agent-testing/SKILL.md for the workflow.

usage() {
  cat >&2 <<'EOF'
usage: feature-vm [--host NAME] [--trusted] [--flake DIR] [COMMAND ...]

With no COMMAND: boot in the foreground (Ctrl-C / poweroff to stop).

  up                  boot in the background, wait until ssh answers
  run 'CMD'           run a shell command in the VM (exit code passes through)
  run PROG ARG...     run a program with arguments, each quoted for you
  ssh                 interactive shell in the VM
  put SRC DEST        copy host SRC into the VM at DEST (recursive)
  get SRC DEST        copy VM SRC to host DEST (recursive)
  apply [MODULE.nix]  build the VM config from the flake (plus MODULE, if
                      given) on the host and activate it in the running VM
  reset               reboot to the pristine boot config (drops all changes)
  down                stop the background VM
  status              show whether a VM is up, for which host, in which mode
  screencap OUT.png   capture the VM display

Options (only read by up / foreground boot; later commands reuse them):
  --host NAME   nixosConfigurations.NAME to boot (default: this machine)
  --trusted     mount the shared folders read-write, allow guest internet
  --flake DIR   nixos-config checkout (default: the worktree you are in,
                else ~/Repos/nixos-config-worktrees/main)

Default mode is locked down: read-only shares, no internet. In both modes
the VM gets no key of yours; every secret in it is a throwaway fixture.
EOF
}

die() {
  echo "[feature-vm] ERROR: $*" >&2
  exit 1
}
log() { echo "[feature-vm] $*" >&2; }

state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/feature-vm"
run_dir="$state_dir/run"
config_file="$state_dir/config"
legacy_key_dir="$state_dir/host-ssh"
unit="feature-vm-bg"
ssh_port=2222
known_hosts="$state_dir/known_hosts"
# The VM's sshd key is fixed at build time (feature-vm.nix) and pinned
# here, so a command meant for the VM never runs on whatever else might
# be listening on localhost:2222.
interactive_ssh_opts=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts"
  -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$HOME/.ssh/id_ed25519")
ssh_opts=("${interactive_ssh_opts[@]}" -o BatchMode=yes -o ConnectTimeout=5)

opt_host=""
opt_trusted=0
opt_flake=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      [ $# -ge 2 ] || die "--host needs a value"
      opt_host="$2"
      shift 2
      ;;
    --trusted)
      opt_trusted=1
      shift
      ;;
    --flake)
      [ $# -ge 2 ] || die "--flake needs a value"
      opt_flake="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) break ;;
  esac
done
cmd="${1:-boot}"
[ $# -gt 0 ] && shift

# Options are only read before the command. Refuse them after it rather
# than silently booting the default host in the default mode.
case "$cmd" in
  up | down | reset | status | ssh)
    [ $# -eq 0 ] || die "$cmd takes no arguments; options go first: feature-vm [--host H] [--trusted] $cmd"
    ;;
  boot)
    for a in "$@"; do
      case "$a" in
        --host | --trusted | --flake) die "options go first: feature-vm [--host H] [--trusted]" ;;
      esac
    done
    ;;
esac

resolve_flake() {
  local dir="$opt_flake"
  if [ -z "$dir" ]; then
    dir="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$dir" ] || [ ! -f "$dir/modules/nixos/feature-vm.nix" ]; then
      dir="$HOME/Repos/nixos-config-worktrees/main"
    fi
  fi
  [ -f "$dir/flake.nix" ] || die "no flake.nix in $dir (pass --flake)"
  (cd "$dir" && pwd)
}

# Every value written here is validated first, so sourcing it back is safe.
write_config() {
  {
    printf 'host=%q\n' "$1"
    printf 'trusted=%q\n' "$2"
    printf 'flake=%q\n' "$3"
    printf 'vm=%q\n' "$4"
    printf 'research=%q\n' "$5"
  } > "$config_file"
}

load_config() {
  [ -f "$config_file" ] || die "no VM configured — run: feature-vm up"
  host="" trusted="" flake="" vm="" research=""
  # shellcheck disable=SC1090
  . "$config_file"
}

vm_active() {
  systemctl --user is-active --quiet "$unit.service" ||
    systemctl --user is-active --quiet feature-vm.scope
}

# Resolve options, build the VM, stage the shares. Leaves $config_file
# describing the VM that `serve` will boot.
prepare() {
  local host="${opt_host:-$(uname -n)}"
  case "$host" in
    "" | *[!a-z0-9-]*) die "bad host name: $host" ;;
  esac
  local flake
  flake="$(resolve_flake)"

  # Export the actual research-agent checkout selected for this smoke. The
  # default mirrors production; cross-repo feature work can point at its
  # exact worktree without rebuilding or editing feature-vm.nix.
  local research="${RESEARCH_AGENT_WORKTREE:-$HOME/Repos/research-agent}"
  case "$research" in
    /*) ;;
    *) die "RESEARCH_AGENT_WORKTREE must be absolute: $research" ;;
  esac
  case "$research" in
    *,*) die "RESEARCH_AGENT_WORKTREE cannot contain a comma: $research" ;;
  esac
  if [ ! -f "$research/scripts/run-agent.sh" ] || [ ! -d "$research/agent" ]; then
    die "no research-agent checkout at $research"
  fi

  mkdir -p "$state_dir"
  chmod 0700 "$state_dir"
  # Earlier launcher versions staged a copy of ~/.ssh/id_ed25519 here for
  # the VM. Nothing reads it any more; do not leave it lying around.
  rm -rf "$legacy_key_dir"
  rmdir "$state_dir/empty" 2>/dev/null || true

  log "building nixosConfigurations.$host VM from $flake"
  local vm
  vm="$(build_target vm "$host" "$flake" "")" || die "VM build failed"
  local hostkey
  hostkey="$(build_target hostkey "$host" "$flake" "")" || die "VM host key build failed"
  printf '[localhost]:%s %s\n' "$ssh_port" "$(cut -d' ' -f1,2 "$hostkey/ssh_host_ed25519_key.pub")" > "$known_hosts"
  write_config "$host" "$opt_trusted" "$flake" "$vm" "$research"
}

# build_target ATTR HOST FLAKE MODULE — see scripts/feature-vm-target.nix.
# The result stays a GC root ($state_dir/root-ATTR) until `down`: the guest
# runs straight off the host /nix/store, so a garbage collection mid-session
# (host auto-GC, or one triggered by apply's own build) must not reap it.
build_target() {
  nix build --print-out-paths --impure --file "$TARGET" \
    --out-link "$state_dir/root-$1" \
    --argstr attr "$1" --argstr host "$2" --argstr flake "$3" --argstr module "$4"
}

# Boot the VM described by $config_file in the foreground.
serve() {
  load_config
  rm -rf "$run_dir"
  mkdir -p "$run_dir"
  export TMPDIR="$run_dir"
  cd "$run_dir"

  local ro="" net=""
  if [ "$trusted" != 1 ]; then
    ro=",readonly=on"
    # restrict=on cuts the guest off from the host and the internet;
    # the ssh port forward still works.
    net="restrict=on"
  fi
  local opts="-snapshot"
  opts="$opts -qmp unix:$run_dir/qmp.sock,server=on,wait=off"
  opts="$opts -serial unix:$run_dir/serial.sock,server=on,wait=off"
  opts="$opts -virtfs local,path=$HOME/Repos/nixos-config-worktrees,security_model=none,mount_tag=worktrees$ro"
  opts="$opts -virtfs local,path=$research,security_model=mapped-xattr,mount_tag=research-agent$ro"
  export QEMU_OPTS="${FEATURE_VM_DISPLAY--display none} $opts"
  export QEMU_NET_OPTS="$net"

  local mode=locked
  [ "$trusted" = 1 ] && mode=trusted
  log "host=$host mode=$mode run=$run_dir"
  log "ssh:    feature-vm ssh   (or ssh -p $ssh_port jonathan@localhost)"
  log "serial: socat - UNIX-CONNECT:$run_dir/serial.sock"
  "$MEMORY_RUNNER" -- "$vm"/bin/run-*-vm "$@"
}

ssh_ready() {
  timeout 10 ssh -p "$ssh_port" "${ssh_opts[@]}" jonathan@localhost true 2>/dev/null
}

# Returns non-zero (after saying why) if the VM dies or never answers.
# The boot clock starts when QEMU does: before that the VM may be queued
# behind another memory-heavy job for as long as that job takes.
wait_ssh() {
  local limit="${FEATURE_VM_BOOT_TIMEOUT:-300}" started queued=0
  until [ -S "$run_dir/qmp.sock" ]; do
    vm_active || {
      log "VM exited before QEMU started — journalctl --user -u $unit"
      return 1
    }
    # QEMU normally starts within a second or two; say so only if it does not.
    if [ $((queued % 60)) -eq 6 ]; then
      log "waiting for the memory lock (another memory-heavy job is running)"
    fi
    sleep 2
    queued=$((queued + 2))
  done
  # Wall-clock, not a loop counter: one ssh probe can block for seconds.
  started=$SECONDS
  while [ $((SECONDS - started)) -lt "$limit" ]; do
    if ssh_ready; then
      log "ready after $((SECONDS - started))s"
      return 0
    fi
    vm_active || {
      log "VM exited during boot — journalctl --user -u $unit"
      return 1
    }
    sleep 2
  done
  log "ssh not ready after ${limit}s — journalctl --user -u $unit"
  return 1
}

start_bg() {
  # A socket left from an earlier boot would start the clock early.
  rm -f "$run_dir/qmp.sock"
  systemd-run --user --unit="$unit" --collect --quiet \
    --slice=ram-heavy.slice --property=OOMPolicy=kill \
    --setenv=XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}" \
    -- "$SELF" _serve
  if ! wait_ssh; then
    # A VM that never came up must not keep holding the memory lock.
    stop_bg
    die "boot failed; VM stopped"
  fi
}

stop_bg() {
  if systemctl --user is-active --quiet "$unit.service"; then
    systemctl --user stop "$unit.service"
  fi
}

require_up() {
  systemctl --user is-active --quiet "$unit.service" ||
    systemctl --user is-active --quiet feature-vm.scope ||
    die "no VM running — run: feature-vm up"
}

case "$cmd" in
  boot)
    vm_active && die "a VM is already running (feature-vm down)"
    prepare
    FEATURE_VM_DISPLAY="${FEATURE_VM_DISPLAY--display none}" \
      systemd-run --user --scope --quiet --collect --unit=feature-vm \
      --slice=ram-heavy.slice --property=OOMPolicy=kill \
      -- "$SELF" _serve "$@"
    ;;
  _serve) serve "$@" ;;
  up)
    vm_active && die "a VM is already running (feature-vm down)"
    prepare
    start_bg
    ;;
  run)
    [ $# -ge 1 ] || die "usage: feature-vm run 'CMD' | run PROG ARG..."
    require_up
    if [ $# -eq 1 ]; then
      remote="$1"
    else
      remote="$(printf '%q ' "$@")"
    fi
    exec ssh -p "$ssh_port" "${ssh_opts[@]}" jonathan@localhost "$remote"
    ;;
  ssh)
    require_up
    exec ssh -p "$ssh_port" "${interactive_ssh_opts[@]}" jonathan@localhost
    ;;
  put | get)
    [ $# -eq 2 ] || die "usage: feature-vm $cmd SRC DEST"
    require_up
    if [ "$cmd" = put ]; then
      src="$1" dest="jonathan@localhost:$2"
    else
      src="jonathan@localhost:$1" dest="$2"
    fi
    exec scp -r -P "$ssh_port" "${ssh_opts[@]}" "$src" "$dest"
    ;;
  apply)
    [ $# -le 1 ] || die "usage: feature-vm apply [MODULE.nix]"
    require_up
    load_config
    module=""
    if [ $# -eq 1 ]; then
      [ -f "$1" ] || die "no such module file: $1"
      module="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    fi
    # The running VM holds the memory-coordination lock; this build is its
    # child, not a competing job, so it must not queue behind it.
    top="$(NIX_MEMORY_COORDINATION_HELD=1 build_target toplevel "$host" "$flake" "$module")" ||
      die "build failed"
    log "activating $top"
    # The guest sees the host /nix/store, so the new system is already there.
    exec ssh -p "$ssh_port" "${ssh_opts[@]}" jonathan@localhost \
      "sudo $top/bin/switch-to-configuration test"
    ;;
  reset)
    require_up
    systemctl --user is-active --quiet "$unit.service" ||
      die "reset only works on a VM started with: feature-vm up"
    stop_bg
    start_bg
    ;;
  down)
    # A foreground VM is its launcher terminal's to stop; its run dir holds
    # the live sockets and disk overlay.
    if systemctl --user is-active --quiet feature-vm.scope; then
      die "a foreground VM is running; stop it in its terminal (Ctrl-C)"
    fi
    stop_bg
    rm -rf "$run_dir"
    rm -f "$state_dir"/root-*
    ;;
  status)
    if ! vm_active; then
      echo "down"
      exit 3
    fi
    load_config
    mode=locked
    [ "$trusted" = 1 ] && mode=trusted
    if ssh_ready; then ready=ssh-ready; else ready=booting; fi
    echo "up host=$host mode=$mode $ready flake=$flake"
    ;;
  screencap)
    [ $# -eq 1 ] || die "usage: feature-vm screencap OUT.png"
    require_up
    exec "$SCREENCAP" "$run_dir/qmp.sock" "$1"
    ;;
  *) die "unknown command $cmd (see --help)" ;;
esac
