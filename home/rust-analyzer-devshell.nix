# rust-analyzer-devshell — the language server home/vscodium.nix points
# `rust-analyzer.server.path` at, so the editor's analysis runs inside the
# workspace's own nix devShell.
#
# Why it exists. rust-analyzer does not merely parse: it runs cargo, cargo
# runs every build script, and a build script links. This host has no global
# compiler — a project's toolchain lives in that project's devShell — and a
# VSCodium started from the desktop menu hands the server the login PATH. So
# the editor reported, for most of a Rust dependency graph:
#
#   error: linker `cc` not found
#   error: could not compile `serde` (build script)
#
# while `nix develop` in the same checkout had cc, pkg-config, OPENSSL_* and
# the project's rustc all along. Same class as `nix.serverPath` next to it in
# home/vscodium.nix, one layer deeper: nix-ide needed its binary pinned,
# rust-analyzer needs a whole environment.
#
# Three things this file is careful about, each pinned by a phase of
# tests/rust-analyzer-devshell.nix:
#
#   1. stdout is the LSP transport. A devShell's shellHook writes to stdout —
#      klaffat's prints a toolchain banner — so entering the shell naively
#      corrupts the first frame and the editor reports a protocol error. The
#      real stdout is parked on fd 3 across `nix develop` and handed to the
#      server only once the hook has run; the hook's own chatter lands on
#      stderr, which is where the editor's output channel reads from.
#
#   2. The server always starts. The devShell belongs to someone else's
#      flake and can fail to evaluate, go offline, or not exist. An editor
#      with no language server is worse than one without the project's
#      toolchain, so every failure route still execs the pinned server and
#      says so on stderr. The capability probe runs BEFORE the session
#      because once the server owns stdio there is no way back.
#
#   3. `--version` costs nothing. The extension validates a configured
#      server path by running it with --version before starting a session
#      and reports "Failed to execute ... --version" when that is slow or
#      fails; a capability probe has no project to resolve, so it must not
#      evaluate a flake. This is also why the session runs THIS pinned
#      server rather than whatever rust-analyzer the devShell happens to
#      carry: the version the extension validated is then the version it
#      talks to, and a project pinning an old nixpkgs cannot hand the
#      extension a server it refuses to drive.
#
# The devShell supplies the environment — cc, pkg-config, OPENSSL_*, the
# project's rustc and its sccache wrapper — which is the whole point.
#
# Two directories, deliberately kept apart. `nix develop` runs the shellHook
# in the CALLER's directory, not the flake root, and hooks write there:
# klaffat's does `mkdir -p data`, and its .gitignore entry for that is
# root-anchored (`/data/`). Entering from a crate subdirectory therefore left
# an untracked `crates/<x>/data` behind on every server start. So the shell is
# entered from the flake root, where a hook expects to be, and the server is
# handed its original directory back before it execs.
{ pkgs }:
let
  server = pkgs.rust-analyzer;
in
(pkgs.writeShellApplication {
  name = "rust-analyzer-devshell";
  runtimeInputs = [ pkgs.coreutils pkgs.bash pkgs.nix ];
  text = ''
    # Both pins are overridable for the same reason: a harness has to
    # displace them to observe anything (the SWEEP_GH_BIN pattern in
    # home/worktree-sweep-script.nix). nix is named rather than absolute so
    # PATH resolves the pinned copy above.
    server="''${RA_DEVSHELL_SERVER_BIN:-${server}/bin/rust-analyzer}"
    nix_bin="''${RA_DEVSHELL_NIX_BIN:-nix}"

    # Capability probe (see 3): answer it without touching a flake.
    if [ "$#" -eq 1 ]; then
      case "$1" in
        --version | --help | -h) exec "$server" "$@" ;;
      esac
    fi

    # The extension spawns the server with the workspace folder as its
    # working directory. Walk up from there: opening a single crate rather
    # than the workspace root is ordinary, and the flake is at the root.
    root=$PWD
    while [ "$root" != / ] && [ ! -e "$root/flake.nix" ]; do
      root=$(dirname "$root")
    done

    if [ ! -e "$root/flake.nix" ]; then
      echo "rust-analyzer-devshell: route=plain (no flake.nix above $PWD)" >&2
      exec "$server" "$@"
    fi

    # The directory the editor gave us, handed back to the server below.
    workspace=$PWD
    cd "$root" || {
      echo "rust-analyzer-devshell: route=plain (cannot enter $root)" >&2
      exec "$server" "$@"
    }

    # The probe's own diagnosis is the only thing that explains a degraded
    # session: without it the editor just reports `linker cc not found`
    # again, with nothing pointing at the flake that failed to evaluate.
    if ! probe_err=$("$nix_bin" develop --quiet "$root" --command true 2>&1 >/dev/null); then
      echo "rust-analyzer-devshell: route=plain ($root devShell would not start)" >&2
      # Truncated without a pipeline, on purpose. A `| head -20` consumer
      # closes the pipe after 20 lines, and a nix evaluation trace easily
      # exceeds the 64 KiB pipe buffer — writing into that closed pipe
      # raised SIGPIPE, errexit+pipefail turned it into the wrapper's exit
      # status, and the server this branch exists to start never started
      # (exit 141). The diagnostic must never be able to cost the editor
      # its language server.
      if [ -n "$probe_err" ]; then
        mapfile -t -n 20 probe_lines <<<"$probe_err"
        printf 'rust-analyzer-devshell:   %s\n' "''${probe_lines[@]}" >&2
      fi
      exec "$server" "$@"
    fi

    echo "rust-analyzer-devshell: route=devshell ($root)" >&2

    # fd 3 carries the LSP stream past the shellHook (see 1). The inner
    # shell returns to the workspace directory, restores stdout and closes
    # the spare before the server inherits anything.
    exec 3>&1 1>&2
    # shellcheck disable=SC2016 # $0/$@ are for the inner shell, not this one
    exec "$nix_bin" develop --quiet "$root" --command bash -c '
      cd "$1" || echo "rust-analyzer-devshell: could not return to $1" >&2
      shift
      exec 1>&3 3>&-
      exec "$0" "$@"
    ' "$server" "$workspace" "$@"
  '';
}).overrideAttrs (old: {
  # The harness compares the server's wrapped stdout against an unwrapped
  # run of the same binary, so it needs the one this wrapper pins.
  passthru = (old.passthru or { }) // { inherit server; };
})
