{ pkgs }:

# nixos-worktree-sweep — delete merged-and-stale nixos-config worktrees
# and local branches. PRs merge by SQUASH, so `git branch --merged`
# never matches; GitHub PR state is the source of truth and `branch -D`
# (not -d) is required — which is exactly why every predicate below
# fails closed.
#
# FAIL-CLOSED CONTRACT (asserted by tests/worktree-sweep.nix): an item
# is deleted only when EVERY predicate positively holds. Any error,
# missing data, or ambiguity on any predicate means "keep" with a
# logged reason. A gh outage means zero deletions. One journal line
# per decision.
#
# Worktree predicates (ALL must hold to delete):
#   1. a merged PR exists whose headRefOid equals the local branch tip
#      — tip equality also proves no post-merge commits would be lost
#        to `branch -D`
#   2. branch tip commit is older than 7 days
#   3. `git status --porcelain` is empty (no uncommitted/untracked work)
#   4. no live process cwd (/proc/*/cwd) resolves inside the worktree
#      — 2026-07-07 incident: a directory deleted under a running
#        Claude session ENOENT-broke every hook in it (posix_spawn)
#
# Branches without worktrees: predicates 1 + 2, then `branch -D`.
#
# Env overrides — FOR THE TEST HARNESS ONLY (tests/worktree-sweep.nix).
# Production runs (the systemd user timer) must not set these:
#   SWEEP_BARE_REPO        bare repo path
#   SWEEP_WORKTREES_DIR    worktrees root
#   SWEEP_GH_BIN           gh executable (stubbed in the harness —
#                          runtimeInputs pins the real gh ahead of
#                          PATH, so a PATH stub can't shadow it)
#   SWEEP_EXTRA_LIVE_CWDS  colon-separated paths treated as live cwds
#                          IN ADDITION to the /proc scan, which always
#                          runs (/proc can't be faked in the sandbox)
pkgs.writeShellApplication {
  name = "nixos-worktree-sweep";
  runtimeInputs = with pkgs; [ git jq coreutils ];
  text = ''
    BARE="''${SWEEP_BARE_REPO:-$HOME/Repos/nixos-config}"
    WTS="''${SWEEP_WORKTREES_DIR:-$HOME/Repos/nixos-config-worktrees}"
    GH_BIN="''${SWEEP_GH_BIN:-${pkgs.gh}/bin/gh}"
    REPO_SLUG="jonathanmoregard/nixos-config"
    MAX_AGE_DAYS=7

    log() { echo "[worktree-sweep] $*"; }

    now=$(date +%s)

    if [ ! -d "$BARE" ]; then
      log "abort: bare repo not found at $BARE — zero deletions"
      exit 0
    fi

    # Global gh gate: no auth (keyring locked, offline, token expired)
    # means the merged-PR predicate can never positively hold → do
    # nothing at all this run.
    if ! "$GH_BIN" auth status >/dev/null 2>&1; then
      log "abort: gh auth unavailable — zero deletions this run"
      exit 0
    fi

    # --- predicates ----------------------------------------------------
    # Each check returns 0 = predicate holds, non-zero = keep; the keep
    # reason travels in $REASON. check_merged also sets $MERGED_PR,
    # check_age sets $AGE_DAYS (for the deletion log line).
    REASON=""
    MERGED_PR=""
    AGE_DAYS=""

    check_merged() {  # <branch>
      local branch="$1" tip pr_json count match
      REASON=""
      # --verify -q: plain rev-parse echoes unresolvable refs back to
      # stdout; --verify guarantees $tip is a real oid or the guard fires.
      if ! tip=$(git -C "$BARE" rev-parse --verify -q "refs/heads/$branch" 2>/dev/null); then
        REASON="cannot resolve local tip — fail closed"
        return 1
      fi
      if ! pr_json=$("$GH_BIN" pr list --repo "$REPO_SLUG" --head "$branch" \
                       --state merged --json number,headRefOid 2>/dev/null); then
        REASON="gh pr list failed — fail closed"
        return 1
      fi
      if ! count=$(jq 'length' <<<"$pr_json" 2>/dev/null); then
        REASON="gh output not parseable as JSON — fail closed"
        return 1
      fi
      if [ "$count" -eq 0 ]; then
        REASON="no merged PR for this branch"
        return 1
      fi
      if ! match=$(jq -r --arg tip "$tip" \
             '[.[] | select(.headRefOid == $tip)][0].number // empty' \
             <<<"$pr_json" 2>/dev/null); then
        REASON="gh output not parseable as JSON — fail closed"
        return 1
      fi
      if [ -z "$match" ]; then
        REASON="merged PR exists but its head tip differs from the local tip (post-merge commits?) — fail closed"
        return 1
      fi
      MERGED_PR="$match"
      return 0
    }

    check_age() {  # <branch>
      local branch="$1" ts
      REASON=""
      if ! ts=$(git -C "$BARE" log -1 --format=%ct "refs/heads/$branch" 2>/dev/null); then
        REASON="cannot read tip commit time — fail closed"
        return 1
      fi
      AGE_DAYS=$(( (now - ts) / 86400 ))
      if [ "$AGE_DAYS" -lt "$MAX_AGE_DAYS" ]; then
        REASON="tip commit only ''${AGE_DAYS}d old (< ''${MAX_AGE_DAYS}d)"
        return 1
      fi
      return 0
    }

    check_clean() {  # <worktree-path>
      local wt="$1" status
      REASON=""
      if ! status=$(git -C "$wt" status --porcelain 2>/dev/null); then
        REASON="git status failed — fail closed"
        return 1
      fi
      if [ -n "$status" ]; then
        REASON="dirty: uncommitted or untracked work present"
        return 1
      fi
      return 0
    }

    check_no_live_cwd() {  # <worktree-realpath>
      local dir="$1" link target extra extras
      REASON=""
      # Coverage gap (accepted): readlink on /proc/<pid>/cwd needs
      # ptrace-read credentials, so OTHER users' processes (root
      # included) return EACCES and are skipped — a root shell cd'd
      # into a worktree is invisible here. Worktrees are jonathan-owned
      # and the timer runs as jonathan, so every realistic occupant
      # (Claude sessions, shells, editors) IS visible; do not assume
      # total cwd coverage beyond that.
      for link in /proc/[0-9]*/cwd; do
        target=$(readlink "$link" 2>/dev/null) || continue
        case "$target" in
          "$dir"|"$dir"/*)
            REASON="live process cwd inside ($link → $target) — deleting would ENOENT-break it"
            return 1 ;;
        esac
      done
      if [ -n "''${SWEEP_EXTRA_LIVE_CWDS:-}" ]; then
        IFS=':' read -r -a extras <<<"''${SWEEP_EXTRA_LIVE_CWDS}"
        for extra in "''${extras[@]}"; do
          case "$extra" in
            "$dir"|"$dir"/*)
              REASON="live cwd (harness-injected via SWEEP_EXTRA_LIVE_CWDS)"
              return 1 ;;
          esac
        done
      fi
      return 0
    }

    # --- phase 1: registered worktrees -----------------------------------
    # Track every branch that has a worktree so phase 2 skips them
    # (one decision per item per run).
    declare -A wt_branches=()

    process_worktree() {  # <path> <branch> <bare> <detached> <locked>
      local wt="$1" branch="$2" is_bare="$3" is_detached="$4" is_locked="$5" real

      [ "$is_bare" = "1" ] && return 0  # the bare repo's own list entry

      if [ "$is_detached" = "1" ] || [ -z "$branch" ]; then
        log "kept worktree $wt: detached HEAD — fail closed"
        return 0
      fi
      wt_branches["$branch"]=1

      if [ "$branch" = "main" ] || [ "$wt" = "$WTS/main" ]; then
        log "kept worktree $wt (branch $branch): protected (main)"
        return 0
      fi
      case "$wt" in
        "$WTS"/*) : ;;
        *)
          log "kept worktree $wt (branch $branch): outside $WTS — fail closed"
          return 0 ;;
      esac
      if [ "$is_locked" = "1" ]; then
        log "kept worktree $wt (branch $branch): locked"
        return 0
      fi
      if [ ! -d "$wt" ]; then
        log "kept worktree $wt (branch $branch): directory missing (prunable?) — fail closed"
        return 0
      fi
      if ! real=$(realpath "$wt" 2>/dev/null); then
        log "kept worktree $wt (branch $branch): realpath failed — fail closed"
        return 0
      fi

      if ! check_merged "$branch"; then
        log "kept worktree $wt (branch $branch): $REASON"
        return 0
      fi
      if ! check_age "$branch"; then
        log "kept worktree $wt (branch $branch): $REASON"
        return 0
      fi
      if ! check_clean "$wt"; then
        log "kept worktree $wt (branch $branch): $REASON"
        return 0
      fi
      if ! check_no_live_cwd "$real"; then
        log "kept worktree $wt (branch $branch): $REASON"
        return 0
      fi

      # All predicates hold. Non-force remove: git re-verifies the tree
      # is clean, a last belt against TOCTOU between check and delete.
      if ! git -C "$BARE" worktree remove "$wt" 2>/dev/null; then
        log "kept worktree $wt (branch $branch): git worktree remove refused — fail closed"
        return 0
      fi
      if git -C "$BARE" branch -D "$branch" >/dev/null 2>&1; then
        log "deleted worktree $wt + branch $branch (PR #$MERGED_PR merged at this tip, ''${AGE_DAYS}d old, clean, no live cwd)"
      else
        log "deleted worktree $wt; branch $branch delete FAILED — manual cleanup needed"
      fi
    }

    # Snapshot the list before mutating it (worktree remove during
    # iteration would race a streamed read).
    worktree_dump=$(git -C "$BARE" worktree list --porcelain)

    cur_wt=""; cur_branch=""; cur_bare=0; cur_detached=0; cur_locked=0
    flush() {
      [ -n "$cur_wt" ] || return 0
      process_worktree "$cur_wt" "$cur_branch" "$cur_bare" "$cur_detached" "$cur_locked"
      cur_wt=""; cur_branch=""; cur_bare=0; cur_detached=0; cur_locked=0
    }
    while IFS= read -r line; do
      case "$line" in
        "worktree "*)          flush; cur_wt="''${line#worktree }" ;;
        "branch refs/heads/"*) cur_branch="''${line#branch refs/heads/}" ;;
        bare)                  cur_bare=1 ;;
        detached)              cur_detached=1 ;;
        locked*)               cur_locked=1 ;;
      esac
    done <<<"$worktree_dump"
    flush

    # --- phase 2: local branches without worktrees ------------------------
    branch_dump=$(git -C "$BARE" for-each-ref refs/heads --format='%(refname:short)')

    while IFS= read -r branch; do
      [ -n "$branch" ] || continue
      [ "$branch" = "main" ] && continue
      [ -n "''${wt_branches[$branch]+x}" ] && continue  # decided in phase 1
      if ! check_merged "$branch"; then
        log "kept branch $branch: $REASON"
        continue
      fi
      if ! check_age "$branch"; then
        log "kept branch $branch: $REASON"
        continue
      fi
      if git -C "$BARE" branch -D "$branch" >/dev/null 2>&1; then
        log "deleted branch $branch (PR #$MERGED_PR merged at this tip, ''${AGE_DAYS}d old, no worktree)"
      else
        log "kept branch $branch: git branch -D failed — fail closed"
      fi
    done <<<"$branch_dump"

    log "sweep complete"
  '';
}
