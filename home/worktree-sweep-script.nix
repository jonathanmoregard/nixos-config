{ pkgs
, # Directories scanned for git worktrees. Every worktree found under a
  # root is a deletion CANDIDATE; anything outside them is never touched,
  # which is what keeps a repo's own main checkout (e.g. ~/.claude) safe.
  roots ? [ "$HOME/Repos/nixos-config-worktrees" "$HOME/worktrees" ]
, maxAgeDays ? 7
}:

# worktree-sweep — delete merged-and-stale worktrees and local branches
# across every repo that has a worktree under one of `roots`. PRs merge by
# SQUASH, so `git branch --merged` never matches; GitHub PR state is the
# source of truth and `branch -D` (not -d) is required — which is exactly
# why every predicate below fails closed.
#
# Repos are DISCOVERED, not configured: each candidate worktree is resolved
# to its owning repo via `git rev-parse --git-common-dir`, and that repo's
# slug and default branch are read from its own git config. A new repo with
# a worktree under a root is swept with no edit here. The cost of that
# convenience is that both derivations must fail closed, and they do — a
# non-GitHub remote or an unreadable repo means "keep", logged.
#
# FAIL-CLOSED CONTRACT (asserted by tests/worktree-sweep.nix): an item
# is deleted only when EVERY predicate positively holds. Any error,
# missing data, or ambiguity on any predicate means "keep" with a
# logged reason. A gh outage means zero deletions. One journal line
# per decision.
#
# Worktree predicates (ALL must hold to delete):
#   1. the worktree lives under one of `roots`
#   2. a merged PR exists whose headRefOid equals the local branch tip
#      — tip equality also proves no post-merge commits would be lost
#        to `branch -D`
#   3. branch tip commit is older than maxAgeDays
#   4. `git status --porcelain` is empty (no uncommitted/untracked work)
#   5. no live process cwd (/proc/*/cwd) resolves inside the worktree
#      — 2026-07-07 incident: a directory deleted under a running
#        Claude session ENOENT-broke every hook in it (posix_spawn)
#
# Branches without worktrees: predicates 2 + 3, then `branch -D`. Only
# repos discovered through a worktree are scanned this way — a repo that
# has never had a worktree under a root is never touched at all.
#
# Env overrides — FOR THE TEST HARNESS ONLY (tests/worktree-sweep.nix).
# Production runs (the systemd user timer) must not set these:
#   SWEEP_ROOTS            colon-separated worktree roots (discovery mode)
#   SWEEP_BARE_REPO        single-repo mode: sweep exactly this repo
#   SWEEP_WORKTREES_DIR    single-repo mode: its allowed worktree root
#   SWEEP_REPO_SLUG        single-repo mode: slug instead of deriving one
#   SWEEP_PROTECTED_BRANCH single-repo mode: default branch to protect
#   SWEEP_GH_BIN           gh executable (stubbed in the harness —
#                          runtimeInputs pins the real gh ahead of
#                          PATH, so a PATH stub can't shadow it)
#   SWEEP_EXTRA_LIVE_CWDS  colon-separated paths treated as live cwds
#                          IN ADDITION to the /proc scan, which always
#                          runs (/proc can't be faked in the sandbox)
let
  defaultRoots = builtins.concatStringsSep ":" roots;
