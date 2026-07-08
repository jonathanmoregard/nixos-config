# worktree-sweep: runtime-invocation harness for the merged-and-stale
# worktree sweeper (home/worktree-sweep-script.nix — the exact
# derivation the systemd user unit execs; asserted below via
# deployedExecStart, not a copy that can drift).
#
# Destructive automation ships only behind this harness. It builds a
# fixture bare repo + worktrees in the sandbox with real git, stubs
# `gh` (SWEEP_GH_BIN — writeShellApplication pins the real gh ahead of
# PATH, so a PATH stub can't shadow it), and asserts every fail-closed
# predicate:
#
#   merged + >7d old + clean + no live cwd → DELETED (worktree AND branch)
#   dirty (untracked work)                 → kept, logged
#   live cwd                               → kept, logged
#     (via SWEEP_EXTRA_LIVE_CWDS — /proc can't be faked in the nix
#      sandbox, so the harness injects extra "live" paths; the real
#      /proc scan still runs in every mode. 2026-07-07 incident class:
#      deleting a running session's cwd ENOENT-broke all its hooks.)
#   gh failure on one branch               → kept, logged
#   unmerged (no merged PR)                → kept, logged
#   merged but tip younger than 7d         → kept, logged
#   merged PR head != local tip            → kept, logged (branch reuse)
#   main worktree                          → never touched
#   branch w/o worktree: merged + old      → branch DELETED
#   branch w/o worktree: unmerged / young  → kept, logged
#   gh outage (auth check fails)           → ZERO deletions
#
# Run: nix build .#checks.x86_64-linux.worktree-sweep -L
{ pkgs, sweepScript, deployedExecStart }:

