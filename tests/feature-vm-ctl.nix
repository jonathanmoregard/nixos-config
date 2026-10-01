# feature-vm-ctl: runtime-invocation harness for scripts/feature-vm.sh.
#
# Runs the real launcher against fake `nix`, `systemd-run`, `systemctl`,
# `ssh` and QEMU, and pins the invariants that make the default VM a
# sandbox rather than a copy of the host with its keys:
#
#   - no boot, locked or trusted, exports any key of the user's to the VM
#     (and a key copy an older launcher staged is removed);
#   - a locked boot cuts guest networking (restrict=on) and exports every
#     share read-only; --trusted is the only way to writable shares + net;
#   - `run` passes the guest command's exit code through and quotes
#     multi-argument commands;
#   - `apply` builds as a child of the VM's memory lock, not a competitor
#     (otherwise it waits forever behind the VM it is meant to update);
#   - ssh to the VM checks its build-time host key (pinned known_hosts),
#     so commands never run on some other listener on localhost:2222;
#   - hostile host names are refused before they reach a nix attr path.
#
# Run: nix build .#checks.x86_64-linux.feature-vm-ctl -L
{ pkgs }:
let
  fakeRunner = pkgs.writeShellScriptBin "nix-memory-run" ''
    [ "$1" = -- ] && shift
    exec "$@"
  '';
  tool = import ../scripts/feature-vm.nix { inherit pkgs; memoryRunner = fakeRunner; };