in
pkgs.writeShellApplication {
  name = "worktree-sweep";
  runtimeInputs = with pkgs; [ git jq coreutils ];
  text = ''
    GH_BIN="''${SWEEP_GH_BIN:-${pkgs.gh}/bin/gh}"
    MAX_AGE_DAYS=${toString maxAgeDays}

    log() { echo "[worktree-sweep] $*"; }

    now=$(date +%s)

    # Global gh gate: no auth (keyring locked, offline, token expired)
    # means the merged-PR predicate can never positively hold → do
    # nothing at all this run.
    if ! "$GH_BIN" auth status >/dev/null 2>&1; then
      log "abort: gh auth unavailable — zero deletions this run"
      exit 0
    fi

    # --- per-repo context ------------------------------------------------
    # Set by sweep_repo before the predicates run.
    REPO=""        # repo dir: a bare repo, or the main checkout's toplevel
    SLUG=""        # owner/name on GitHub
    PROTECTED=()   # branch names this repo must never delete
    ROOTS=()       # worktree roots a candidate must live under

    REASON=""
    MERGED_PR=""
    AGE_DAYS=""

    is_protected() {  # <branch>
      local b
      for b in "''${PROTECTED[@]}"; do
        [ "$1" = "$b" ] && return 0
      done
      return 1
    }

    under_roots() {  # <path>
      local p="$1" root
      for root in "''${ROOTS[@]}"; do
        [ -n "$root" ] || continue
        case "$p" in
          "$root"/*) return 0 ;;
        esac
      done
      return 1
    }

    # owner/name from a GitHub remote URL, or non-zero for anything else.
    # A repo whose origin is not GitHub has no PR state to consult, so it
    # must never reach the delete path.
    slug_from_url() {  # <url>
      local s="$1"
      s="''${s%.git}"
      case "$s" in
        *github.com[:/]*)
          s="''${s##*github.com}"
          s="''${s#[:/]}"
          ;;
        *) return 1 ;;
      esac
      case "$s" in
        */*/*) return 1 ;;   # more than owner/name — not a repo slug
        */*)   printf '%s' "$s" ;;
        *)     return 1 ;;
      esac
    }

    check_merged() {  # <branch>
      local branch="$1" tip pr_json count match
      REASON=""
      # --verify -q: plain rev-parse echoes unresolvable refs back to
      # stdout; --verify guarantees $tip is a real oid or the guard fires.
      if ! tip=$(git -C "$REPO" rev-parse --verify -q "refs/heads/$branch" 2>/dev/null); then
        REASON="cannot resolve local tip — fail closed"
        return 1
      fi
      if ! pr_json=$("$GH_BIN" pr list --repo "$SLUG" --head "$branch" \
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
      if ! ts=$(git -C "$REPO" log -1 --format=%ct "refs/heads/$branch" 2>/dev/null); then
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

      if is_protected "$branch"; then
        log "kept worktree $wt (branch $branch): protected (default branch)"
        return 0
      fi
      # The repo's own checkout is never a candidate: it sits outside the
      # roots. Belt and braces for the case where someone points a root at
      # a repo's parent directory anyway.
      if [ "$wt" = "$REPO" ]; then
        log "kept worktree $wt (branch $branch): the repo's own checkout"
        return 0
      fi
      if ! under_roots "$wt"; then
        log "kept worktree $wt (branch $branch): outside the swept roots — fail closed"
        return 0
      fi
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
      if ! git -C "$REPO" worktree remove "$wt" 2>/dev/null; then
        log "kept worktree $wt (branch $branch): git worktree remove refused — fail closed"
        return 0
      fi
      if git -C "$REPO" branch -D "$branch" >/dev/null 2>&1; then
        log "deleted worktree $wt + branch $branch (PR #$MERGED_PR merged at this tip, ''${AGE_DAYS}d old, clean, no live cwd)"
      else
        log "deleted worktree $wt; branch $branch delete FAILED — manual cleanup needed"
      fi
    }

    sweep_repo() {  # <repo-dir>
      local repo="$1" url derived head
      REPO="$repo"
      SLUG=""
      PROTECTED=(main master)
      wt_branches=()

      # Separate "git will not operate here at all" from "this repo has no
      # origin". `remote get-url` fails for BOTH, so blaming a missing remote
      # is wrong whenever the real cause is that git refused the directory.
      # The live case: safe.bareRepository = explicit (home/jonathan.nix) makes
      # every `git -C <bare-dir> ...` fail outright, and discovery resolves a
      # linked worktree to its owner, which for ~/Repos/nixos-config is exactly
      # that bare dir. Skipping is correct — the repo is swept through its
      # linked worktrees — but the nightly log said "no origin remote" for a
      # repo that has one, which misreports a fail-closed path.
      if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        log "skipped repo $repo: git refuses to operate here (bare repo under safe.bareRepository, or unreadable) — fail closed"
        return 0
      fi

      if [ -n "''${SWEEP_REPO_SLUG:-}" ]; then
        SLUG="$SWEEP_REPO_SLUG"
      else
        if ! url=$(git -C "$repo" remote get-url origin 2>/dev/null); then
          log "skipped repo $repo: no origin remote — fail closed"
          return 0
        fi
        if ! derived=$(slug_from_url "$url"); then
          log "skipped repo $repo: origin '$url' is not a GitHub repo — no PR state to consult, fail closed"
          return 0
        fi
        SLUG="$derived"
      fi

      # The default branch is protected on top of main/master. Unresolvable
      # origin/HEAD (never set locally by `git remote set-head`) is common
      # and not itself dangerous — every deletion still needs a merged PR at
      # the same tip — so fall back rather than skip, and say so.
      if [ -n "''${SWEEP_PROTECTED_BRANCH:-}" ]; then
        PROTECTED=("$SWEEP_PROTECTED_BRANCH")
      elif head=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
        PROTECTED+=("''${head#origin/}")
      else
        log "note: $SLUG has no origin/HEAD — protecting main and master by name"
      fi

      log "sweeping $SLUG (repo $repo)"

      # Snapshot the list before mutating it (worktree remove during
      # iteration would race a streamed read).
      local worktree_dump cur_wt cur_branch cur_bare cur_detached cur_locked line branch branch_dump
      if ! worktree_dump=$(git -C "$repo" worktree list --porcelain 2>/dev/null); then
        log "skipped repo $repo: worktree list failed — fail closed"
        return 0
      fi

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

      # --- phase 2: local branches without worktrees ----------------------
      branch_dump=$(git -C "$repo" for-each-ref refs/heads --format='%(refname:short)')

      while IFS= read -r branch; do
        [ -n "$branch" ] || continue
        is_protected "$branch" && continue
        [ -n "''${wt_branches[$branch]+x}" ] && continue  # decided in phase 1
        if ! check_merged "$branch"; then
          log "kept branch $branch: $REASON"
          continue
        fi
        if ! check_age "$branch"; then
          log "kept branch $branch: $REASON"
          continue
        fi
        if git -C "$repo" branch -D "$branch" >/dev/null 2>&1; then
          log "deleted branch $branch (PR #$MERGED_PR merged at this tip, ''${AGE_DAYS}d old, no worktree)"
        else
          log "kept branch $branch: git branch -D failed — fail closed"
        fi
      done <<<"$branch_dump"
    }

    # --- target selection -------------------------------------------------
    # Single-repo mode (harness) sweeps exactly the repo it is handed.
    # Otherwise every repo owning a worktree under a root is discovered:
    # the repo list is not configured anywhere, so a new repo needs no
    # edit here to be swept.
    declare -A seen_repos=()
    repos=()

    if [ -n "''${SWEEP_BARE_REPO:-}" ]; then
      IFS=':' read -r -a ROOTS <<<"''${SWEEP_WORKTREES_DIR:-}"
      : "''${SWEEP_REPO_SLUG:=jonathanmoregard/nixos-config}"
      : "''${SWEEP_PROTECTED_BRANCH:=main}"
      export SWEEP_REPO_SLUG SWEEP_PROTECTED_BRANCH
      if [ ! -d "$SWEEP_BARE_REPO" ]; then
        log "abort: repo not found at $SWEEP_BARE_REPO — zero deletions"
        exit 0
      fi
      repos=("$SWEEP_BARE_REPO")
    else
      IFS=':' read -r -a ROOTS <<<"''${SWEEP_ROOTS:-${defaultRoots}}"
      for root in "''${ROOTS[@]}"; do
        [ -d "$root" ] || { log "root $root does not exist — skipping"; continue; }
        for candidate in "$root"/*/; do
          candidate="''${candidate%/}"
          [ -d "$candidate" ] || continue
          # git-common-dir resolves a linked worktree to its owner: the
          # bare repo itself, or <toplevel>/.git for a normal checkout.
          common=$(git -C "$candidate" rev-parse --path-format=absolute \
                     --git-common-dir 2>/dev/null) || continue
          owner="''${common%/.git}"
          [ -d "$owner" ] || continue
          if [ -z "''${seen_repos[$owner]+x}" ]; then
            seen_repos["$owner"]=1
            repos+=("$owner")
          fi
        done
      done
      log "discovered ''${#repos[@]} repo(s) with worktrees under: ''${ROOTS[*]}"
    fi

    for repo in "''${repos[@]}"; do
      sweep_repo "$repo"
    done

    log "sweep complete"
  '';
}
