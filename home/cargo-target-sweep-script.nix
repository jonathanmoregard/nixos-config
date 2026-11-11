{ pkgs
, # Directories scanned for cargo target dirs. Anything outside them is
  # never touched. Matches worktree-sweep's roots so the two agree on what
  # counts as disposable workspace.
  roots ? [ "$HOME/worktrees" "$HOME/Repos/nixos-config-worktrees" ]
, # A target dir untouched for this long is removed outright.
  maxAgeDays ? 14
, # Inside a target dir that is still active, artifacts older than this are
  # pruned individually by cargo-sweep.
  pruneAgeDays ? 14
}:

# cargo-target-sweep — reclaim Cargo build artifacts whose lifetime has come
# uncoupled from the worktree that owns them.
#
# WHY THIS EXISTS. On 2026-11-10 `~/worktrees` held 2.26 TB, ~60% of a 3.7 TB
# disk, and 2.2 TB of that (97%) was cargo `target/`. 85 of 172 target dirs
# had September or October mtimes while their worktrees were legitimately
# alive. worktree-sweep correctly refuses to remove those worktrees — dirty,
# unmerged, or recently active — so the artifacts were never reachable by any
# existing cleanup. A worktree can be alive while its target/ is a month dead.
#
# WHY DELETION IS SAFE HERE. klaffat's flake sets RUSTC_WRAPPER=sccache
# (~/.cache/sccache) precisely so that target dirs are disposable: its own
# comment says "rebuilds after target cleanup reuse ~/.cache/sccache instead".
# Removing a target dir costs link time, not compile time. Source, dirty
# working-tree changes, branches and .git are never touched by anything here.
#
# TWO PASSES, both liveness-gated:
#   A. target dir untouched >= maxAgeDays  -> detached, then removed via
#                                             `cargo clean`
#   B. target dir still active             -> `cargo sweep --time` prunes only
#                                             the stale artifacts inside it
# Pass B is what keeps long-lived worktrees from silently re-accumulating;
# pass A is what reclaims the backlog.
#
# WHY `cargo clean` AND `cargo sweep`, NOT `rm -rf`. Both are scoped by
# construction: they can only ever touch the target directory belonging to the
# manifest they are handed. A stray root or a symlinked path cannot turn
# either into a recursive delete of something else. That scoping is only as
# good as the target directory cargo actually resolves, which is why
# predicate (4) below pins it rather than assuming it.
#
# FAIL-CLOSED CONTRACT (asserted by tests/cargo-target-sweep.nix). Every
# predicate must positively hold or the directory is kept, and the reason is
# logged. Silence is never consent.
#
#   1. path matches <root>/*/target and resolves (after symlink resolution)
#      to a location still inside that root
#   2. it really is a Cargo target dir — CACHEDIR.TAG with Cargo's own
#      signature, .rustc_info.json, or a profile .fingerprint dir. This is
#      what stops a directory merely NAMED `target` from being deleted.
#   3. a Cargo.toml sits beside it, so the scoped tool has a manifest
#   4. `cargo metadata` resolves that manifest's target directory to exactly
#      this path. CARGO_TARGET_DIR is not the only way to redirect it:
#      CARGO_BUILD_TARGET_DIR and `build.target-dir` in any .cargo/config.toml
#      on the cwd ancestry (notably ~/.cargo/config.toml, which IS on it when
#      this runs as a user unit) redirect it too. Measured 2026-11-11: with
#      CARGO_BUILD_TARGET_DIR set, `cargo metadata` reported the redirected
#      path — so asking cargo is the check, and unsetting is only the belt.
#   5. the per-worktree Cargo lock (.klaffat-cargo.lock) can be taken
#      non-blocking — the same lock ~/Repos/klaffat/scripts/with-cargo-lock
#      takes, so a lane holding it is never interrupted — and, once taken,
#      no OTHER process holds the lock file open: with-cargo-lock opens it
#      and then blocks in flock(), so an open fd on it is a waiting lane
#   6. no live process has cwd, an open fd, or a mapped file inside it
#      — mapped files matter: a running rustc maps .rlib/.so straight out
#        of the target dir without holding a conventional fd
#      — this check is taken FRESH, per directory, while the lock is held,
#        and is the last thing before acting. An earlier revision took one
#        /proc snapshot up front; a `cargo` started by hand after that
#        snapshot (it takes no klaffat lock) would have been swept
#        mid-build. One snapshot per candidate costs ~0.05s.
#      — it cannot close the window on its own: a `cargo` that starts
#        between the check and the rename keeps its files through the
#        rename. So the check is asked AGAIN on the detached path, where
#        anything that opened files before the rename is still visible and
#        nothing new can arrive (a newcomer resolves `target`, which is now
#        a fresh directory). A hit there moves the directory back.
#
# Predicates 5 and 6 are what make this safe against the standing constraint
# that parallel klaffat lanes run constantly: destroying a lane's target dir
# mid-build loses hours and can corrupt a run reporting into a PR.
#
# WHY PASS A DETACHES BEFORE CLEANING. `cargo clean` unlinks everything in the
# target dir — including the lock file this sweep is holding. Measured
# 2026-11-11: with the sweep still holding its fd, a competing lane recreated
# .klaffat-cargo.lock (new inode) and took the flock immediately, i.e. the
# mutual exclusion is gone the moment the clean starts, exactly while the
# files are disappearing. So pass A renames `target` to
# `target.sweeping.<pid>` first — one atomic rename in the parent directory —
# and cleans the detached path. A lane arriving mid-delete then creates a
# fresh empty `target/` and builds into it: a cold build, never a build whose
# files vanish underneath it. A sweep killed between the rename and the clean
# leaves a detached dir behind, which the next run adopts (see ADOPT below),
# gated on the recorded pid no longer existing.
#
# Age is deliberately NOT read from the target dir's own mtime, nor from its
# depth-1 entries — see the comment at the age computation. Getting that wrong
# makes the job delete directories that are being built into right now.