pkgs.runCommand "worktree-sweep-harness"
  {
    inherit deployedExecStart;
    sweep = "${sweepScript}/bin/nixos-worktree-sweep";
    nativeBuildInputs = with pkgs; [ bash git jq coreutils gnugrep ];
  } ''
    fail() {
      echo "FAIL: $*"
      for f in run1.log run2.log gh.log; do
        [ -f "$f" ] && { echo "=== $f ==="; cat "$f"; }
      done
      exit 1
    }

    # --- drift gate ----------------------------------------------------
    # The dellan unit must exec exactly the derivation under test.
    [ "$deployedExecStart" = "$sweep" ] || \
      fail "dellan ExecStart ($deployedExecStart) != tested script ($sweep)"

    export HOME="$PWD/home"
    mkdir -p "$HOME"
    git config --global user.email "harness@example.invalid"
    git config --global user.name "harness"
    git config --global init.defaultBranch main

    OLD=$(date -d "10 days ago" +%Y-%m-%dT%H:%M:%S)
    NEW=$(date -d "1 day ago" +%Y-%m-%dT%H:%M:%S)

    # --- fixture: bare repo + registered worktrees, real layout ---------
    mkfixture() {
      local root="$1"
      local bare="$root/nixos-config"
      local wts="$root/nixos-config-worktrees"
      mkdir -p "$root"
      git init -q "$root/seed"
      git -C "$root/seed" commit -q --allow-empty -m init
      git clone -q --bare "$root/seed" "$bare"
      mkdir -p "$wts"
      git -C "$bare" worktree add -q "$wts/main" main

      mkwt() {  # <name> <commit-date>
        git -C "$bare" worktree add -q -b "feat/$1" "$wts/$1" main
        echo "$1" > "$wts/$1/file.txt"
        git -C "$wts/$1" add file.txt
        GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
          git -C "$wts/$1" commit -qm "work on $1"
      }
      mkbranch() {  # <name> <commit-date> — branch with NO worktree
        git -C "$bare" worktree add -q -b "feat/$1" "$root/tmp-$1" main
        echo "$1" > "$root/tmp-$1/file.txt"
        git -C "$root/tmp-$1" add file.txt
        GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
          git -C "$root/tmp-$1" commit -qm "work on $1"
        git -C "$bare" worktree remove "$root/tmp-$1"
      }

      mkwt merged-old-clean "$OLD"
      mkwt dirty            "$OLD"
      mkwt live-cwd         "$OLD"
      mkwt gh-fails         "$OLD"
      mkwt unmerged         "$OLD"
      mkwt merged-recent    "$NEW"
      mkwt tip-mismatch     "$OLD"
      echo "uncommitted work" > "$wts/dirty/scratch.txt"

      mkbranch branch-merged-old "$OLD"
      mkbranch branch-unmerged   "$OLD"
      mkbranch branch-recent     "$NEW"
    }

    # --- gh stub ---------------------------------------------------------
    # Behavior keyed off the --head branch name; GH_STUB_DOWN=1 simulates
    # a full outage (auth check fails). Every call is logged for the
    # repo-slug assertion.
    mkdir -p bin
    export GH_LOG="$PWD/gh.log"
    cat > bin/gh <<'STUB'
    #!/bin/sh
    echo "$*" >> "$GH_LOG"
    if [ "''${GH_STUB_DOWN:-0}" = "1" ]; then
      echo "error connecting to api.github.com" >&2
      exit 1
    fi
    [ "''${1:-}" = "auth" ] && exit 0
    head=""; prev=""
    for a in "$@"; do
      [ "$prev" = "--head" ] && head="$a"
      prev="$a"
    done
    name="''${head#feat/}"
    case "$name" in
      unmerged|branch-unmerged)
        echo "[]" ;;
      gh-fails)
        echo "GraphQL: boom" >&2; exit 1 ;;
      tip-mismatch)
        echo '[{"number":77,"headRefOid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]' ;;
      *)
        tip=$(git -C "$FIXTURE_BARE" rev-parse "refs/heads/$head")
        printf '[{"number":42,"headRefOid":"%s"}]\n' "$tip" ;;
    esac
    STUB
    chmod +x bin/gh

    # =====================================================================
    # Run 1: gh healthy — mixed keep/delete decisions
    # =====================================================================
    mkfixture "$PWD/fix1"
    export FIXTURE_BARE="$PWD/fix1/nixos-config"
    WTS1="$PWD/fix1/nixos-config-worktrees"

    SWEEP_BARE_REPO="$FIXTURE_BARE" \
    SWEEP_WORKTREES_DIR="$WTS1" \
    SWEEP_GH_BIN="$PWD/bin/gh" \
    SWEEP_EXTRA_LIVE_CWDS="$WTS1/live-cwd" \
      "$sweep" > run1.log 2>&1 || fail "sweep exited non-zero on run 1"

    echo "=== run 1 decisions ==="
    cat run1.log

    has_branch() { git -C "$FIXTURE_BARE" show-ref --verify -q "refs/heads/$1"; }

    # 1. all predicates hold → worktree AND branch deleted
    [ ! -e "$WTS1/merged-old-clean" ] || fail "merged-old-clean worktree survived"
    if has_branch feat/merged-old-clean; then fail "feat/merged-old-clean branch survived"; fi
    grep -qF "deleted worktree $WTS1/merged-old-clean" run1.log \
      || fail "no deletion log line for merged-old-clean"

    # 2. dirty → kept, untracked work intact, logged
    [ -d "$WTS1/dirty" ] || fail "dirty worktree was deleted"
    [ -f "$WTS1/dirty/scratch.txt" ] || fail "dirty worktree lost its untracked file"
    has_branch feat/dirty || fail "feat/dirty branch was deleted"
    grep -qF "kept worktree $WTS1/dirty (branch feat/dirty): dirty" run1.log \
      || fail "no kept/dirty log line"

    # 3. live cwd → kept, logged (the incident-class predicate)
    [ -d "$WTS1/live-cwd" ] || fail "live-cwd worktree was deleted (2026-07-07 incident class)"
    has_branch feat/live-cwd || fail "feat/live-cwd branch was deleted"
    grep -qF "kept worktree $WTS1/live-cwd (branch feat/live-cwd): live" run1.log \
      || fail "no kept/live-cwd log line"

    # 4. per-branch gh failure → kept, logged
    [ -d "$WTS1/gh-fails" ] || fail "gh-fails worktree was deleted on gh error"
    has_branch feat/gh-fails || fail "feat/gh-fails branch was deleted on gh error"
    grep -qF "kept worktree $WTS1/gh-fails (branch feat/gh-fails): gh pr list failed" run1.log \
      || fail "no kept/gh-failure log line"

    # 5. unmerged → kept, logged
    [ -d "$WTS1/unmerged" ] || fail "unmerged worktree was deleted"
    has_branch feat/unmerged || fail "feat/unmerged branch was deleted"
    grep -qF "kept worktree $WTS1/unmerged (branch feat/unmerged): no merged PR" run1.log \
      || fail "no kept/unmerged log line"

    # 6. merged but young → kept, logged
    [ -d "$WTS1/merged-recent" ] || fail "merged-recent worktree was deleted before 7 days"
    grep -qF "kept worktree $WTS1/merged-recent (branch feat/merged-recent): tip commit only" run1.log \
      || fail "no kept/young log line"

    # 7. merged PR head != local tip (branch reused post-merge) → kept
    [ -d "$WTS1/tip-mismatch" ] || fail "tip-mismatch worktree was deleted (post-merge commits lost)"
    grep -qF "kept worktree $WTS1/tip-mismatch (branch feat/tip-mismatch): merged PR" run1.log \
      || fail "no kept/tip-mismatch log line"

    # 8. main is sacred
    [ -d "$WTS1/main" ] || fail "main worktree was deleted"
    has_branch main || fail "main branch was deleted"

    # 9. branch without worktree: merged + old → deleted
    if has_branch feat/branch-merged-old; then fail "feat/branch-merged-old survived"; fi
    grep -qF "deleted branch feat/branch-merged-old" run1.log \
      || fail "no deletion log line for branch-merged-old"

    # 10. branch without worktree: unmerged / young → kept, logged
    has_branch feat/branch-unmerged || fail "feat/branch-unmerged was deleted"
    grep -qF "kept branch feat/branch-unmerged: no merged PR" run1.log \
      || fail "no kept log line for branch-unmerged"
    has_branch feat/branch-recent || fail "feat/branch-recent was deleted before 7 days"
    grep -qF "kept branch feat/branch-recent: tip commit only" run1.log \
      || fail "no kept log line for branch-recent"

    # 11. gh queried against the pinned repo slug
    grep -q -- "--repo jonathanmoregard/nixos-config" gh.log \
      || fail "gh was not queried with the pinned repo slug"

    # =====================================================================
    # Run 2: gh outage — MUST mean zero deletions
    # =====================================================================
    mkfixture "$PWD/fix2"
    FIX2_BARE="$PWD/fix2/nixos-config"
    WTS2="$PWD/fix2/nixos-config-worktrees"

    GH_STUB_DOWN=1 \
    FIXTURE_BARE="$FIX2_BARE" \
    SWEEP_BARE_REPO="$FIX2_BARE" \
    SWEEP_WORKTREES_DIR="$WTS2" \
    SWEEP_GH_BIN="$PWD/bin/gh" \
      "$sweep" > run2.log 2>&1 || fail "sweep exited non-zero during gh outage"

    echo "=== run 2 (gh down) decisions ==="
    cat run2.log

    if grep -q "deleted" run2.log; then fail "gh outage produced deletions"; fi
    for wt in main merged-old-clean dirty live-cwd gh-fails unmerged merged-recent tip-mismatch; do
      [ -d "$WTS2/$wt" ] || fail "gh-down run removed worktree $wt"
    done
    for b in main feat/merged-old-clean feat/dirty feat/live-cwd feat/gh-fails \
             feat/unmerged feat/merged-recent feat/tip-mismatch \
             feat/branch-merged-old feat/branch-unmerged feat/branch-recent; do
      git -C "$FIX2_BARE" show-ref --verify -q "refs/heads/$b" \
        || fail "gh-down run deleted branch $b"
    done
    grep -q "gh auth unavailable" run2.log \
      || fail "gh-down run did not log the outage reason"

    echo "ok: delete fired only on merged+old+clean+no-cwd; every failure mode kept + logged; gh outage = zero deletions"
    touch $out
  ''
