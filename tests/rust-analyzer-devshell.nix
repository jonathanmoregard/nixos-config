# rust-analyzer-devshell: runtime-invocation harness for the language-server
# wrapper home/vscodium.nix points `rust-analyzer.server.path` at
# (home/rust-analyzer-devshell.nix — the exact derivation the editor spawns,
# asserted below via deployedServerPath rather than a copy that can drift).
#
# Not a VM lane: it boots nothing, stubs `nix` and drives the real wrapper
# against fixture trees. Runs in seconds.
#
# The incident it pins down (2026-10-27): a VSCodium started from the desktop
# menu hands rust-analyzer the login PATH, and NixOS has no global compiler,
# so every build script in a Rust workspace failed with
#
#   error: linker `cc` not found
#
# while the project's own `nix develop` had cc, pkg-config and OPENSSL_* all
# along. The fix runs the server inside the workspace's devShell, which puts
# two things at risk that only a harness can hold:
#
#   A. stdout is the LSP transport. A devShell's shellHook writes to stdout
#      (klaffat's prints a toolchain banner), so entering the shell naively
#      corrupts the first frame the editor reads — the editor then reports a
#      protocol error, not a banner. Phase E is that proof: the banner must
#      land on stderr and the server's own stdout must arrive byte-intact.
#   B. the server must always start. The devShell is someone else's flake and
#      can fail to evaluate; an editor with no language server at all is a
#      worse outcome than one without the project's toolchain, so every
#      failure route still execs the pinned server (phases B and D).
#
# Phase A pins the extension's own precondition: it validates the configured
# server by running `<path> --version` before it starts a session and reports
# "Failed to execute ... --version" if that is slow or fails. A capability
# probe has no project to resolve, so it must never pay for a flake
# evaluation — asserted by the stub log staying empty.
#
# Run: nix build .#checks.x86_64-linux.rust-analyzer-devshell -L
{ pkgs, raDevshell, deployedSettings }:

let
  wrapper = "${raDevshell}/bin/rust-analyzer-devshell";
