{ pkgs, sweepScript, deployedExecStart, deployedTimer, worktreeSweepTimer }:
# Fail-closed contract harness for cargo-target-sweep.
#
# Destructive automation ships only behind a test that proves each KEEP
# predicate actually keeps. Every arm builds a real fixture and asserts on
# the sweep's own journal output and on what survives on disk.
#
# FIXTURES ARE REAL CARGO BUILDS. An earlier revision hand-wrote plausible
# files into `target/`, which passed every arm while testing almost nothing:
# `cargo sweep --time` reads `.fingerprint` metadata to decide what to prune,
# so against a hand-made tree it cleaned 0 bytes and pass B was never
# exercised (measured 2026-11-11). Every fixture here is produced by an
# actual `cargo build --offline` of a dependency-free lib crate — rlib only,
# so no linker is needed in the sandbox.
#
# The arms that matter most are the negative ones: a directory merely NAMED
# `target`, a target dir a lane is building in, and a manifest whose target
# dir cargo resolves somewhere else. Those are the three ways this job could
# destroy work it must not touch.

pkgs.runCommand "cargo-target-sweep-contract"
{
  nativeBuildInputs = [
    sweepScript
    pkgs.cargo
    pkgs.rustc
    pkgs.coreutils
    pkgs.diffutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.python3
    pkgs.util-linux
  ];
  # Passed as derivation attributes, matching tests/worktree-sweep.nix:
  # home-manager renders ExecStart as a list, and Nix coerces it to the
  # plain path here. Comparing it inside Nix with toJSON would instead
  # compare `["..."]` against `"..."` and fail on the brackets alone.
  inherit deployedExecStart;
  inherit (deployedTimer) OnCalendar RandomizedDelaySec;
  wtOnCalendar = worktreeSweepTimer.OnCalendar;
  wtRandomizedDelaySec = worktreeSweepTimer.RandomizedDelaySec;
} ''
  set -euo pipefail

  export HOME=$TMPDIR/home
  # Cargo needs a writable CARGO_HOME; the sandbox has no default one.
  export CARGO_HOME=$TMPDIR/cargo
  ROOT=$HOME/worktrees
  mkdir -p "$ROOT" "$CARGO_HOME"

  CARGO_TAG='Signature: 8a477f597d28d172a0f0f2f52a2b2447'

  # A genuine cargo target dir: built by cargo, so it carries the
  # .fingerprint metadata cargo-sweep needs and the deps/ layout that the
  # age computation has to cope with.
  mk_real() { # crate-name [dir-name] -> prints the worktree path
    local wt="$ROOT/''${2:-$1}"
    mkdir -p "$wt/src"
    printf 'pub fn f() -> u32 { 1 }\n' > "$wt/src/lib.rs"
    printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\npath = "src/lib.rs"\n' "$1" > "$wt/Cargo.toml"
    ( cd "$wt" && cargo build --offline ) > "$TMPDIR/build-$1.log" 2>&1 \
      || { echo "FATAL: cargo build failed for fixture $1"; cat "$TMPDIR/build-$1.log"; exit 1; }
    printf '%s\n' "$wt"
  }

  backdate() { # dir, days — the CONTENTS, not just the directory
    find "$1" -mindepth 1 -exec touch -d "$2 days ago" {} +
    touch -d "$2 days ago" "$1"
  }

  # Arm 8 deliberately plants an unreadable subdir, so `find` exits non-zero
  # here; with errexit + pipefail that silently killed this harness itself
  # before it printed a single line. Tolerate the walk's exit status — the
  # unreadable subtree is invisible to both the before and the after walk,
  # so the comparison stays sound.
  snapshot() { { find "$ROOT" -printf '%p|%T@|%i\n' 2>/dev/null || true; } | sort; }
  findq() { find "$@" 2>/dev/null || true; }

  # ---------------------------------------------------------------- arm 1
  # A directory merely NAMED target, with no cargo marker, is never touched.
  # This is the gate that stops the job eating unrelated data.
  mkdir -p "$ROOT/decoy/target/precious"
  printf '[package]\nname = "decoy"\n' > "$ROOT/decoy/Cargo.toml"
  printf 'do not delete me\n' > "$ROOT/decoy/target/precious/data.txt"
  backdate "$ROOT/decoy/target" 400

  # ---------------------------------------------------------------- arm 2
  # A stale, unlocked, genuine target dir is removed.
  STALE=$(mk_real stale); backdate "$STALE/target" 90

  # ---------------------------------------------------------------- arm 3
  # An ACTIVE target dir is pruned, not cleaned: the artifacts older than
  # the prune age go, the recent ones stay. The old harness only checked
  # that `CLEAN` was absent, so a sweep that silently did nothing at all to
  # an active directory passed it.
  ACTIVE=$(mk_real active)
  printf 'stale artifact\n' > "$ACTIVE/target/debug/deps/libstaleart-0000000000000000.rlib"
  touch -d "90 days ago" "$ACTIVE/target/debug/deps/libstaleart-0000000000000000.rlib"

  # ---------------------------------------------------------------- arm 4
  # A stale target dir whose Cargo lock is HELD by a lane that is otherwise
  # idle — the lane holds the lock fd and nothing else. The lock fd is
  # deliberately excluded from the liveness scan, so this arm reaches the
  # flock predicate instead of being short-circuited by /proc. Before that
  # exclusion this arm always tripped LIVE and the flock branch was dead
  # code: replacing `flock -n` with `true` still passed the old harness.
  LOCKED=$(mk_real locked); backdate "$LOCKED/target" 90
  touch "$LOCKED/target/.klaffat-cargo.lock"
  exec {held}>>"$LOCKED/target/.klaffat-cargo.lock"
  flock -n "$held" || { echo "FATAL: could not take fixture lock"; exit 1; }

  # ---------------------------------------------------------------- arm 5
  # A stale target dir with no manifest beside it is kept — the scoped tool
  # would have nothing to aim at, and an unowned tree is not ours to judge.
  mkdir -p "$ROOT/nomanifest/target"
  printf '%s\n' "$CARGO_TAG" > "$ROOT/nomanifest/target/CACHEDIR.TAG"
  backdate "$ROOT/nomanifest/target" 90

  # ---------------------------------------------------------------- arm 6
  # DEEP MTIME. `cargo check` writes into target/debug/deps/, which bumps
  # deps/ but leaves debug/ and target/ alone. An age read from the target
  # dir's depth-1 entries therefore reports a tree built seconds ago as 90
  # DAYS OLD — reproduced on tuxedo 2026-11-11 — and the sweep deletes a
  # directory that is being built into right now. This is the arm that
  # blocked the first revision of this PR.
  DEEP=$(mk_real deep); backdate "$DEEP/target" 90
  printf 'pub fn f() -> u32 { 2 }\n' > "$DEEP/src/lib.rs"
  ( cd "$DEEP" && cargo check --offline ) > "$TMPDIR/build-deep-recheck.log" 2>&1 \
    || { echo "FATAL: cargo check failed for the deep fixture"; cat "$TMPDIR/build-deep-recheck.log"; exit 1; }
  # FIXTURE REALISM GUARD. The previous revision of this harness backdated
  # every fixture uniformly, so the trap shape was never present and the arm
  # passed against a script that had the bug. Assert the trap exists here,
  # before the sweep runs — pruning this directory bumps debug/'s mtime, so
  # it cannot be checked afterwards. depth-1 must read as ancient while the
  # tree as a whole is seconds old; that gap IS the defect.
  deep_now=$(date +%s)
  deep_d1=$(findq "$DEEP/target" -maxdepth 1 -mindepth 1 -printf '%T@\n' | sort -n | tail -1 | cut -d. -f1)
  deep_all=$(findq "$DEEP/target" -mindepth 1 -printf '%T@\n' | sort -n | tail -1 | cut -d. -f1)
  test -n "$deep_d1" && test -n "$deep_all" \
    || { echo "FAIL arm6 fixture: could not read the deep fixture's mtimes"; exit 1; }
  test "$(((deep_now - deep_d1) / 86400))" -ge 14 \
    || { echo "FAIL arm6 fixture: depth-1 reads $(((deep_now - deep_d1) / 86400))d — this arm no longer reproduces the trap"; exit 1; }
  test "$(((deep_now - deep_all) / 86400))" -eq 0 \
    || { echo "FAIL arm6 fixture: the tree is not actually fresh — nothing was written deep inside it"; exit 1; }
  echo "arm6 fixture: depth-1 reads $(((deep_now - deep_d1) / 86400))d, deepest write $(((deep_now - deep_all) / 86400))d"

  # ------------------------------------------------------ host /proc shape
  # On a real host most /proc/N/{cwd,fd,maps} belong to other users and are
  # unreadable (521 of 817 on tuxedo, 2026-11-11). `find` and `gawk` then
  # exit non-zero EVEN WHEN THEY MATCHED, and a liveness test that reads
  # their exit status reports every live directory as idle — reproduced on
  # tuxedo: a shell cd'd into a target dir, an fd held in it and a mapping
  # out of it all read "not live". The single-uid sandbox has no such
  # entries, so arms 7-7e passed against that script. A NON-DUMPABLE process
  # of our own uid gets root-owned /proc entries, which is the host's shape.
  python3 -c 'import ctypes, time; ctypes.CDLL(None).prctl(4, 0, 0, 0, 0); time.sleep(600)' &
  ndpid=$!
  sleep 1
  # Open, don't `test -r`: maps is mode 0444 whatever the dumpable flag, and
  # the ptrace access check that refuses it only happens at open().
  ! cat "/proc/$ndpid/maps" >/dev/null 2>&1 && ! readlink "/proc/$ndpid/cwd" >/dev/null 2>&1 \
    || { echo "FATAL host-shape: the non-dumpable neighbour's /proc entries are readable — arms 7-7e would not model the host"; exit 1; }

  # ---------------------------------------------------------------- arm 7
  # LIVE. A process holding an fd on a real artifact inside a stale target
  # dir protects the whole directory.
  LIVEWT=$(mk_real livefd); backdate "$LIVEWT/target" 90
  exec {livefd}<"$LIVEWT/target/.rustc_info.json"

  # ---------------------------------------------------------------- arm 7b
  # CWD branch. A shell sitting in the target dir holds no fd inside it, so
  # only the cwd scan can see it.
  CWDWT=$(mk_real livecwd); backdate "$CWDWT/target" 90
  ( cd "$CWDWT/target" && exec sleep 300 ) &
  cwdpid=$!

  # ---------------------------------------------------------------- arm 7c
  # MAPPED-FILE branch. A running rustc maps .rlib/.so straight out of the
  # target dir without holding a conventional fd — the header calls this the
  # reason the maps scan exists, and nothing else in this harness reaches it.
  # A binary executing from inside the tree is the same shape: no open fd, no
  # cwd inside it, only a mapping. Replace the maps scan with `false` and
  # this arm is the one that fails.
  MAPWT=$(mk_real livemap)
  # Keep the basename: nixpkgs' coreutils is a multi-call binary that
  # dispatches on argv[0], so a copy named anything else exits immediately
  # with "unknown program" and the fixture would silently test nothing.
  cp "$(command -v sleep)" "$MAPWT/target/debug/sleep"
  # Backdate AFTER copying — the copy bumps debug/'s mtime, which would
  # otherwise make this fixture merely active and never reach the question
  # the arm is asking.
  backdate "$MAPWT/target" 90
  "$MAPWT/target/debug/sleep" 300 &
  mappid=$!
  sleep 1   # let it map itself in
  grep -qF "$MAPWT/target/debug/sleep" "/proc/$mappid/maps" \
    || { echo "FATAL arm7c: fixture process is not mapped out of the target dir"; exit 1; }

  # ---------------------------------------------------------------- arm 7d
  # PATTERN CHARACTERS IN THE PATH. A liveness match that treats the
  # directory as a glob (`find -lname "$dir/*"`) never matches a worktree
  # named with [ ] * ?, so a shell sitting inside one reads as idle.
  GLOBWT=$(mk_real globcwd 'glob [1]'); backdate "$GLOBWT/target" 90
  ( cd "$GLOBWT/target" && exec sleep 300 ) &
  globpid=$!

  # ---------------------------------------------------------------- arm 7e
  # SPACES IN A MAPPED PATH. /proc/N/maps is whitespace-separated, so reading
  # the path as field 6 truncates "map [1]/..." at the space and the mapping
  # is never matched.
  SPMAPWT=$(mk_real spacemap 'map [1]')
  cp "$(command -v sleep)" "$SPMAPWT/target/debug/sleep"
  backdate "$SPMAPWT/target" 90
  "$SPMAPWT/target/debug/sleep" 300 &
  spmappid=$!
  sleep 1
  grep -qF "$SPMAPWT/target/debug/sleep" "/proc/$spmappid/maps" \
    || { echo "FATAL arm7e: fixture process is not mapped out of the target dir"; exit 1; }

  # ---------------------------------------------------------------- arm 8
  # ERREXIT. writeShellApplication's preamble sets errexit and the script's
  # own `set -uo pipefail` does NOT clear it, so one unreadable subdir used
  # to abort the entire sweep — every later directory silently unswept.
  # The tell is the summary line: it is only reached if the loop completed.
  UNREAD=$(mk_real unreadable)
  mkdir -p "$UNREAD/target/debug/locked-away"
  printf 'x\n' > "$UNREAD/target/debug/locked-away/thing"
  # Backdate BEFORE chmod; chmod changes ctime, not mtime.
  backdate "$UNREAD/target" 90
  # ...then write something FRESH inside, and make the directory unwalkable.
  # `find` cannot descend into it, so the recent file is invisible and an
  # incomplete walk reports "nothing recent" = stale. Reproduced 2026-11-11:
  # a tree written to seconds earlier was judged stale this way. Staleness
  # that could not be established must not be assumed.
  printf 'built just now\n' > "$UNREAD/target/debug/locked-away/fresh"
  # The directory's OWN mtime must read old, or find sees it as a recent hit
  # and quits before it ever tries to descend — which is correct behaviour
  # for a different shape, and would leave this arm testing nothing.
  touch -d "90 days ago" "$UNREAD/target/debug/locked-away"
  chmod 000 "$UNREAD/target/debug/locked-away"

  # ---------------------------------------------------------------- arm 9
  # ADOPT. A detached dir left behind by a sweep killed mid-clean is
  # adopted on the next run — but only when the pid that detached it is
  # gone. A live pid's detached dir belongs to a running sweep.
  DEADPID=4194300
  test ! -d "/proc/$DEADPID" || { echo "FATAL: fixture pid $DEADPID exists"; exit 1; }
  ORPHAN=$(mk_real orphan)
  mv "$ORPHAN/target" "$ORPHAN/target.sweeping.$DEADPID"
  INUSE=$(mk_real inuse)
  mv "$INUSE/target" "$INUSE/target.sweeping.$$"

  # ------------------------------------------------------------ dry run
  # A dry run must reach the same verdicts while leaving the filesystem
  # byte-identical. The old script opened the lock file with `>>` BEFORE
  # testing DRY_RUN, which created it and bumped the parent directory's
  # mtime — a "dry" run that wrote to every directory it inspected.
  snapshot > before.txt
  CARGO_TARGET_SWEEP_DRY_RUN=1 cargo-target-sweep > dry.log 2>&1 || true
  snapshot > after.txt
  echo "--- dry run ---"; cat dry.log

  if ! diff -u before.txt after.txt > dryrun.diff; then
    echo "FAIL dry-run: the dry run modified the filesystem:"; cat dryrun.diff; exit 1
  fi
  test -z "$(findq "$ROOT" -name .klaffat-cargo.lock -newer before.txt)" \
    || { echo "FAIL dry-run: created a cargo lock file"; exit 1; }
  grep -q 'WOULD-CLEAN.*stale' dry.log \
    || { echo "FAIL dry-run: did not plan to clean the stale target"; exit 1; }
  grep -q 'WOULD-ADOPT.*orphan' dry.log \
    || { echo "FAIL dry-run: did not plan to adopt the detached dir"; exit 1; }

  # ------------------------------------------------------------ real run
  cargo-target-sweep > run.log 2>&1 || true
  echo "--- real run ---"; cat run.log

  exec {held}>&-
  exec {livefd}>&-
  kill "$cwdpid" "$mappid" "$globpid" "$spmappid" "$ndpid" 2>/dev/null || true
  for p in "$cwdpid" "$mappid" "$globpid" "$spmappid" "$ndpid"; do wait "$p" 2>/dev/null || true; done

  # ----------------------------------------------------------- assertions

  # arm 1: the decoy survives, with its contents intact
  test -f "$ROOT/decoy/target/precious/data.txt" \
    || { echo "FAIL arm1: deleted a directory that only happened to be named target"; exit 1; }
  grep -q 'KEEP.*decoy.*no cargo marker' run.log \
    || { echo "FAIL arm1: decoy was not kept for the documented reason"; exit 1; }

  # arm 2: the stale target dir is gone, its SOURCE is not, and it was
  # DETACHED before being cleaned — see arm 11 for why that ordering is the
  # whole safety property.
  test ! -e "$STALE/target" \
    || { echo "FAIL arm2: stale target dir survived"; exit 1; }
  test -f "$STALE/Cargo.toml" && test -f "$STALE/src/lib.rs" \
    || { echo "FAIL arm2: sweep destroyed source next to the target dir"; exit 1; }
  test -z "$(findq "$STALE" -maxdepth 1 -name 'target.sweeping.*')" \
    || { echo "FAIL arm2: detached dir was left behind"; exit 1; }
  d_line=$(grep -n "DETACH $STALE/target" run.log | head -1 | cut -d: -f1)
  c_line=$(grep -n "CLEAN .*$STALE/target\$" run.log | head -1 | cut -d: -f1)
  test -n "$d_line" && test -n "$c_line" && [ "$d_line" -lt "$c_line" ] \
    || { echo "FAIL arm2: clean was not preceded by a detach (detach=$d_line clean=$c_line)"; exit 1; }

  # arm 3: the active dir is pruned — old artifact gone, recent ones kept,
  # and the directory itself still there.
  grep -q "PRUNE .*$ACTIVE/target" run.log \
    || { echo "FAIL arm3: an active target dir was not pruned"; cat run.log; exit 1; }
  grep -q "CLEAN .*$ACTIVE/target" run.log \
    && { echo "FAIL arm3: an active target dir was cleaned wholesale"; exit 1; }
  test ! -e "$ACTIVE/target/debug/deps/libstaleart-0000000000000000.rlib" \
    || { echo "FAIL arm3: prune left the stale artifact behind — pass B does nothing"; exit 1; }
  test -n "$(findq "$ACTIVE/target" -name 'libactive*')" \
    || { echo "FAIL arm3: prune removed the current build artifacts"; exit 1; }

  # arm 4: lock held -> kept, and kept for the FLOCK reason specifically.
  # Asserting the reason is what makes the flock branch testable at all.
  test -d "$LOCKED/target" \
    || { echo "FAIL arm4: deleted a target dir an in-flight lane was holding"; exit 1; }
  grep -q "KEEP   $LOCKED/target — cargo lock held by a running lane" run.log \
    || { echo "FAIL arm4: locked dir not kept by the flock predicate"; cat run.log; exit 1; }

  # arm 5: no manifest, no action
  test -d "$ROOT/nomanifest/target" \
    || { echo "FAIL arm5: swept a target dir with no manifest"; exit 1; }
  grep -q 'KEEP.*nomanifest.*no Cargo\.toml' run.log \
    || { echo "FAIL arm5: nomanifest not kept for the documented reason"; exit 1; }

  # arm 6: a tree whose only recent write is deep under debug/deps/ is NOT
  # stale, however old its depth-1 entries look.
  #
  # FIXTURE REALISM GUARD FIRST. The previous revision of this harness
  # backdated every fixture uniformly, so the trap shape was never present
  # and the arm passed against a script that had the bug. Assert the trap
  # exists before asserting the sweep survives it: depth-1 must still read
  # as ancient while the tree as a whole is seconds old.
  # (the trap-shape guard ran at fixture-creation time: pruning this
  # directory bumps debug/'s mtime, so it cannot be checked after the run)
  grep -q "CLEAN .*$DEEP/target" run.log \
    && { echo "FAIL arm6: a tree written to seconds ago was judged stale from depth-1 mtimes"; exit 1; }
  test -d "$DEEP/target" \
    || { echo "FAIL arm6: deleted a target dir that was written to seconds ago"; exit 1; }

  # arm 7: an open fd on an artifact protects the directory
  test -d "$LIVEWT/target" \
    || { echo "FAIL arm7: deleted a target dir with a live fd inside it"; exit 1; }
  grep -q "KEEP   $LIVEWT/target — LIVE" run.log \
    || { echo "FAIL arm7: live dir not kept for the documented reason"; cat run.log; exit 1; }

  # arm 7b: a process whose CWD is the target dir, holding no fd in it
  test -d "$CWDWT/target" \
    || { echo "FAIL arm7b: deleted a target dir a process was sitting in"; exit 1; }
  grep -q "KEEP   $CWDWT/target — LIVE" run.log \
    || { echo "FAIL arm7b: the cwd branch of the liveness scan did not fire"; cat run.log; exit 1; }

  # arm 7c: a binary MAPPED out of the target dir, with no fd and no cwd
  test -d "$MAPWT/target" \
    || { echo "FAIL arm7c: deleted a target dir a running process was mapped out of"; exit 1; }
  grep -q "KEEP   $MAPWT/target — LIVE" run.log \
    || { echo "FAIL arm7c: the mapped-file branch of the liveness scan did not fire"; cat run.log; exit 1; }

  # arm 7d: cwd inside a path containing glob characters and a space
  test -d "$GLOBWT/target" \
    || { echo "FAIL arm7d: deleted a target dir a process was sitting in (glob chars in path)"; exit 1; }
  grep -qF "KEEP   $GLOBWT/target — LIVE" run.log \
    || { echo "FAIL arm7d: liveness treated the path as a pattern"; cat run.log; exit 1; }

  # arm 7e: mapping out of a path containing a space
  test -d "$SPMAPWT/target" \
    || { echo "FAIL arm7e: deleted a target dir a process was mapped out of (space in path)"; exit 1; }
  grep -qF "KEEP   $SPMAPWT/target — LIVE" run.log \
    || { echo "FAIL arm7e: the maps scan truncated a path at a space"; cat run.log; exit 1; }

  # arm 8: an unwalkable subtree makes staleness unprovable, so the tree is
  # kept — not detached on the strength of a walk that could not see the
  # file written seconds ago.
  test -d "$UNREAD/target" \
    || { echo "FAIL arm8: detached a tree whose staleness could not be established"; exit 1; }
  test -f "$UNREAD/target/debug/locked-away/fresh" 2>/dev/null \
    || chmod 755 "$UNREAD/target/debug/locked-away" 2>/dev/null || true
  grep -q "KEEP   $UNREAD/target — could not walk the whole tree" run.log \
    || { echo "FAIL arm8: the incomplete walk was not reported as unprovable"; cat run.log; exit 1; }
  # ...and the loop still reached its summary. errexit is set by
  # writeShellApplication's preamble and `set -uo pipefail` does not clear
  # it, so one bad directory used to abort every later one.
  grep -q '^cargo-target-sweep: cleaned=' run.log \
    || { echo "FAIL arm8: the sweep aborted before its summary — errexit killed the loop"; exit 1; }

  # arm 9: dead pid adopted, live pid left alone
  test ! -e "$ORPHAN/target.sweeping.$DEADPID" \
    || { echo "FAIL arm9: a detached dir from a dead sweep was not adopted"; exit 1; }
  grep -q "ADOPT .*$ORPHAN/target.sweeping.$DEADPID" run.log \
    || { echo "FAIL arm9: adoption not logged"; exit 1; }
  test -d "$INUSE/target.sweeping.$$" \
    || { echo "FAIL arm9: stole a detached dir belonging to a LIVE sweep"; exit 1; }

  # --------------------------------------------------------------- arm 10
  # AGE REGRESSION. Taking the Cargo lock CREATES .klaffat-cargo.lock inside
  # the target dir, which bumps that directory's own mtime to now. If age
  # were read from the directory itself, the first sweep would reset the age
  # of everything it merely INSPECTED and no later run would clean anything
  # — the job would quietly do nothing forever. Same shape as the atime bug
  # that stopped systemd-tmpfiles reaping /tmp.
  #
  # The previous harness checked this with two DRY runs. A dry run writes
  # nothing by design, so the very hazard it named could not occur and the
  # arm passed unconditionally. Use the REAL run above instead: it took the
  # lock on livefd's target (creating the file) and then kept the directory
  # because a process held an fd inside it. That fd is now closed.
  test -f "$LIVEWT/target/.klaffat-cargo.lock" \
    || { echo "FAIL arm10: the real run never created a lock file — this arm would prove nothing"; exit 1; }
  lockmt=$(stat -c %Y "$LIVEWT/target")
  nowmt=$(date +%s)
  test "$((nowmt - lockmt))" -lt 86400 \
    || { echo "FAIL arm10: taking the lock did not bump the directory mtime — the hazard is not present"; exit 1; }
  CARGO_TARGET_SWEEP_DRY_RUN=1 cargo-target-sweep > age2.log 2>&1 || true
  grep -q "WOULD-CLEAN.*$LIVEWT/target" age2.log \
    || { echo "FAIL arm10: a prior sweep reset the directory's age — the job would never clean anything again"; cat age2.log; exit 1; }

  # --------------------------------------------------------------- arm 11
  # DETACH PROPERTY — of the PRIMITIVE, not of the script. This arm does not
  # run cargo-target-sweep; it replays mv + cargo clean directly to pin the
  # technique the script relies on. The script's own use of it is asserted in
  # arm 2 (DETACH is logged, and logged before CLEAN).
  #
  # Why the technique: `cargo clean` unlinks the lock file the sweep is
  # holding, so from the first unlink onwards a competing lane recreates it
  # (new inode), takes the flock, and builds into a directory whose files are
  # disappearing. Measured 2026-11-11: the competitor got the lock
  # immediately.
  PROP=$(mk_real property)
  : > "$PROP/target/.klaffat-cargo.lock"
  exec {sweepfd}>>"$PROP/target/.klaffat-cargo.lock"
  flock -n "$sweepfd" || { echo "FATAL: could not take property-arm lock"; exit 1; }
  ino_held=$(stat -c %i "$PROP/target/.klaffat-cargo.lock")
  mv "$PROP/target" "$PROP/target.sweeping.probe"
  # A lane arriving now makes its own target dir and its own lock.
  mkdir -p "$PROP/target"
  : > "$PROP/target/.klaffat-cargo.lock"
  ino_lane=$(stat -c %i "$PROP/target/.klaffat-cargo.lock")
  printf 'lane artifact\n' > "$PROP/target/lane-is-building"
  test "$ino_held" != "$ino_lane" \
    || { echo "FAIL arm11: detach did not separate the inodes"; exit 1; }
  CARGO_TARGET_DIR="$PROP/target.sweeping.probe" cargo clean --manifest-path "$PROP/Cargo.toml" >/dev/null 2>&1
  exec {sweepfd}>&-
  test ! -e "$PROP/target.sweeping.probe" \
    || { echo "FAIL arm11: the detached dir was not cleaned"; exit 1; }
  test -f "$PROP/target/lane-is-building" \
    || { echo "FAIL arm11: cleaning the detached dir destroyed the lane's fresh target dir"; exit 1; }

  # --------------------------------------------------------------- arm 12
  # REDIRECTED TARGET DIR. CARGO_TARGET_DIR is not the only way to move a
  # manifest's target directory: CARGO_BUILD_TARGET_DIR and `build.target-dir`
  # in $CARGO_HOME/config.toml do it too, and the latter is read in
  # production because this runs as a user unit with CARGO_HOME=~/.cargo.
  # The sweep must refuse rather than aim a clean at a path it never
  # inspected.
  REDIR=$(mk_real redirected); backdate "$REDIR/target" 90
  mkdir -p "$TMPDIR/elsewhere"
  printf 'precious\n' > "$TMPDIR/elsewhere/do-not-delete"
  printf '[build]\ntarget-dir = "%s"\n' "$TMPDIR/elsewhere" > "$CARGO_HOME/config.toml"
  cargo-target-sweep > redir.log 2>&1 || true
  rm -f "$CARGO_HOME/config.toml"
  echo "--- redirect run ---"; cat redir.log
  test -d "$REDIR/target" \
    || { echo "FAIL arm12: swept a target dir cargo resolves somewhere else"; exit 1; }
  test -f "$TMPDIR/elsewhere/do-not-delete" \
    || { echo "FAIL arm12: the clean was aimed at the redirected directory"; exit 1; }
  grep -q "KEEP   $REDIR/target — cargo resolves this manifest's target dir to '$TMPDIR/elsewhere' — refusing to aim a clean elsewhere" redir.log \
    || { echo "FAIL arm12: redirection was not detected"; cat redir.log; exit 1; }

  # Belt-and-braces: the same hazard via the environment.
  REDIR2=$(mk_real redirected-env); backdate "$REDIR2/target" 90
  CARGO_BUILD_TARGET_DIR="$TMPDIR/elsewhere" cargo-target-sweep > redir2.log 2>&1 || true
  test -f "$TMPDIR/elsewhere/do-not-delete" \
    || { echo "FAIL arm12b: CARGO_BUILD_TARGET_DIR from the environment redirected the clean"; exit 1; }
  test ! -e "$REDIR2/target" \
    || { echo "FAIL arm12b: unsetting CARGO_BUILD_TARGET_DIR did not restore normal operation"; cat redir2.log; exit 1; }

  # --------------------------------------------------------------- arm 13
  # THE UNIT MUST BE ABLE TO FAIL. systemd reports the last command's status
  # as the service result, and the last statement of the script is a log
  # line — so a run that failed to detach or failed to clean exited 0, the
  # unit was recorded as successful, and the host's unit-failure notifier
  # never fired. A sweep that cannot report failure is a sweep nobody finds
  # out has stopped working.
  UNDET=$(mk_real undetachable); backdate "$UNDET/target" 90
  chmod 555 "$UNDET"          # parent unwritable => the rename must fail
  set +e
  cargo-target-sweep > failrun.log 2>&1
  failrc=$?
  set -e
  chmod 755 "$UNDET"
  echo "--- failing run (rc=$failrc) ---"; cat failrun.log
  grep -q "FAIL   could not detach $UNDET/target" failrun.log \
    || { echo "FAIL arm13: the fixture did not actually fail to detach — the arm proves nothing"; exit 1; }
  test "$failrc" -ne 0 \
    || { echo "FAIL arm13: a run with a failed detach still exited 0 — systemd would call this a success"; exit 1; }
  grep -qE '^cargo-target-sweep: .*failed=[1-9]' failrun.log \
    || { echo "FAIL arm13: the summary did not count the failure"; exit 1; }
  test -d "$UNDET/target" \
    || { echo "FAIL arm13: the undetachable target dir went away anyway"; exit 1; }

  # Also pin the other half: a clean run must exit 0, or the unit would be
  # reported as failed every single day.
  set +e
  CARGO_TARGET_SWEEP_DRY_RUN=1 cargo-target-sweep > okrun.log 2>&1
  okrc=$?
  set -e
  test "$okrc" -eq 0 \
    || { echo "FAIL arm13: a run with no failures exited $okrc"; cat okrun.log; exit 1; }

  # ------------------------------------------------------- drift gate
  # The deployed user unit must exec exactly the derivation tested above,
  # or this harness proves nothing about what actually runs.
  expected="${sweepScript}/bin/cargo-target-sweep"
  if [ "$deployedExecStart" != "$expected" ]; then
    echo "FAIL drift: unit execs '$deployedExecStart' but the tested derivation is '$expected'"
    exit 1
  fi

  # ------------------------------------------------------- schedule gate
  # The two sweeps walk the same trees, so they are scheduled apart rather
  # than both at midnight. A comment claiming an offset is worthless if the
  # units do not actually have one — the previous revision's comment said
  # "offset from worktree-sweep's window" while both read OnCalendar=daily.
  if [ "$OnCalendar" = "$wtOnCalendar" ]; then
    echo "FAIL schedule: cargo-target-sweep and worktree-sweep share OnCalendar='$OnCalendar'"
    exit 1
  fi
  echo "schedule: cargo-target-sweep '$OnCalendar' +$RandomizedDelaySec; worktree-sweep '$wtOnCalendar' +$wtRandomizedDelaySec"

  echo "all cargo-target-sweep contract arms passed"
  touch $out
''
