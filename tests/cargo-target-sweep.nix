{ pkgs, sweepScript, deployedExecStart }:
# Fail-closed contract harness for cargo-target-sweep.
#
# Destructive automation ships only behind a test that proves each KEEP
# predicate actually keeps. Every arm builds a real fixture and asserts on
# the sweep's own journal output and on what survives on disk.
#
# The arms that matter most are the negative ones: a directory merely NAMED
# `target`, and a target dir whose Cargo lock is held by a running lane.
# Those are the two ways this job could destroy work it must not touch.

pkgs.runCommand "cargo-target-sweep-contract"
{
  nativeBuildInputs = [ sweepScript pkgs.coreutils pkgs.gnugrep pkgs.util-linux ];
  # Passed as a derivation attribute, matching tests/worktree-sweep.nix:
  # home-manager renders ExecStart as a list, and Nix coerces it to the
  # plain path here. Comparing it inside Nix with toJSON would instead
  # compare `["..."]` against `"..."` and fail on the brackets alone.
  inherit deployedExecStart;
} ''
  set -euo pipefail

  export HOME=$TMPDIR/home
  # Cargo needs a writable CARGO_HOME; the sandbox has no default one.
  export CARGO_HOME=$TMPDIR/cargo
  ROOT=$HOME/worktrees
  mkdir -p "$ROOT" "$CARGO_HOME"

  CARGO_TAG='Signature: 8a477f597d28d172a0f0f2f52a2b2447'

  # A realistic cargo target dir: manifest beside it, Cargo's CACHEDIR.TAG
  # inside it, and an artifact to account for.
  mk_target() { # name, age_days
    local wt="$ROOT/$1" age="$2"
    mkdir -p "$wt/target/debug" "$wt/src"
    # A real, resolvable package: `cargo clean` parses the manifest and
    # refuses a stub, so a stub fixture would test nothing.
    printf 'fn main() {}\n' > "$wt/src/lib.rs"
    printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\npath = "src/lib.rs"\n' "$1" > "$wt/Cargo.toml"
    printf '%s\n' "$CARGO_TAG" > "$wt/target/CACHEDIR.TAG"
    printf 'artifact\n' > "$wt/target/debug/libthing.rlib"
    # Backdate the CONTENTS, not just the directory: age is derived from the
    # newest real artifact precisely so that a sweep touching the directory
    # (by creating its lock file) cannot reset it. A fixture that backdated
    # only the directory would be testing the bug, not the fix.
    find "$wt/target" -mindepth 1 -exec touch -d "$age days ago" {} +
    touch -d "$age days ago" "$wt/target"
    printf '%s\n' "$wt"
  }

  # ---------------------------------------------------------------- arm 1
  # A directory merely NAMED target, with no Cargo CACHEDIR.TAG, is never
  # touched. This is the gate that stops the job eating unrelated data.
  mkdir -p "$ROOT/decoy/target/precious"
  printf '[package]\nname = "decoy"\n' > "$ROOT/decoy/Cargo.toml"
  printf 'do not delete me\n' > "$ROOT/decoy/target/precious/data.txt"
  touch -d "400 days ago" "$ROOT/decoy/target"

  # ---------------------------------------------------------------- arm 2
  # A stale, unlocked, genuine target dir is removed.
  mk_target stale 90 >/dev/null

  # ---------------------------------------------------------------- arm 3
  # A fresh target dir is not removed wholesale.
  mk_target fresh 1 >/dev/null

  # ---------------------------------------------------------------- arm 4
  # A stale target dir whose Cargo lock is HELD by a running lane is kept.
  # This is the predicate protecting in-flight parallel builds.
  LOCKED=$(mk_target locked 90)
  touch "$LOCKED/target/.klaffat-cargo.lock"
  exec {held}>>"$LOCKED/target/.klaffat-cargo.lock"
  flock -n "$held" || { echo "FATAL: could not take fixture lock"; exit 1; }

  # ---------------------------------------------------------------- arm 5
  # A stale target dir with no manifest beside it is kept — the scoped tool
  # would have nothing to aim at, and an unowned tree is not ours to judge.
  mkdir -p "$ROOT/nomanifest/target"
  printf '%s\n' "$CARGO_TAG" > "$ROOT/nomanifest/target/CACHEDIR.TAG"
  touch -d "90 days ago" "$ROOT/nomanifest/target"

  # ------------------------------------------------------------------ run
  # Dry run first: it must reach the same verdicts without changing anything.
  CARGO_TARGET_SWEEP_DRY_RUN=1 cargo-target-sweep > dry.log 2>&1 || true
  echo "--- dry run ---"; cat dry.log

  test -d "$ROOT/stale/target" \
    || { echo "FAIL: dry run deleted the stale target dir"; exit 1; }
  grep -q 'WOULD-CLEAN.*stale' dry.log \
    || { echo "FAIL: dry run did not plan to clean the stale target"; exit 1; }

  cargo-target-sweep > run.log 2>&1 || true
  echo "--- real run ---"; cat run.log

  exec {held}>&-

  # ----------------------------------------------------------- assertions
  # arm 1: the decoy survives, with its contents intact
  test -f "$ROOT/decoy/target/precious/data.txt" \
    || { echo "FAIL arm1: deleted a directory that only happened to be named target"; exit 1; }
  grep -q 'KEEP.*decoy.*no cargo marker' run.log \
    || { echo "FAIL arm1: decoy was not kept for the documented reason"; exit 1; }

  # arm 2: the stale target dir is gone, and its SOURCE is not
  test ! -e "$ROOT/stale/target/debug/libthing.rlib" \
    || { echo "FAIL arm2: stale artifacts survived"; exit 1; }
  test -f "$ROOT/stale/Cargo.toml" \
    || { echo "FAIL arm2: sweep destroyed source next to the target dir"; exit 1; }

  # arm 3: fresh is not cleaned wholesale
  grep -q 'CLEAN.*fresh' run.log \
    && { echo "FAIL arm3: a fresh target dir was cleaned wholesale"; exit 1; }

  # arm 4: a target dir an in-flight lane is holding must survive. Either
  # protective predicate may be the one that fires — in practice /proc does,
  # because holding a flock means holding an fd and that fd is visible
  # there. What must never happen is the artifacts going away.
  test -f "$ROOT/locked/target/debug/libthing.rlib" \
    || { echo "FAIL arm4: deleted a target dir an in-flight lane was holding"; exit 1; }
  grep -qE 'KEEP.*locked.*(cargo lock held|LIVE)' run.log \
    || { echo "FAIL arm4: locked dir not kept for a documented protective reason"; exit 1; }
  grep -q 'CLEAN.*locked' run.log \
    && { echo "FAIL arm4: locked dir was cleaned"; exit 1; }

  # arm 5: no manifest, no action
  test -d "$ROOT/nomanifest/target" \
    || { echo "FAIL arm5: swept a target dir with no manifest"; exit 1; }
  grep -q 'KEEP.*nomanifest.*no Cargo\.toml' run.log \
    || { echo "FAIL arm5: nomanifest not kept for the documented reason"; exit 1; }

  # ---------------------------------------------------------------- arm 6
  # REGRESSION GATE. Taking the Cargo lock creates .klaffat-cargo.lock
  # inside the target dir, which bumps that directory's mtime. If age were
  # read from the directory itself, the first sweep would reset the age of
  # everything it merely INSPECTED, and no later run would ever clean
  # anything — the job would quietly do nothing forever. This is the exact
  # shape of the atime bug that stopped systemd-tmpfiles reaping /tmp.
  #
  # The dry run above already inspected (and therefore lock-touched) every
  # fixture. A second stale fixture introduced only now would not prove
  # that, so assert on one the dry run already walked: it must STILL be
  # judged stale on a later run.
  mk_target lingering 90 >/dev/null
  CARGO_TARGET_SWEEP_DRY_RUN=1 cargo-target-sweep > age1.log 2>&1 || true
  grep -q 'WOULD-CLEAN.*lingering' age1.log \
    || { echo "FAIL arm6: fixture not seen as stale on first pass"; cat age1.log; exit 1; }

  CARGO_TARGET_SWEEP_DRY_RUN=1 cargo-target-sweep > age2.log 2>&1 || true
  grep -q 'WOULD-CLEAN.*lingering' age2.log \
    || { echo "FAIL arm6: a prior sweep reset the directory's age — the job would never clean anything again"; cat age2.log; exit 1; }

  # ---------------------------------------------------------------- arm 7
  # REALISM GATE. Every real target dir on the host this ships to carries
  # NO CACHEDIR.TAG — measured 2026-11-11: 0 of 91. Cargo marks them with
  # .rustc_info.json and .fingerprint instead. An earlier revision gated on
  # CACHEDIR.TAG alone and passed every arm above while being a total no-op
  # in production: it rejected all 91 real directories and reported success.
  # This arm is shaped like the real thing, so that can never recur.
  REALISTIC="$ROOT/realistic"
  mkdir -p "$REALISTIC/target/debug/.fingerprint" "$REALISTIC/src"
  printf 'fn main() {}\n' > "$REALISTIC/src/lib.rs"
  printf '[package]\nname = "realistic"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\npath = "src/lib.rs"\n' > "$REALISTIC/Cargo.toml"
  printf '{}\n' > "$REALISTIC/target/.rustc_info.json"
  printf 'artifact\n' > "$REALISTIC/target/debug/libreal.rlib"
  test ! -e "$REALISTIC/target/CACHEDIR.TAG"   # the whole point of this arm
  find "$REALISTIC/target" -mindepth 1 -exec touch -d "90 days ago" {} +
  touch -d "90 days ago" "$REALISTIC/target"

  CARGO_TARGET_SWEEP_DRY_RUN=1 cargo-target-sweep > real.log 2>&1 || true
  grep -q 'WOULD-CLEAN.*realistic' real.log \
    || { echo "FAIL arm7: a realistically-marked cargo target dir was not recognised — the job would be a no-op in production"; cat real.log; exit 1; }

  # ------------------------------------------------------- drift gate
  # The deployed user unit must exec exactly the derivation tested above,
  # or this harness proves nothing about what actually runs.
  expected="${sweepScript}/bin/cargo-target-sweep"
  if [ "$deployedExecStart" != "$expected" ]; then
    echo "FAIL drift: unit execs '$deployedExecStart' but the tested derivation is '$expected'"
    exit 1
  fi

  echo "all cargo-target-sweep contract arms passed"
  touch $out
''