in
pkgs.runCommand "rust-analyzer-devshell"
{
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.bash pkgs.jq ];
} ''
  set -euo pipefail

  # Drift gate: read the settings.json the primary host really deploys and
  # require that it spawns the derivation under test. A rename, or a setting
  # dropped from home/vscodium.nix, fails here instead of leaving this lane
  # green while the editor runs something else.
  configured=$(jq -r '."rust-analyzer.server.path" // "<unset>"' ${deployedSettings})
  if [ "$configured" != "${wrapper}" ]; then
    echo "the deployed VSCodium settings.json spawns" >&2
    echo "  $configured" >&2
    echo "but the derivation under test is" >&2
    echo "  ${wrapper}" >&2
    exit 1
  fi

  export HOME=$PWD
  export NIX_STUB_LOG=$PWD/nix.log

  # ── Fixtures ────────────────────────────────────────────────────────────
  # `plain` has no flake.nix anywhere above it: the sandbox build directory
  # is not a flake, which is what makes the negative route testable at all.
  mkdir -p plain repo/crates/web
  echo '{ outputs = _: { }; }' > repo/flake.nix
  repo=$PWD/repo

  # ── Stub nix ────────────────────────────────────────────────────────────
  # writeShellApplication pins the real nix ahead of PATH, so the wrapper
  # takes its binary from RA_DEVSHELL_NIX_BIN (the SWEEP_GH_BIN pattern in
  # tests/worktree-sweep.nix). The stub models the two calls the wrapper
  # makes and, in session mode, the shellHook-on-stdout behaviour that
  # phase E exists for.
  mkdir -p stub stub/devshell-bin
  export HOOK_CWD=$PWD/hook-cwd
  export RECORDER_LOG=$PWD/recorder.log
  export STUB_DEVSHELL_BIN=$PWD/stub/devshell-bin

  # Stands in for the compiler a real devShell puts on PATH and the login
  # environment does not have — the absence that started all this.
  printf '#!/bin/sh\necho fixture-cc\n' > stub/devshell-bin/cc
  chmod +x stub/devshell-bin/cc

  cat > stub/nix <<'STUB'
  #!/bin/sh
  echo "$*" >> "$NIX_STUB_LOG"
  [ "$1" = develop ] || { echo "stub nix: unexpected argv: $*" >&2; exit 64; }
  root=$3
  [ -e "$root/flake.nix" ] || { echo "stub nix: no flake.nix at $root" >&2; exit 1; }
  shift 4
  if [ "$1" = true ]; then
    if [ "''${RA_STUB_PROBE_FAIL:-0}" = 1 ]; then
      echo "stub nix: error: fixture flake does not evaluate" >&2
      exit 1
    fi
    exit 0
  fi
  # What entering a devShell gives the command: an environment it did not
  # have, and a shellHook that writes to the CALLER's directory.
  echo "STUB-SHELLHOOK-BANNER"
  echo "$PWD" > "$HOOK_CWD"
  PATH="$STUB_DEVSHELL_BIN:$PATH"
  export PATH
  RA_STUB_DEVSHELL_MARKER=from-devshell
  export RA_STUB_DEVSHELL_MARKER
  exec "$@"
  STUB
  sed -i 's/^  //' stub/nix
  chmod +x stub/nix
  export RA_DEVSHELL_NIX_BIN=$PWD/stub/nix

  # A server that reports what it inherited. The real rust-analyzer cannot
  # be asked, so without this the lane could only check the SHAPE of the
  # nix invocation and would stay green if the environment, the working
  # directory or the argv were dropped on the way through.
  cat > stub/recorder <<'REC'
  #!/bin/sh
  {
    echo "pwd=$PWD"
    echo "argv=$*"
    echo "cc=$(command -v cc || echo none)"
    echo "marker=''${RA_STUB_DEVSHELL_MARKER:-unset}"
  } > "$RECORDER_LOG"
  echo "RECORDER-STDOUT"
  REC
  sed -i 's/^  //' stub/recorder
  chmod +x stub/recorder

  run() { # run <cwd> <expected-exit> [args...]
    local cwd=$1 want=$2; shift 2
    : > "$NIX_STUB_LOG"
    set +e
    ( cd "$cwd" && "${wrapper}" "$@" ) > out.txt 2> err.txt
    local rc=$?
    set -e
    if [ "$rc" != "$want" ]; then
      echo "exit $rc, expected $want (cwd=$cwd argv=$*)" >&2
      echo "--- stdout ---" >&2; cat out.txt >&2
      echo "--- stderr ---" >&2; cat err.txt >&2
      exit 1
    fi
  }

  # ── A. The extension's --version probe never evaluates a flake ──────────
  # Both from a plain directory and from inside the fixture flake: a cold
  # evaluation here is what the extension reports as a broken server path.
  for where in plain repo; do
    run "$where" 0 --version
    grep -qi 'rust-analyzer' out.txt \
      || { echo "[A/$where] --version printed no version:"; cat out.txt; exit 1; }
    if [ -s "$NIX_STUB_LOG" ]; then
      echo "[A/$where] --version evaluated a flake:" >&2; cat "$NIX_STUB_LOG" >&2; exit 1
    fi
  done
  echo "[A] --version answers from the pinned server, no nix call"

  # ── B. No flake above the workspace: the server still starts ────────────
  run plain 2 --ra-devshell-probe
  grep -q 'route=plain' err.txt \
    || { echo "[B] no route=plain line:"; cat err.txt; exit 1; }
  grep -q 'unexpected flag' err.txt \
    || { echo "[B] the pinned server was never reached:"; cat err.txt; exit 1; }
  [ ! -s "$NIX_STUB_LOG" ] \
    || { echo "[B] called nix without a flake:"; cat "$NIX_STUB_LOG"; exit 1; }
  echo "[B] no flake.nix above cwd -> pinned server, no nix call"

  # ── C. Walk-up from a crate subdirectory ────────────────────────────────
  # The extension spawns the server in the workspace folder, which is not
  # always the flake root (opening crates/klaffat-web directly is ordinary).
  run repo/crates/web 2 --ra-devshell-probe
  grep -q "route=devshell ($repo)" err.txt \
    || { echo "[C] did not walk up to $repo:"; cat err.txt; exit 1; }
  grep -qx "develop --quiet $repo --command true" "$NIX_STUB_LOG" \
    || { echo "[C] no capability probe for $repo:"; cat "$NIX_STUB_LOG"; exit 1; }
  grep -q "develop --quiet $repo --command bash -c" "$NIX_STUB_LOG" \
    || { echo "[C] no session call for $repo:"; cat "$NIX_STUB_LOG"; exit 1; }
  echo "[C] crate subdirectory resolves to the workspace flake"

  # ── D. A devShell that will not start degrades, never blocks ────────────
  RA_STUB_PROBE_FAIL=1 run repo 2 --ra-devshell-probe
  grep -q 'devShell would not start' err.txt \
    || { echo "[D] no degrade line:"; cat err.txt; exit 1; }
  # And says WHY. Without the probe's own diagnosis the editor reports only
  # the original `linker cc not found`, with nothing naming the flake that
  # failed — the degrade route is the one that most needs explaining.
  grep -q 'fixture flake does not evaluate' err.txt \
    || { echo "[D] degraded silently, no cause reported:"; cat err.txt; exit 1; }
  grep -q 'unexpected flag' err.txt \
    || { echo "[D] the pinned server was never reached:"; cat err.txt; exit 1; }
  grep -qx "develop --quiet $repo --command true" "$NIX_STUB_LOG" \
    || { echo "[D] probe missing:"; cat "$NIX_STUB_LOG"; exit 1; }
  grep -q 'bash -c' "$NIX_STUB_LOG" \
    && { echo "[D] started a session after a failed probe:"; cat "$NIX_STUB_LOG"; exit 1; }
  echo "[D] unusable devShell -> pinned server, no session"

  # ── E. stdout belongs to the LSP stream, the shellHook does not ─────────
  # --print-config-schema is the one server invocation that writes real
  # bytes to stdout and exits, so it stands in for a session's first frame.
  run repo 0 --print-config-schema
  grep -q 'STUB-SHELLHOOK-BANNER' out.txt \
    && { echo "[E] shellHook output corrupted the LSP stream:"; head -c 200 out.txt; exit 1; }
  grep -q 'STUB-SHELLHOOK-BANNER' err.txt \
    || { echo "[E] shellHook output went nowhere; stderr was:"; cat err.txt; exit 1; }
  head -c1 out.txt | grep -q '\[' \
    || { echo "[E] server stdout is not the config schema:"; head -c 200 out.txt; exit 1; }
  # Byte-identical to the same server run outside the wrapper: nothing is
  # prepended, appended, or swallowed on the way through the devShell.
  ${raDevshell.server}/bin/rust-analyzer --print-config-schema > expected.json
  cmp out.txt expected.json \
    || { echo "[E] server stdout differs from an unwrapped run"; exit 1; }
  echo "[E] shellHook banner -> stderr, server stdout byte-intact"

  # ── F. What the server actually inherits ────────────────────────────────
  # The acceptance criterion is not "nix develop was invoked", it is "the
  # server runs with the devShell's environment". Phases C-E can only see
  # the shape of the invocation; this one swaps in a server that reports
  # its own environment, working directory and argv.
  rm -f "$RECORDER_LOG" "$HOOK_CWD"
  RA_DEVSHELL_SERVER_BIN=$PWD/stub/recorder \
    run repo/crates/web 0 --some-server-flag value
  [ -f "$RECORDER_LOG" ] \
    || { echo "[F] the server never ran"; cat err.txt; exit 1; }

  grep -qx "cc=$STUB_DEVSHELL_BIN/cc" "$RECORDER_LOG" \
    || { echo "[F] server did not inherit the devShell PATH:"; cat "$RECORDER_LOG"; exit 1; }
  grep -qx 'marker=from-devshell' "$RECORDER_LOG" \
    || { echo "[F] server did not inherit the devShell environment:"; cat "$RECORDER_LOG"; exit 1; }
  grep -qx 'argv=--some-server-flag value' "$RECORDER_LOG" \
    || { echo "[F] argv was not passed through:"; cat "$RECORDER_LOG"; exit 1; }

  # The server keeps the directory the editor gave it, while the shellHook
  # ran at the flake root. A hook that writes relative paths (klaffat's
  # `mkdir -p data`, .gitignore'd only as root-anchored `/data/`) would
  # otherwise litter whichever crate directory the editor happened to open.
  grep -qx "pwd=$repo/crates/web" "$RECORDER_LOG" \
    || { echo "[F] server lost its workspace directory:"; cat "$RECORDER_LOG"; exit 1; }
  [ "$(cat "$HOOK_CWD")" = "$repo" ] \
    || { echo "[F] shellHook ran in $(cat "$HOOK_CWD"), expected $repo"; exit 1; }

  grep -qx 'RECORDER-STDOUT' out.txt \
    || { echo "[F] server stdout did not arrive:"; cat out.txt; exit 1; }
  grep -q 'STUB-SHELLHOOK-BANNER' out.txt \
    && { echo "[F] banner reached the LSP stream:"; cat out.txt; exit 1; }
  echo "[F] server inherits the devShell env, keeps its workspace dir, hook runs at the root"

  touch $out
''
