{ pkgs
, # Directories scanned for git worktrees. Every worktree found under a
  # root is a deletion CANDIDATE; anything outside them is never touched,
  # which is what keeps a repo's own main checkout (e.g. ~/.claude) safe.
  roots ? [ "$HOME/Repos/nixos-config-worktrees" "$HOME/worktrees" ]
, maxAgeDays ? 7
}:

# worktree-sweep — delete merged or inactive worktrees and merged branches
# across every repo that has a worktree under one of `roots`. PRs merge by
# SQUASH, so `git branch --merged` never matches; GitHub PR state is the
# source of truth and `branch -D` (not -d) is required — which is exactly
# why every predicate below fails closed.
#
# Repos are DISCOVERED, not configured: each candidate worktree is resolved
# to its owning repo via `git rev-parse --git-common-dir`, and that repo's
# slug and default branch are read from its own git config. A new repo with
# a worktree under a root is swept with no edit here. Repositories without
# GitHub PR state still get reversible age-only worktree cleanup; their local
# branches are preserved.
#
# FAIL-CLOSED CONTRACT (asserted by tests/worktree-sweep.nix): eligibility
# needs an exact-tip merged PR OR a tip commit at least maxAgeDays old. Every
# safety predicate below must still positively hold. Missing PR state can
# authorize only reversible age cleanup, never branch deletion. One journal
# line per decision.
#
# Worktree eligibility (EITHER may hold):
#   1. a merged PR exists whose headRefOid equals the local branch tip
#      — tip equality also proves no post-merge commits would be lost
#        to `branch -D`
#   2. branch tip commit is older than maxAgeDays
#
# Mandatory safety predicates (ALL must hold):
#   3. worktree is branch-backed, inside a configured root, and unlocked
#   4. `git status --porcelain` is empty and ignored content contains only
#      conventional Nix result symlinks with verified /nix/store targets
#   5. no live process cwd (/proc/*/cwd) resolves inside the worktree
#      — 2026-07-07 incident: a directory deleted under a running
#        Claude session ENOENT-broke every hook in it (posix_spawn)
#   6. result/result-* symlinks, if present, point into /nix/store
#
# Exact-tip merged worktrees lose both worktree and branch immediately.
# Age-only worktrees lose only the worktree; their branch is preserved.
# Branches without worktrees require predicate 1, then `branch -D`. Only
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

    # Cache GitHub capability once. Missing auth disables only PR-based
    # eligibility; commit age can still authorize reversible worktree
    # removal while every local branch stays protected.
    GH_AVAILABLE=1
    if ! "$GH_BIN" auth status >/dev/null 2>&1; then
      GH_AVAILABLE=0
      log "note: gh auth unavailable — merged-PR eligibility disabled; age-only cleanup remains active"
    fi

    # --- per-repo context ------------------------------------------------
    # Set by sweep_repo before the predicates run.
    REPO=""        # repo dir: a bare repo, or the main checkout's toplevel
    REPO_IS_BARE=0 # explicit --git-dir mode for validated bare owners
    SLUG=""        # owner/name on GitHub
    PROTECTED=()   # branch names this repo must never delete
    ROOTS=()       # worktree roots a candidate must live under

    REASON=""
    MERGED_PR=""
    AGE_DAYS=""
    RESULT_LINKS_REMOVED=0

    repo_git() {
      if [ "$REPO_IS_BARE" -eq 1 ]; then
        git --git-dir="$REPO" "$@"
      else
        git -C "$REPO" "$@"
      fi
    }

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
    slug_from_url() {  # <url>
      local s="$1"
      s="''${s%.git}"
      case "$s" in
        git@github.com:*)     s="''${s#git@github.com:}" ;;
        ssh://git@github.com/*) s="''${s#ssh://git@github.com/}" ;;
        ssh://github.com/*)   s="''${s#ssh://github.com/}" ;;
        https://github.com/*) s="''${s#https://github.com/}" ;;
        http://github.com/*)  s="''${s#http://github.com/}" ;;
        git://github.com/*)   s="''${s#git://github.com/}" ;;
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
      MERGED_PR=""
      if [ "$GH_AVAILABLE" -ne 1 ]; then
        REASON="gh auth unavailable — merged state unknown"
        return 1
      fi
      if [ -z "$SLUG" ]; then
        REASON="non-GitHub origin — merged state unavailable"
        return 1
      fi
      # --verify -q: plain rev-parse echoes unresolvable refs back to
      # stdout; --verify guarantees $tip is a real oid or the guard fires.
      if ! tip=$(repo_git rev-parse --verify -q "refs/heads/$branch" 2>/dev/null); then
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
      if ! ts=$(repo_git log -1 --format=%ct "refs/heads/$branch" 2>/dev/null); then
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
      local wt="$1" status entry tag index_flags index_file
      REASON=""
      # Command-line untracked visibility overrides a repository-level
      # status.showUntrackedFiles=no. Without it, both this check and Git's
      # default worktree removal can silently discard untracked files.
      if ! status=$(git -C "$wt" status --porcelain=v1 \
                      --untracked-files=all --ignored=no 2>/dev/null); then
        REASON="git status failed — fail closed"
        return 1
      fi
      if [ -n "$status" ]; then
        REASON="dirty: uncommitted or untracked work present"
        return 1
      fi

      # assume-unchanged and skip-worktree flags can hide tracked edits from
      # both status and non-force worktree removal. Keeping such worktrees is
      # safer than trying to infer whether their masked paths are unchanged.
      if ! index_file=$(mktemp); then
        REASON="cannot create index-flag inventory — fail closed"
        return 1
      fi
      if ! git -C "$wt" ls-files -v -z > "$index_file"; then
        unlink -- "$index_file"
        REASON="cannot inspect index flags — fail closed"
        return 1
      fi
      index_flags=0
      while IFS= read -r -d "" entry; do
        tag="''${entry%% *}"
        case "$tag" in
          [a-z]|S)
            index_flags=1
            break ;;
        esac
      done < "$index_file"
      unlink -- "$index_file"
      if [ "$index_flags" -eq 1 ]; then
        REASON="dirty: assume-unchanged or skip-worktree index flag present — fail closed"
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

    # Validate every ignored path and conventional Nix out-link before
    # unlinking anything. Arbitrary ignored data may be valuable (.env,
    # local fixtures, generated notes), so only reproducible top-level Nix
    # result symlinks are safe to discard. This also avoids using
    # `git worktree remove --force`.
    remove_nix_result_links() {  # <worktree-path>
      local wt="$1" link target canonical_target ignored ignored_file ignored_ok=1
      local -a links=()
      RESULT_LINKS_REMOVED=0
      REASON=""

      if ! ignored_file=$(mktemp); then
        REASON="cannot create ignored-content inventory — fail closed"
        return 1
      fi
      if ! git -C "$wt" ls-files --others --ignored --exclude-standard -z > "$ignored_file"; then
        unlink -- "$ignored_file"
        REASON="cannot inventory ignored content — fail closed"
        return 1
      fi
      while IFS= read -r -d "" ignored; do
        case "$ignored" in
          */*)
            REASON="ignored non-Nix content present below top level: $ignored — fail closed"
            ignored_ok=0
            break
            ;;
          result|result-*)
            if [ ! -L "$wt/$ignored" ]; then
              REASON="ignored non-Nix content present: $ignored — fail closed"
              ignored_ok=0
              break
            fi
            links+=("$wt/$ignored")
            ;;
          *)
            REASON="ignored non-Nix content present: $ignored — fail closed"
            ignored_ok=0
            break
            ;;
        esac
      done < "$ignored_file"
      unlink -- "$ignored_file"
      [ "$ignored_ok" -eq 1 ] || return 1

      # Never unlink a tracked path as disposable build output. It may be an
      # intentional repository artifact, and a later failed removal would
      # otherwise leave the retained worktree damaged.
      for link in "$wt/result" "$wt"/result-*; do
        [ -L "$link" ] || continue
        ignored="''${link#"$wt"/}"
        if git -C "$wt" ls-files --error-unmatch -- "$ignored" >/dev/null 2>&1; then
          REASON="tracked result-like symlink present: $ignored — fail closed"
          return 1
        fi
      done

      # Only ignored, untracked result links collected above can reach this
      # validation and unlink path. Nix creates absolute out-links; rejecting
      # relative targets avoids canonicalizing them against the sweeper's cwd
      # instead of the symlink's parent.
      for link in "''${links[@]}"; do
        if ! target=$(readlink -- "$link" 2>/dev/null); then
          REASON="cannot read Nix result link $link — fail closed"
          return 1
        fi
        case "$target" in
          /*) ;;
          *)
            REASON="result-like symlink $link has a relative target — fail closed"
            return 1 ;;
        esac
        if ! canonical_target=$(realpath -m -- "$target" 2>/dev/null); then
          REASON="cannot canonicalize Nix result link $link — fail closed"
          return 1
        fi
        case "$canonical_target" in
          /nix/store/*) ;;
          *)
            REASON="result-like symlink $link targets outside /nix/store — fail closed"
            return 1 ;;
        esac
      done

      for link in "''${links[@]}"; do
        if ! unlink -- "$link"; then
          REASON="cannot unlink verified Nix result link $link — fail closed"
          return 1
        fi
        RESULT_LINKS_REMOVED=$((RESULT_LINKS_REMOVED + 1))
      done
      return 0
    }

    # --- phase 1: registered worktrees -----------------------------------
    # Track every branch that has a worktree so phase 2 skips them
    # (one decision per item per run). Detached HEAD tips separately protect
    # every branch pointing at that commit: such a branch is a recovery anchor.
    declare -A wt_branches=()
    declare -A detached_heads=()

    process_worktree() {  # <path> <branch> <head> <bare> <detached> <locked>
      local wt="$1" branch="$2" head="$3" is_bare="$4" is_detached="$5" is_locked="$6" real
      local merged=0 aged=0 merged_reason="" age_reason=""

      [ "$is_bare" = "1" ] && return 0  # the bare repo's own list entry

      if [ "$is_detached" = "1" ] || [ -z "$branch" ]; then
        [ -n "$head" ] && detached_heads["$head"]=1
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

      if check_merged "$branch"; then
        merged=1
      else
        merged_reason="$REASON"
      fi
      if check_age "$branch"; then
        aged=1
      else
        age_reason="$REASON"
      fi
      if [ "$merged" -eq 0 ] && [ "$aged" -eq 0 ]; then
        log "kept worktree $wt (branch $branch): not merged at local tip ($merged_reason); not inactive for $MAX_AGE_DAYS days ($age_reason)"
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
      if ! remove_nix_result_links "$wt"; then
        log "kept worktree $wt (branch $branch): $REASON"
        return 0
      fi
      if ! check_clean "$wt"; then
        log "kept worktree $wt (branch $branch): changed during cleanup ($REASON)"
        return 0
      fi

      # Eligibility plus every safety predicate holds. Non-force remove makes
      # Git re-verify tracked/untracked state after verified Nix out-links are
      # gone, a last belt against TOCTOU between check and delete.
      if ! repo_git -c status.showUntrackedFiles=all \
               worktree remove "$wt" 2>/dev/null; then
        log "kept worktree $wt (branch $branch): git worktree remove refused — fail closed"
        return 0
      fi
      if [ "$merged" -eq 0 ]; then
        log "deleted inactive worktree $wt; preserved branch $branch (''${AGE_DAYS}d old, clean, no live cwd, removed $RESULT_LINKS_REMOVED Nix result link(s))"
      elif [ -n "''${detached_heads[$head]+x}" ]; then
        log "deleted worktree $wt; preserved branch $branch because its tip is checked out by a detached worktree (PR #$MERGED_PR, removed $RESULT_LINKS_REMOVED Nix result link(s))"
      elif repo_git branch -D "$branch" >/dev/null 2>&1; then
        log "deleted worktree $wt + branch $branch (PR #$MERGED_PR merged at this tip, clean, no live cwd, removed $RESULT_LINKS_REMOVED Nix result link(s))"
      else
        log "deleted worktree $wt; branch $branch delete FAILED — manual cleanup needed"
      fi
    }

    sweep_repo() {  # <repo-dir>
      local repo="$1" url derived head repo_label
      REPO="$repo"
      REPO_IS_BARE=0
      SLUG=""
      PROTECTED=(main master)
      wt_branches=()
      detached_heads=()

      # Discovery validates each owner through a registered worktree's
      # git-common-dir. `safe.bareRepository = explicit` intentionally rejects
      # implicit `git -C <bare-dir>` access, so address a bare owner with the
      # explicit --git-dir form. Normal checkouts stay in -C mode.
      if [ "$(git --git-dir="$repo" rev-parse --is-bare-repository 2>/dev/null || true)" = "true" ]; then
        REPO_IS_BARE=1
      elif ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        log "skipped repo $repo: git refuses to operate here (bare repo under safe.bareRepository, or unreadable) — fail closed"
        return 0
      fi

      if [ -n "''${SWEEP_REPO_SLUG:-}" ]; then
        SLUG="$SWEEP_REPO_SLUG"
      else
        if ! url=$(repo_git remote get-url origin 2>/dev/null); then
          log "note: repo $repo has no origin remote — age-only cleanup only; branches preserved"
        elif ! derived=$(slug_from_url "$url"); then
          log "note: repo $repo origin '$url' is not a GitHub repo — age-only cleanup only; branches preserved"
        else
          SLUG="$derived"
        fi
      fi
      repo_label="$SLUG"
      [ -n "$repo_label" ] || repo_label="$repo"

      # The default branch is protected on top of main/master. Unresolvable
      # origin/HEAD (never set locally by `git remote set-head`) is common
      # and not itself dangerous — every deletion still needs a merged PR at
      # the same tip — so fall back rather than skip, and say so.
      if [ -n "''${SWEEP_PROTECTED_BRANCH:-}" ]; then
        PROTECTED=("$SWEEP_PROTECTED_BRANCH")
      elif head=$(repo_git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
        PROTECTED+=("''${head#origin/}")
      else
        log "note: $repo_label has no origin/HEAD — protecting main and master by name"
      fi

      log "sweeping $repo_label (repo $repo)"

      # Snapshot the list before mutating it (worktree remove during
      # iteration would race a streamed read).
      local worktree_dump cur_wt cur_branch cur_head cur_bare cur_detached cur_locked line branch branch_dump tip
      if ! worktree_dump=$(repo_git worktree list --porcelain 2>/dev/null); then
        log "skipped repo $repo: worktree list failed — fail closed"
        return 0
      fi

      # Index every detached tip before processing any branch-backed worktree.
      # Worktree-list order is path-based, so discovering detached anchors only
      # during mutation can delete a matching branch before its anchor appears.
      cur_head=""; cur_detached=0
      record_detached() {
        if [ "$cur_detached" = "1" ] && [ -n "$cur_head" ]; then
          detached_heads["$cur_head"]=1
        fi
        cur_head=""; cur_detached=0
      }
      while IFS= read -r line; do
        case "$line" in
          "worktree "*) record_detached ;;
          "HEAD "*)     cur_head="''${line#HEAD }" ;;
          detached)     cur_detached=1 ;;
        esac
      done <<<"$worktree_dump"
      record_detached

      cur_wt=""; cur_branch=""; cur_head=""; cur_bare=0; cur_detached=0; cur_locked=0
      flush() {
        [ -n "$cur_wt" ] || return 0
        process_worktree "$cur_wt" "$cur_branch" "$cur_head" "$cur_bare" "$cur_detached" "$cur_locked"
        cur_wt=""; cur_branch=""; cur_head=""; cur_bare=0; cur_detached=0; cur_locked=0
      }
      while IFS= read -r line; do
        case "$line" in
          "worktree "*)          flush; cur_wt="''${line#worktree }" ;;
          "HEAD "*)              cur_head="''${line#HEAD }" ;;
          "branch refs/heads/"*) cur_branch="''${line#branch refs/heads/}" ;;
          bare)                  cur_bare=1 ;;
          detached)              cur_detached=1 ;;
          locked*)               cur_locked=1 ;;
        esac
      done <<<"$worktree_dump"
      flush

      # --- phase 2: local branches without worktrees ----------------------
      branch_dump=$(repo_git for-each-ref refs/heads --format='%(refname:short)')

      while IFS= read -r branch; do
        [ -n "$branch" ] || continue
        is_protected "$branch" && continue
        [ -n "''${wt_branches[$branch]+x}" ] && continue  # decided in phase 1
        if ! tip=$(repo_git rev-parse --verify -q "refs/heads/$branch" 2>/dev/null); then
          log "kept branch $branch: cannot resolve local tip — fail closed"
          continue
        fi
        if [ -n "''${detached_heads[$tip]+x}" ]; then
          log "kept branch $branch: tip is checked out by a detached worktree — recovery anchor"
          continue
        fi
        if ! check_merged "$branch"; then
          log "kept branch $branch: $REASON"
          continue
        fi
        if repo_git branch -D "$branch" >/dev/null 2>&1; then
          log "deleted branch $branch (PR #$MERGED_PR merged at this tip, no worktree)"
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