in
pkgs.runCommand "feature-vm-ctl-harness"
  {
    nativeBuildInputs = with pkgs; [ bash coreutils gnugrep git python3 ];
  } ''
    set -euo pipefail
    export HOME=$TMPDIR/home
    export XDG_CACHE_HOME=$HOME/.cache
    mkdir -p $HOME/.ssh fakebin
    echo PRIVATE > $HOME/.ssh/id_ed25519
    log=$TMPDIR/calls
    : > $log

    # Fake VM: records what QEMU would have been started with.
    mkdir -p fakevm/bin
    cat > fakevm/bin/run-test-vm <<'EOF'
    #!/usr/bin/env bash
    { echo "QEMU_OPTS=$QEMU_OPTS"; echo "QEMU_NET_OPTS=$QEMU_NET_OPTS"; } > "$HOME/qemu-env"
    # FAKE_BOOT=1: behave like a QEMU that started (QMP socket, unit active).
    if [ "''${FAKE_BOOT:-0}" = 1 ]; then
      python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("qmp.sock")'
      touch "$HOME/vm-active"
    fi
    EOF
    cat > fakebin/nix <<EOF
    #!/usr/bin/env bash
    echo "nix held=\''${NIX_MEMORY_COORDINATION_HELD:-} \$*" >> $log
    case "\$*" in
      *"attr toplevel"*) echo /nix/store/fake-toplevel ;;
      *"attr hostkey"*) echo $PWD/fakekey ;;
      *) echo $PWD/fakevm ;;
    esac
    EOF
    cat > fakebin/systemd-run <<'EOF'
    #!/usr/bin/env bash
    while [ "$1" != -- ]; do shift; done
    shift
    exec "$@"
    EOF
    cat > fakebin/systemctl <<EOF
    #!/usr/bin/env bash
    echo "systemctl \$*" >> $log
    case "\$2" in
      is-active) [ -e "\$HOME/vm-active" ] || [ -e "\$HOME/active-\$4" ] ;;
      stop) rm -f "\$HOME/vm-active" ;;
    esac
    EOF
    cat > fakebin/ssh <<EOF
    #!/usr/bin/env bash
    printf '%s\n' "ssh \''${@: -1}" >> $log
    printf '%s\n' "\$*" >> $log.ssh-args
    exit \''${FAKE_SSH_RC:-0}
    EOF
    mkdir -p fakekey
    echo "ssh-ed25519 AAAAfakehostkey feature-vm" > fakekey/ssh_host_ed25519_key.pub
    chmod +x fakebin/* fakevm/bin/*
    patchShebangs fakebin fakevm >/dev/null
    export PATH=$PWD/fakebin:$PATH

    mkdir -p flake/modules/nixos research/agent research/scripts
    touch flake/flake.nix flake/modules/nixos/feature-vm.nix research/scripts/run-agent.sh
    export RESEARCH_AGENT_WORKTREE=$PWD/research
    fv() { ${tool}/bin/feature-vm --host test --flake $PWD/flake "$@"; }
    key=$XDG_CACHE_HOME/feature-vm/host-ssh/id_ed25519
    fail() { echo "FAIL: $*" >&2; cat $HOME/qemu-env >&2 || true; exit 1; }

    # A key copy staged by an earlier launcher version.
    mkdir -p $XDG_CACHE_HOME/feature-vm/host-ssh
    cp $HOME/.ssh/id_ed25519 $XDG_CACHE_HOME/feature-vm/host-ssh/

    # 1. trusted boot: shares writable, network open, still no key.
    fv --trusted
    grep -q '^QEMU_NET_OPTS=$' $HOME/qemu-env || fail "trusted boot restricted the network"
    grep -q 'mount_tag=worktrees ' $HOME/qemu-env || fail "trusted worktrees share not writable"
    [ ! -e $key ] || fail "the key copy an older launcher staged is still there"

    # 2. locked boot: net restricted, shares read-only.
    fv
    grep -q '^QEMU_NET_OPTS=restrict=on$' $HOME/qemu-env || fail "locked boot has guest network"
    grep -q 'mount_tag=worktrees,readonly=on' $HOME/qemu-env || fail "locked worktrees share writable"
    grep -q 'mount_tag=research-agent,readonly=on' $HOME/qemu-env || fail "locked research share writable"

    # Neither mode may hand the VM anything from ~/.ssh or a copy of it.
    if grep -q -e host-ssh -e '\.ssh' $HOME/qemu-env; then fail "a key directory is exported to the VM"; fi
    if grep -rq PRIVATE $XDG_CACHE_HOME; then fail "key material under the launcher's cache dir"; fi

    # What the VM runs from stays a GC root while it is up.
    grep -q -- "--out-link $XDG_CACHE_HOME/feature-vm/root-vm " $log || fail "booted VM is not a GC root"
    if grep -q -- '--no-link' $log; then fail "a launcher build leaves no GC root"; fi

    # The VM's host key is pinned, not trusted on first use.
    grep -qx '\[localhost\]:2222 ssh-ed25519 AAAAfakehostkey' $XDG_CACHE_HOME/feature-vm/known_hosts ||
      fail "VM host key not pinned: $(cat $XDG_CACHE_HOME/feature-vm/known_hosts 2>&1)"

    # 3. run: exit code passes through; multi-arg commands are quoted.
    touch $HOME/vm-active
    rc=0; FAKE_SSH_RC=7 fv run 'false' || rc=$?
    [ $rc -eq 7 ] || fail "run exit code $rc, want 7"
    fv run echo 'a b'
    grep -qx 'ssh echo a\\ b ' $log || fail "multi-arg run not quoted: $(tail -1 $log)"

    # 4. apply builds under the VM's lock and activates the built system.
    fv apply
    grep -q '^nix held=1 .*--argstr attr toplevel' $log ||
      fail "apply did not build the toplevel as a lock child"
    grep -qx 'ssh sudo /nix/store/fake-toplevel/bin/switch-to-configuration test' $log || fail "apply did not activate"

    # Every ssh to the VM checks the pinned key.
    if grep -qi 'StrictHostKeyChecking=\(n\)o' $log.ssh-args; then fail "an ssh call skips host key checking"; fi
    grep -q "StrictHostKeyChecking=yes -o UserKnownHostsFile=$XDG_CACHE_HOME/feature-vm/known_hosts" $log.ssh-args ||
      fail "ssh does not use the pinned known_hosts"

    # 5. refusals.
    rm $HOME/vm-active
    if ${tool}/bin/feature-vm --host 'x;rm' --flake $PWD/flake up 2>/dev/null; then fail "bad host accepted"; fi
    if fv run true 2>/dev/null; then fail "run without a VM succeeded"; fi
    if fv frobnicate 2>/dev/null; then fail "unknown command accepted"; fi

    # Options after the command are refused, not silently dropped.
    if fv up --trusted 2> opt.err; then fail "option after the command accepted"; fi
    grep -q 'options go first' opt.err || fail "wrong message: $(cat opt.err)"

    # down leaves a foreground VM (and its run dir) alone.
    mkdir -p $XDG_CACHE_HOME/feature-vm/run
    touch $HOME/active-feature-vm.scope
    if fv down 2> down.err; then fail "down claimed to stop a foreground VM"; fi
    [ -d $XDG_CACHE_HOME/feature-vm/run ] || fail "down removed a foreground VM's run dir"
    rm $HOME/active-feature-vm.scope

    # 6. up: returns once ssh answers after QEMU started.
    FAKE_BOOT=1 fv up 2> up.err || fail "up failed: $(cat up.err)"
    grep -q 'ready after' up.err || fail "up did not wait for ssh"

    # 7. up: a VM that exits before QEMU starts is reported, not waited on.
    rm $HOME/vm-active
    if fv up 2> up.err; then fail "up succeeded although the VM exited"; fi
    grep -q 'exited before QEMU started' up.err || fail "wrong up failure: $(cat up.err)"

    # 8. up: ssh never answers -> the VM is stopped, so it cannot sit on
    #    the memory lock.
    rc=0
    FAKE_BOOT=1 FAKE_SSH_RC=255 FEATURE_VM_BOOT_TIMEOUT=2 fv up 2> up.err || rc=$?
    [ $rc -ne 0 ] || fail "up succeeded without ssh"
    grep -q 'systemctl --user stop feature-vm-bg.service' $log || fail "failed boot left the VM running"
    [ ! -e $HOME/vm-active ] || fail "VM still active after failed boot"

    touch $out
  ''