let
  inherit (pkgs) lib;
  rootsStr = lib.concatStringsSep " " (map (r: ''"${r}"'') roots);
in
pkgs.writeShellApplication {
  name = "cargo-target-sweep";
  runtimeInputs = with pkgs; [
    cargo
    cargo-sweep
    coreutils
    findutils
    gawk
    gnugrep
    jq
    util-linux
  ];
  text = ''
    set -uo pipefail
    # writeShellApplication's preamble sets errexit, and `set -uo pipefail`
    # above does NOT clear it (measured: a bare `false` aborted the script).
    # A sweep must survive one bad directory: `du` on a tree with an
    # unreadable subdir, a vanished path, a manifest cargo dislikes. Every
    # predicate here is tested explicitly and every failure is logged, so
    # errexit buys nothing and costs the rest of the run.
    set +e

    MAX_AGE_DAYS=${toString maxAgeDays}
    PRUNE_AGE_DAYS=${toString pruneAgeDays}
    DRY_RUN=''${CARGO_TARGET_SWEEP_DRY_RUN:-0}
    ROOTS=(${rootsStr})

    # Belt for predicate (4)'s braces: these redirect the target dir cargo
    # resolves, and a stray value from the environment would aim every clean
    # below somewhere else. The metadata check is what actually enforces it.
    unset CARGO_TARGET_DIR CARGO_BUILD_TARGET_DIR

    log() { printf '%s\n' "$*"; }
    keep() { log "KEEP   $2 — $1"; }
    # Counted so the unit can fail. systemd treats the last command's status
    # as the service result, and the last command here is a log line, so
    # without this every failed detach and failed clean would report success
    # and the host's unit-failure notifier would never fire.
    failures=0
    fail() { log "FAIL   $*"; failures=$((failures + 1)); }

    LOCK_NAME=.klaffat-cargo.lock
    release_lock() {
      if [ -n "''${lockfd:-}" ]; then
        exec {lockfd}>&-
        lockfd=""
      fi
      return 0
    }

    # Liveness depends entirely on /proc. If it cannot be read, nothing below
    # can establish that a directory is idle, and the fail-closed contract
    # says refuse rather than guess.
    if [ ! -r /proc/self/maps ] || [ ! -L /proc/self/cwd ]; then
      log "ABORT  /proc is not readable — cannot verify liveness; refusing to sweep"
      exit 1
    fi

    # Fresh liveness scan for ONE directory: cwd, open fds and mapped files of
    # every process. Returns 0 when something live is inside it.
    #
    # Two scans, each ONE process rather than one per pid. The per-pid shape
    # this replaces spawned readlink for every fd and awk for every process:
    # measured on tuxedo with 822 processes it cost 7.4s PER DIRECTORY, 11+
    # minutes across the 91 real target dirs, and — worse than slow — every
    # one of those seconds sat between the liveness check and the delete it
    # was meant to guard. The single-process form measures 0.04s and 0.009s,
    # so the window it leaves is a window in name only.
    #
    # The coordination lock file is excluded: holding only that fd is what a
    # waiting lane looks like, and the flock predicate is what handles it.
    # Without this exclusion the flock branch could never fire — the holder
    # would always look LIVE first — and so could never be tested either.
    #
    # KNOWN LIMIT: /proc entries belonging to other users are unreadable here
    # and are silently skipped, so a process running as another user (a root
    # build in the user's worktree) is not seen. The swept trees are the
    # user's own and the unit runs as that user, so this is out of scope
    # rather than handled; it is not a case this sweep can detect.
    #
    # THE SIGNAL IS OUTPUT, NEVER EXIT STATUS. On a real host most /proc
    # entries belong to other users, so `find` and `gawk` exit non-zero on
    # EACCES even after they matched — and under pipefail that read as "not
    # live". Reproduced on tuxedo 2026-11-11: a shell cd'd into a target dir,
    # an fd held in it and a mapping out of it all read idle, and the harness
    # (single-uid sandbox, no unreadable entries) passed regardless.
    #
    # PATHS ARE STRINGS, NEVER PATTERNS. `-lname "$dir/*"` is a glob, so a
    # worktree named with [ ] * ? never matched; maps' path is read as the
    # rest of the line after five fields, not as $6, which truncates at a
    # space.
    is_live() {
      local dir=$1 lock="$1/$LOCK_NAME" hit
      hit=$(find /proc/[0-9]*/cwd /proc/[0-9]*/fd -maxdepth 1 -type l -printf '%l\n' 2>/dev/null \
              | awk -v d="$dir" -v lk="$lock" \
                  '$0 != lk && ($0 == d || index($0, d "/") == 1) { print "hit"; exit }')
      [ -n "$hit" ] && return 0
      # Mapped files matter on their own: a running rustc maps .rlib/.so
      # straight out of the target dir without holding a conventional fd.
      # gawk treats an unopenable input file as FATAL and never reaches the
      # files after it (measured: one non-dumpable neighbour sorted first hid
      # every mapping behind it), so unreadable maps are skipped explicitly.
      hit=$(awk -v d="$dir/" -v lk="$lock" \
              'BEGINFILE { if (ERRNO != "") nextfile }
               { p = $0; if (!sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", p)) next }
               p != lk && index(p, d) == 1 { print "hit"; exit }' \
              /proc/[0-9]*/maps 2>/dev/null)
      [ -n "$hit" ] && return 0
      return 1
    }

    # Does any process OTHER than this sweep hold the lock file $1 open?
    # Called only with the flock in our hands, so such a process is a lane
    # blocked in flock(LOCK_EX): with-cargo-lock opens the file and then
    # waits. is_live() excludes the lock path, so it cannot see one.
    #
    # The scan runs in a subshell that first closes its inherited copy of
    # the lock fd, so neither it nor find/awk shows up as a holder; the main
    # shell's own fd is excluded by pid. Signal is output, as in is_live().
    lock_waiters() {
      local lock=$1 hit
      [ -e "$lock" ] || return 1
      hit=$(
        if [ -n "''${lockfd:-}" ]; then exec {lockfd}>&-; fi
        find /proc/[0-9]*/fd -maxdepth 1 -type l -printf '%h %l\n' 2>/dev/null \
          | awk -v lk="$lock" -v me="/proc/$$/fd" '
              { sp = index($0, " ") }
              substr($0, sp + 1) == lk && substr($0, 1, sp - 1) != me { print "hit"; exit }'
      )
      [ -n "$hit" ]
    }

    # Is anything under $1 newer than the staleness cutoff?
    #
    # Prints "active", "stale", "empty", or "unreadable". The last is the
    # point: `find` cannot descend into an unreadable subdirectory, and a
    # fresh file inside one is therefore invisible — measured, a tree whose
    # only recent write sat under a mode-000 directory reported NO recent
    # files and would have been detached and cleaned. An incomplete walk
    # cannot establish staleness, so it is not allowed to.
    staleness() {
      local dir=$1 err hit
      err=$(mktemp) || { printf 'unreadable\n'; return; }
      hit=$(find "$dir" -mindepth 1 ! -name "$LOCK_NAME" \
              -newermt "@$cutoff" -print -quit 2>"$err")
      if [ -s "$err" ]; then
        rm -f "$err"
        printf 'unreadable\n'
        return
      fi
      rm -f "$err"
      if [ -n "$hit" ]; then
        printf 'active\n'
      elif [ -z "$(find "$dir" -mindepth 1 ! -name "$LOCK_NAME" -print -quit 2>/dev/null)" ]; then
        printf 'empty\n'
      else
        printf 'stale\n'
      fi
    }

    log "cargo-target-sweep: max-age ''${MAX_AGE_DAYS}d; prune-age ''${PRUNE_AGE_DAYS}d; dry-run=$DRY_RUN"

    now=$(date +%s)
    cutoff=$(date -d "-''${MAX_AGE_DAYS} days" +%s)
    cleaned=0 pruned=0 kept=0 adopted=0 freed_mb=0

    for root in "''${ROOTS[@]}"; do
      [ -d "$root" ] || continue
      root_real=$(readlink -f "$root") || continue

      # ---- ADOPT: detached dirs left by a sweep that died mid-clean ----
      # Only when the pid that detached it is gone, so a concurrent run's
      # work in progress is never stolen.
      #
      # Every skip is logged and counted: a detached dir is typically many
      # GB, and one skipped silently is one nobody ever finds.
      while IFS= read -r orphan; do
        [ -n "$orphan" ] || continue
        opid=''${orphan##*.sweeping.}
        case "$opid" in
          ''' | *[!0-9]*)
            keep "unrecognised detached-dir suffix — not this sweep's naming" "$orphan"
            kept=$((kept + 1)); continue ;;
        esac
        # A live pid is not proof of a live sweep: pids are reused. Only a
        # process that IS a cargo-target-sweep owns the dir. An unreadable
        # cmdline proves nothing either way, so it keeps (fail closed).
        if [ -d "/proc/$opid" ]; then
          if ! ocmd=$(tr '\0' ' ' < "/proc/$opid/cmdline" 2>/dev/null) \
             || [[ "$ocmd" == *cargo-target-sweep* ]]; then
            keep "detached by a sweep that is still running (pid $opid)" "$orphan"
            kept=$((kept + 1)); continue
          fi
          log "REUSED pid $opid is alive but is not a sweep — treating $orphan as orphaned"
        fi
        omanifest=$(dirname "$orphan")/Cargo.toml
        if [ ! -f "$omanifest" ]; then
          keep "no Cargo.toml beside it — nothing to clean it through" "$orphan"
          kept=$((kept + 1)); continue
        fi
        # A detached dir is unreachable by with-cargo-lock (lanes only ever
        # resolve `target`), so nothing should be inside it — but the whole
        # contract here is that a predicate holds positively before anything
        # is removed, and an orphaned child of the dead sweep is exactly the
        # case that would not.
        if is_live "$orphan" || lock_waiters "$orphan/$LOCK_NAME"; then
          keep "LIVE — a process is using this detached dir" "$orphan"
          kept=$((kept + 1)); continue
        fi
        if [ "$DRY_RUN" = 1 ]; then
          log "WOULD-ADOPT $orphan"
        elif CARGO_TARGET_DIR="$orphan" cargo clean --manifest-path "$omanifest" >/dev/null 2>&1; then
          log "ADOPT  $orphan (left by dead pid $opid)"
          adopted=$((adopted + 1))
        else
          fail "could not clean detached $orphan — it stays until this succeeds"
        fi
      done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -name 'target.sweeping.*' 2>/dev/null)

      while IFS= read -r target; do
        [ -n "$target" ] || continue

        # (1) shape, and still inside the root after symlink resolution
        real=$(readlink -f "$target" 2>/dev/null) || { keep "unresolvable" "$target"; kept=$((kept + 1)); continue; }
        case "$real" in
          "$root_real"/*/target) : ;;
          *) keep "outside root after symlink resolution" "$target"; kept=$((kept + 1)); continue ;;
        esac
        [ -d "$real" ] || { keep "not a directory" "$target"; kept=$((kept + 1)); continue; }

        # (2) it is genuinely a Cargo target dir, not just named 'target'.
        #
        # Do NOT rely on CACHEDIR.TAG alone: measured on tuxedo 2026-11-11,
        # NONE of the 91 real target dirs on this host carry one, so a
        # CACHEDIR.TAG-only gate makes this job a silent no-op — it rejects
        # every directory it exists to clean while reporting success. Cargo
        # does reliably leave .rustc_info.json at the target root and
        # .fingerprint under each profile dir, so accept any of the three.
        # All are cargo-specific enough that a directory merely NAMED
        # `target` holding real data cannot match.
        if ! { grep -qs 'Signature: 8a477f597d28d172a0f0f2f52a2b2447' "$real/CACHEDIR.TAG" \
               || [ -f "$real/.rustc_info.json" ] \
               || [ -d "$real/debug/.fingerprint" ] \
               || [ -d "$real/release/.fingerprint" ]; }; then
          keep "no cargo marker (CACHEDIR.TAG/.rustc_info.json/.fingerprint) — not a cargo target dir" "$target"
          kept=$((kept + 1)); continue
        fi

        # (3) a manifest to hand the scoped tool
        wt=$(dirname "$real")
        man="$wt/Cargo.toml"
        [ -f "$man" ] || { keep "no Cargo.toml beside it" "$target"; kept=$((kept + 1)); continue; }

        # Age must come from the newest artifact ANYWHERE in the tree, not
        # from the directory's own mtime and not from its depth-1 entries.
        # `cargo check` writes into target/debug/deps/, which bumps deps/ but
        # leaves debug/ and target/ untouched: measured 2026-11-11, a tree
        # built seconds ago read as 90 DAYS OLD at depth 1. Reading the
        # directory's own mtime is just as wrong in the other direction —
        # creating the lock file below bumps it, so every inspected directory
        # would look fresh forever. `-newermt ... -print -quit` stops at the
        # first recent file, so an active tree costs almost nothing; a stale
        # one is walked fully, which pass A has to do anyway.
        case "$(staleness "$real")" in
          unreadable)
            keep "could not walk the whole tree (unreadable subdirectory) — staleness unprovable" "$target"
            kept=$((kept + 1)); continue ;;
          empty)
            keep "empty target dir — nothing to age" "$target"; kept=$((kept + 1)); continue ;;
          active) stale=0; age="" ;;
          *)
            stale=1
            mt=$(find "$real" -mindepth 1 ! -name "$LOCK_NAME" -printf '%T@\n' 2>/dev/null \
                 | sort -n | tail -1 | cut -d. -f1)
            age=$(((now - ''${mt:-$now}) / 86400)) ;;
        esac

        # (5) take the per-worktree Cargo lock non-blocking.
        #
        # A dry run must leave the filesystem exactly as it found it, so it
        # never CREATES the lock file: opening it `>>` would create the file
        # and bump the parent directory's mtime (measured). A lock file that
        # does not exist cannot be held by anyone — a lane holding it would
        # have created it — so "absent" is a sound negative in dry run.
        # The redirection must be scoped to a group: `exec {fd}>>f 2>/dev/null`
        # is an exec with no command, so BOTH redirections apply to the shell
        # permanently and every later diagnostic in the run goes to /dev/null
        # (measured). Inside a group, only the group's stderr is affected.
        lock="$real/$LOCK_NAME"
        lockfd=""
        if [ "$DRY_RUN" = 1 ]; then
          if [ -e "$lock" ]; then
            { exec {lockfd}<"$lock"; } 2>/dev/null \
              || { keep "cannot open cargo lock" "$target"; kept=$((kept + 1)); continue; }
          fi
        else
          { exec {lockfd}>>"$lock"; } 2>/dev/null \
            || { keep "cannot open cargo lock" "$target"; kept=$((kept + 1)); continue; }
        fi
        if [ -n "$lockfd" ] && ! flock -n "$lockfd"; then
          release_lock
          keep "cargo lock held by a running lane" "$target"; kept=$((kept + 1)); continue
        fi

        # (6) cargo must agree that THIS path is the manifest's target dir.
        # Asked here, in the same process and cwd that will run the clean, so
        # the answer is the one that governs it.
        resolved=$(cargo metadata --no-deps --offline --format-version 1 \
                     --manifest-path "$man" 2>/dev/null | jq -r '.target_directory // empty')
        if [ -z "$resolved" ]; then
          release_lock
          keep "cargo metadata could not resolve the manifest" "$target"; kept=$((kept + 1)); continue
        fi
        resolved_real=$(readlink -f "$resolved" 2>/dev/null)
        if [ "$resolved_real" != "$real" ]; then
          release_lock
          keep "cargo resolves this manifest's target dir to '$resolved' — refusing to aim a clean elsewhere" "$target"
          kept=$((kept + 1)); continue
        fi

        # Sizing walks the whole tree, so it happens HERE — behind the lock
        # and in front of nothing that matters. Everything above this point
        # is slow enough to matter; everything below is the act itself.
        sz=0
        if [ "$stale" = 1 ]; then
          sz=$(du -sm "$real" 2>/dev/null | cut -f1); sz=''${sz:-0}
        fi

        # (7) staleness was decided before the lock was held, and the walks
        # since then take real time on a 50k-file tree. A lane that built and
        # exited in that interval would leave the first verdict saying stale
        # while its fresh artifacts sit on disk. Re-ask under the lock, and
        # only ever downgrade: a directory may lose its claim to being
        # cleaned, never acquire one mid-run.
        case "$(staleness "$real")" in
          active)
            if [ "$stale" = 1 ]; then
              log "RECHECK $target became active while it was being measured — pruning instead"
            fi
            stale=0 ;;
          unreadable)
            release_lock
            keep "became unwalkable while it was being measured" "$target"; kept=$((kept + 1)); continue ;;
          empty)
            release_lock
            keep "became empty while it was being measured" "$target"; kept=$((kept + 1)); continue ;;
          *) : ;;
        esac

        # (8) no lane waiting on the lock, and nothing live inside. is_live
        # is the LAST thing before acting — the waiter scan goes first, so
        # the only work between is_live and the act is the act's own first
        # syscall. Every scan placed in that gap widens it.
        if [ -n "$lockfd" ] && lock_waiters "$lock"; then
          release_lock
          keep "a lane is waiting on its cargo lock" "$target"; kept=$((kept + 1)); continue
        fi
        if is_live "$real"; then
          release_lock
          keep "LIVE — a process is using it" "$target"; kept=$((kept + 1)); continue
        fi

        if [ "$stale" = 1 ]; then
          if [ "$DRY_RUN" = 1 ]; then
            log "WOULD-CLEAN ''${sz}MB ''${age}d $target"
          else
            # Detach first: see WHY PASS A DETACHES BEFORE CLEANING above.
            detached="$real.sweeping.$$"
            if ! mv "$real" "$detached" 2>/dev/null; then
              fail "could not detach $target"
              release_lock
              kept=$((kept + 1)); continue
            fi
            log "DETACH $target -> $detached"
            # (9) Ask again, on the detached path. Anything that opened
            # files in target/ between (8) and the rename moved with it and
            # is visible here; anything arriving from now on resolves
            # `target` to a fresh directory and cannot reach this one. A lane
            # that opened the lock in that window holds the detached inode.
            #
            # Move back BEFORE releasing the lock. Released first, a waiter
            # woken on the detached inode can run cargo, which recreates
            # target/ by path; the move-back then fails and that lane's
            # flock guards a directory no other lane can reach.
            #
            # KNOWN LIMIT: with-cargo-lock resolves target/ and then opens the
            # lock file. A rename landing exactly between the two makes that
            # open fail with ENOENT and the lane exits at startup with "could
            # not open Cargo lock". It fails safe — before building anything,
            # loudly — and cannot be closed from this side.
            if is_live "$detached" || lock_waiters "$detached/$LOCK_NAME"; then
              if [ -e "$real" ]; then
                release_lock
                keep "LIVE after detach and target/ was recreated meanwhile — left at $detached; a later run adopts it once idle" "$target"
              elif mverr=$(mv -T "$detached" "$real" 2>&1); then
                release_lock
                keep "LIVE after detach — something started using it in the window; moved back" "$target"
              else
                release_lock
                fail "LIVE after detach and could not move $detached back to $target: $mverr"
              fi
              kept=$((kept + 1)); continue
            fi
            # The lock inode moved with the directory and now guards nothing
            # a lane can reach; a lane arriving from here on makes a fresh
            # target/ of its own.
            release_lock
            if CARGO_TARGET_DIR="$detached" cargo clean --manifest-path "$man" >/dev/null 2>&1; then
              log "CLEAN  ''${sz}MB ''${age}d $target"
              cleaned=$((cleaned + 1)); freed_mb=$((freed_mb + sz))
            else
              fail "cargo clean returned non-zero for detached $detached — the next run adopts it"
            fi
          fi
        else
          # still active: prune only the stale artifacts inside it
          if [ "$DRY_RUN" = 1 ]; then
            log "WOULD-PRUNE $target"
          else
            # cargo-sweep 0.8 exits 0 when it fails: "[WARN] Failed to remove"
            # for an undeletable artifact, "[ERROR] Failed to clean" for an
            # unreadable tree (both measured 2026-11-11), so the exit status
            # alone would report a prune that removed nothing. Any [ERROR]
            # line or any "Failed to" line is a failure; other [WARN]s are not.
            if sweep_out=$(cargo sweep --time "$PRUNE_AGE_DAYS" "$wt" 2>&1); then
              if grep -qE '^\[ERROR\]|Failed to' <<<"$sweep_out"; then
                fail "cargo sweep could not remove artifacts in $target: $(grep -m1 -E '^\[ERROR\]|Failed to' <<<"$sweep_out")"
              else
                log "PRUNE  $target"
                pruned=$((pruned + 1))
              fi
            else
              fail "cargo sweep exited non-zero for $target: $(tail -n1 <<<"$sweep_out")"
            fi
          fi
        fi

        release_lock
      done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -name target 2>/dev/null)
    done

    log "cargo-target-sweep: cleaned=$cleaned (''${freed_mb}MB) pruned=$pruned adopted=$adopted kept=$kept failed=$failures"
    [ "$failures" -eq 0 ]
  '';
}
