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
#   A. target dir untouched >= maxAgeDays  -> removed whole, via `cargo clean`
#   B. target dir still active             -> `cargo sweep --time` prunes only
#                                             the stale artifacts inside it
# Pass B is what keeps long-lived worktrees from silently re-accumulating;
# pass A is what reclaims the backlog.
#
# WHY `cargo clean` AND `cargo sweep`, NOT `rm -rf`. Both are scoped by
# construction: they can only ever touch the target directory belonging to the
# manifest they are handed. A stray root or a symlinked path cannot turn
# either into a recursive delete of something else.
#
# FAIL-CLOSED CONTRACT (asserted by tests/cargo-target-sweep.nix). Every
# predicate must positively hold or the directory is kept, and the reason is
# logged. Silence is never consent.
#
#   1. path matches <root>/*/target and resolves (after symlink resolution)
#      to a location still inside that root
#   2. it really is a Cargo target dir — CACHEDIR.TAG present with Cargo's
#      own signature. This is the single most important gate: it is what
#      stops a directory merely NAMED `target` from being deleted.
#   3. a Cargo.toml sits beside it, so the scoped tool has a manifest
#   4. no live process has cwd, an open fd, or a mapped file inside it
#      — mapped files matter: a running rustc maps .rlib/.so straight out
#        of the target dir without holding a conventional fd
#   5. the per-worktree Cargo lock (.klaffat-cargo.lock) can be taken
#      non-blocking, and is HELD for the duration of the removal, so a lane
#      cannot start building into a directory mid-delete
#
# Predicates 4 and 5 are what make this safe against the standing constraint
# that parallel klaffat lanes run constantly: destroying a lane's target dir
# mid-build loses hours and can corrupt a run reporting into a PR. In
# practice (4) fires first, because holding a flock requires holding an open
# fd and that fd is visible in /proc. (5) is not therefore redundant: it is
# the only thing that closes the window BETWEEN the check and the delete,
# and it is the same lock scripts/with-cargo-lock takes in the klaffat repo,
# so a lane starting mid-sweep blocks instead of racing.
#
# Age is deliberately NOT read from the target dir's own mtime — see the
# comment at the age computation. Getting that wrong makes the job silently
# self-defeating.

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
    gnugrep
    util-linux
  ];
  text = ''
    set -uo pipefail

    MAX_AGE_DAYS=${toString maxAgeDays}
    PRUNE_AGE_DAYS=${toString pruneAgeDays}
    DRY_RUN=''${CARGO_TARGET_SWEEP_DRY_RUN:-0}
    ROOTS=(${rootsStr})

    # Cargo refuses to honour a manifest path if this is set, and a stray
    # value from the environment would redirect every clean below.
    unset CARGO_TARGET_DIR

    log() { printf '%s\n' "$*"; }
    keep() { log "KEEP   $2 — $1"; }

    # ---- live-path set: cwd, open fds, and mapped files of every process ----
    LIVE=$(mktemp) || exit 1
    trap 'rm -f "$LIVE"' EXIT
    for p in /proc/[0-9]*; do
      [ -r "$p" ] || continue
      readlink "$p/cwd" 2>/dev/null >>"$LIVE" || true
      if [ -d "$p/fd" ]; then
        for fd in "$p"/fd/*; do
          [ -e "$fd" ] || continue
          readlink "$fd" 2>/dev/null >>"$LIVE" || true
        done
      fi
      if [ -r "$p/maps" ]; then
        awk '{ if ($6 ~ /^\//) print $6 }' "$p/maps" 2>/dev/null >>"$LIVE" || true
      fi
    done
    sort -u -o "$LIVE" "$LIVE"
    log "cargo-target-sweep: $(wc -l <"$LIVE") live paths; max-age ''${MAX_AGE_DAYS}d; dry-run=$DRY_RUN"

    now=$(date +%s)
    cleaned=0 pruned=0 kept=0 freed_mb=0

    for root in "''${ROOTS[@]}"; do
      [ -d "$root" ] || continue
      root_real=$(readlink -f "$root") || continue

      while IFS= read -r target; do
        [ -n "$target" ] || continue

        # (1) shape, and still inside the root after symlink resolution
        real=$(readlink -f "$target" 2>/dev/null) || { keep "unresolvable" "$target"; kept=$((kept+1)); continue; }
        case "$real" in
          "$root_real"/*/target) : ;;
          *) keep "outside root after symlink resolution" "$target"; kept=$((kept+1)); continue ;;
        esac
        [ -d "$real" ] || { keep "not a directory" "$target"; kept=$((kept+1)); continue; }

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
          kept=$((kept+1)); continue
        fi

        # (3) a manifest to hand the scoped tool
        wt=$(dirname "$real")
        man="$wt/Cargo.toml"
        [ -f "$man" ] || { keep "no Cargo.toml beside it" "$target"; kept=$((kept+1)); continue; }

        # (4) nothing live inside
        if grep -qF -- "$real/" "$LIVE"; then
          keep "LIVE — a process is using it" "$target"; kept=$((kept+1)); continue
        fi

        # Age must NOT come from the target dir's own mtime. Taking the lock
        # below creates .klaffat-cargo.lock inside it, which bumps that
        # mtime — so a sweep would reset the age of everything it inspected
        # and never clean anything on any later run. (Same shape as the
        # atime bug that made systemd-tmpfiles never reap /tmp; see
        # profiles/base.nix.) Derive age from the newest real build artifact
        # instead, explicitly excluding our own lock file.
        mt=$(find "$real" -maxdepth 1 -mindepth 1 \
               ! -name .klaffat-cargo.lock -printf '%T@\n' 2>/dev/null \
             | sort -n | tail -1 | cut -d. -f1)
        if [ -z "''${mt:-}" ]; then
          keep "empty target dir — nothing to age" "$target"; kept=$((kept+1)); continue
        fi
        age=$(( (now - mt) / 86400 ))

        # (5) take the per-worktree Cargo lock non-blocking and HOLD it
        lock="$real/.klaffat-cargo.lock"
        exec {lockfd}>>"$lock" 2>/dev/null || { keep "cannot open cargo lock" "$target"; kept=$((kept+1)); continue; }
        if ! flock -n "$lockfd"; then
          exec {lockfd}>&-
          keep "cargo lock held by a running lane" "$target"; kept=$((kept+1)); continue
        fi

        if [ "$age" -ge "$MAX_AGE_DAYS" ]; then
          sz=$(du -sm "$real" 2>/dev/null | cut -f1); sz=''${sz:-0}
          if [ "$DRY_RUN" = 1 ]; then
            log "WOULD-CLEAN ''${sz}MB ''${age}d $target"
          elif cargo clean --manifest-path "$man" >/dev/null 2>&1; then
            log "CLEAN  ''${sz}MB ''${age}d $target"
            cleaned=$((cleaned+1)); freed_mb=$((freed_mb+sz))
          else
            log "FAIL   cargo clean returned non-zero $target"
          fi
        else
          # still active: prune only the stale artifacts inside it
          if [ "$DRY_RUN" = 1 ]; then
            log "WOULD-PRUNE ''${age}d $target"
          elif cargo sweep --time "$PRUNE_AGE_DAYS" "$wt" >/dev/null 2>&1; then
            log "PRUNE  ''${age}d $target"
            pruned=$((pruned+1))
          else
            keep "cargo sweep declined" "$target"; kept=$((kept+1))
          fi
        fi

        exec {lockfd}>&-
      done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -name target 2>/dev/null)
    done

    log "cargo-target-sweep: cleaned=$cleaned (''${freed_mb}MB) pruned=$pruned kept=$kept"
  '';
}
