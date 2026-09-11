# worktree-sweep: runtime-invocation harness for the merged-or-inactive
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
#   merged exact tip + clean + no live cwd → DELETED immediately
#                                         (worktree AND branch)
#   unmerged + >7d old + clean + no cwd   → worktree DELETED, branch KEPT
#   dirty (untracked work)                 → kept, logged
#   live cwd                               → kept, logged
#     (via SWEEP_EXTRA_LIVE_CWDS — /proc can't be faked in the nix
#      sandbox, so the harness injects extra "live" paths; the real
#      /proc scan still runs in every mode. 2026-07-07 incident class:
#      deleting a running session's cwd ENOENT-broke all its hooks.)
#   gh failure on one old branch           → worktree deleted, branch kept
#   unmerged but younger than 7d            → kept, logged
#   merged but tip younger than 7d          → deleted immediately
#   merged PR head != old local tip         → worktree deleted, branch kept
#   locked / detached                       → kept, logged; detached tip's
#                                             local branch also stays protected
#   ignored non-Nix content                 → kept intact, logged
#   verified /nix/store result links        → unlinked before removal
#   result-like link outside /nix/store     → kept intact, logged
#   main worktree                          → never touched
#   branch w/o worktree: merged exact tip   → branch DELETED immediately
#   branch w/o worktree: unmerged           → kept, logged
#   gh outage (auth check fails)            → age-only cleanup still runs;
#                                             no branch deletion
#
# Run 3 covers discovery mode (the production path since 2026-08-17):
# repos are found from the worktree roots rather than named, so the
# harness also asserts the derivations that discovery adds —
#
#   two repos under one root            → both swept in one run
#   repo's own main checkout            → never a candidate (outside roots)
#   non-default branch (master) repo    → its default branch protected
#   non-GitHub origin                   → age-only worktree cleanup; branch kept
#   worktree outside every root         → kept, logged
#
# Run: nix build .#checks.x86_64-linux.worktree-sweep -L
{ pkgs, sweepScript, deployedExecStart }:

pkgs.runCommand "worktree-sweep-harness"
  {
    inherit deployedExecStart;
    sweep = "${sweepScript}/bin/worktree-sweep";
    nativeBuildInputs = with pkgs; [ bash git jq coreutils gnugrep ];
  } ''
    fail() {
      echo "FAIL: $*"
      for f in run1.log run2.log run3.log gh.log; do
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
    # Model production, not a permissive sandbox. home/jonathan.nix sets this,
    # and it is precisely what broke the sweep once (#184): every
    # `git -C <bare-repo>` call returns "cannot use bare repository" and the
    # fail-closed predicates turn the whole run into a silent no-op. Without
    # this line the harness passes against a bare anchor that cannot work on
    # the real host — a green gate over a broken workflow.
    git config --global safe.bareRepository explicit

    OLD=$(date -d "10 days ago" +%Y-%m-%dT%H:%M:%S)
    NEW=$(date -d "1 day ago" +%Y-%m-%dT%H:%M:%S)

    # --- fixture: bare repo + registered worktrees, real layout ---------
    # The bare repo stays — it is still the shared object store on the real
    # host. What changed is the ANCHOR: every command addresses the `main`
    # worktree instead of the bare directory, because safe.bareRepository
    # above forbids discovering the latter. Same refs, same worktree list.
    mkfixture() {
      local root="$1"
      local bare="$root/nixos-config"
      local wts="$root/nixos-config-worktrees"
      local anchor="$wts/main"
      mkdir -p "$root"
      git init -q "$root/seed"
      printf 'result\nresult-*\nignored-*\n' > "$root/seed/.gitignore"
      git -C "$root/seed" add .gitignore
      git -C "$root/seed" commit -qm init
      git clone -q --bare "$root/seed" "$bare"
      mkdir -p "$wts"
      # Bootstrap only. Creating the first worktree is the one operation with
      # no anchor to use yet, and naming GIT_DIR explicitly is exactly the
      # escape hatch `explicit` is defined around. Everything after this goes
      # through $anchor.
      GIT_DIR="$bare" git worktree add -q "$anchor" main

      mkwt() {  # <name> <commit-date>
        git -C "$anchor" worktree add -q -b "feat/$1" "$wts/$1" main
        echo "$1" > "$wts/$1/file.txt"
        git -C "$wts/$1" add file.txt
        GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
          git -C "$wts/$1" commit -qm "work on $1"
      }
      mkbranch() {  # <name> <commit-date> — branch with NO worktree
        git -C "$anchor" worktree add -q -b "feat/$1" "$root/tmp-$1" main
        echo "$1" > "$root/tmp-$1/file.txt"
        git -C "$root/tmp-$1" add file.txt
        GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
          git -C "$root/tmp-$1" commit -qm "work on $1"
        git -C "$anchor" worktree remove "$root/tmp-$1"
      }

      mkwt merged-old-clean "$OLD"
      mkwt dirty            "$OLD"
      mkwt live-cwd         "$OLD"
      mkwt gh-fails         "$OLD"
      mkwt unmerged         "$OLD"
      mkwt merged-recent    "$NEW"
      mkwt tip-mismatch     "$OLD"
      mkwt locked           "$OLD"
      mkwt detached         "$OLD"
      mkwt unsafe-result    "$OLD"
      mkwt escaped-result   "$OLD"
      mkwt relative-result  "$OLD"
      mkwt tracked-result   "$OLD"
      mkwt nested-result    "$OLD"
      mkwt ignored-data     "$OLD"
      mkwt hidden-untracked "$OLD"
      mkwt assume-unchanged "$OLD"
      mkwt a-shared-anchor  "$OLD"
      echo "uncommitted work" > "$wts/dirty/scratch.txt"
      git -C "$anchor" worktree lock "$wts/locked"
      git -C "$wts/detached" checkout -q --detach
      git -C "$anchor" worktree add -q --detach "$wts/z-shared-detached" \
        feat/a-shared-anchor
      ln -s /nix/store/harness-output "$wts/unmerged/result"
      ln -s /tmp/not-a-nix-output "$wts/unsafe-result/result-unsafe"
      ln -s /nix/store/../../tmp/not-a-nix-output \
        "$wts/escaped-result/result-escape"
      ln -s ../nix/store/not-a-store-output \
        "$wts/relative-result/result-relative"
      ln -s /nix/store/tracked-purpose "$wts/tracked-result/result"
      git -C "$wts/tracked-result" add -f result
      GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" \
        git -C "$wts/tracked-result" commit -qm "track intentional result link"
      mkdir "$wts/nested-result/result-cache"
      ln -s /nix/store/important-reference \
        "$wts/nested-result/result-cache/valuable-link"
      echo "must survive" > "$wts/ignored-data/ignored-secret"
      echo "must survive" > "$wts/hidden-untracked/hidden.txt"
      git -C "$wts/hidden-untracked" config status.showUntrackedFiles no
      git -C "$wts/assume-unchanged" update-index --assume-unchanged file.txt
      echo "local edit must survive" > "$wts/assume-unchanged/file.txt"

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
        # Run 3 sweeps several repos in one invocation, so the tip is
        # resolved from whichever fixture repo knows the branch.
        dirs="''${FIXTURE_REPO_DIRS:-$FIXTURE_ANCHOR}"
        tip=""
        for r in $(echo "$dirs" | tr ':' ' '); do
          t=$(git -C "$r" rev-parse "refs/heads/$head" 2>/dev/null \
            || git --git-dir="$r" rev-parse "refs/heads/$head" 2>/dev/null) \
            || continue
          tip="$t"; break
        done
        [ -n "$tip" ] || { echo "[]"; exit 0; }
        printf '[{"number":42,"headRefOid":"%s"}]\n' "$tip" ;;
    esac
    STUB
    chmod +x bin/gh

    # =====================================================================
    # Run 1: gh healthy — mixed keep/delete decisions
    # =====================================================================
    mkfixture "$PWD/fix1"
    # Single-repo mode gets the ANCHOR, not the bare dir: under
    # safe.bareRepository the sweeper cannot operate on the latter at all.
    # The script documents this input as "a bare repo, or the main checkout's
    # toplevel"; on this host only the second half is reachable.
    export FIXTURE_ANCHOR="$PWD/fix1/nixos-config-worktrees/main"
    WTS1="$PWD/fix1/nixos-config-worktrees"

    SWEEP_BARE_REPO="$FIXTURE_ANCHOR" \
    SWEEP_WORKTREES_DIR="$WTS1" \
    SWEEP_GH_BIN="$PWD/bin/gh" \
    SWEEP_EXTRA_LIVE_CWDS="$WTS1/live-cwd" \
      "$sweep" > run1.log 2>&1 || fail "sweep exited non-zero on run 1"

    echo "=== run 1 decisions ==="
    cat run1.log

    has_branch() { git -C "$FIXTURE_ANCHOR" show-ref --verify -q "refs/heads/$1"; }

    # 1. merged-at-tip → worktree AND branch deleted, regardless of age
    [ ! -e "$WTS1/merged-old-clean" ] || fail "merged-old-clean worktree survived"
    if has_branch feat/merged-old-clean; then fail "feat/merged-old-clean branch survived"; fi
    grep -qF "deleted worktree $WTS1/merged-old-clean" run1.log \
      || fail "no deletion log line for merged-old-clean"
    [ ! -e "$WTS1/merged-recent" ] || fail "merged-recent worktree survived"
    if has_branch feat/merged-recent; then fail "feat/merged-recent branch survived"; fi
    grep -qF "deleted worktree $WTS1/merged-recent" run1.log \
      || fail "no deletion log line for merged-recent"

    # 2. dirty → kept, including untracked files hidden by repository config
    # and tracked edits hidden behind assume-unchanged index flags.
    for name in dirty hidden-untracked assume-unchanged; do
      [ -d "$WTS1/$name" ] || fail "$name dirty worktree was deleted"
      has_branch "feat/$name" || fail "feat/$name branch was deleted"
      grep -qF "kept worktree $WTS1/$name (branch feat/$name): dirty" run1.log \
        || fail "no kept/dirty log line for $name"
    done
    [ -f "$WTS1/dirty/scratch.txt" ] || fail "dirty worktree lost its untracked file"
    [ -f "$WTS1/hidden-untracked/hidden.txt" ] \
      || fail "hidden-untracked worktree lost its untracked file"
    grep -qF "local edit must survive" "$WTS1/assume-unchanged/file.txt" \
      || fail "assume-unchanged worktree lost its tracked edit"

    # 3. live cwd → kept, logged (the incident-class predicate)
    [ -d "$WTS1/live-cwd" ] || fail "live-cwd worktree was deleted (2026-07-07 incident class)"
    has_branch feat/live-cwd || fail "feat/live-cwd branch was deleted"
    grep -qF "kept worktree $WTS1/live-cwd (branch feat/live-cwd): live" run1.log \
      || fail "no kept/live-cwd log line"

    # 4. age-only eligibility removes worktrees but preserves branches.
    # A gh error, no merged PR, and a mismatched merged tip must never
    # authorize branch deletion. The ignored Nix out-link on `unmerged`
    # must not make non-force worktree removal fail.
    for name in gh-fails unmerged tip-mismatch; do
      [ ! -e "$WTS1/$name" ] || fail "$name old worktree survived"
      has_branch "feat/$name" || fail "feat/$name branch was deleted"
      grep -qF "deleted inactive worktree $WTS1/$name; preserved branch feat/$name" run1.log \
        || fail "no age-only deletion log line for $name"
    done
    grep -qF "preserved branch feat/unmerged (10d old, clean, no live cwd, removed 1 Nix result link(s))" run1.log \
      || fail "unmerged worktree's verified Nix result link was not removed"

    # 5. locked, detached, non-Nix result-like links, and arbitrary ignored
    # content fail closed. A branch sharing a detached worktree's exact tip
    # remains its recovery anchor and must not be deleted in phase 2.
    for name in locked detached unsafe-result escaped-result relative-result \
                tracked-result nested-result ignored-data z-shared-detached; do
      [ -d "$WTS1/$name" ] || fail "$name worktree was deleted"
    done
    has_branch feat/locked || fail "feat/locked branch was deleted"
    has_branch feat/detached || fail "feat/detached branch was deleted"
    has_branch feat/unsafe-result || fail "feat/unsafe-result branch was deleted"
    has_branch feat/escaped-result || fail "feat/escaped-result branch was deleted"
    has_branch feat/relative-result || fail "feat/relative-result branch was deleted"
    has_branch feat/tracked-result || fail "feat/tracked-result branch was deleted"
    has_branch feat/nested-result || fail "feat/nested-result branch was deleted"
    has_branch feat/ignored-data || fail "feat/ignored-data branch was deleted"
    has_branch feat/a-shared-anchor \
      || fail "detached worktree did not preserve its matching branch"
    [ -L "$WTS1/unsafe-result/result-unsafe" ] \
      || fail "unsafe result-like link was removed"
    [ -L "$WTS1/escaped-result/result-escape" ] \
      || fail "lexically escaped result-like link was removed"
    [ -L "$WTS1/relative-result/result-relative" ] \
      || fail "relative result-like link was removed"
    [ -L "$WTS1/tracked-result/result" ] \
      || fail "tracked result-like link was removed"
    [ -L "$WTS1/nested-result/result-cache/valuable-link" ] \
      || fail "nested ignored result-like link was removed"
    grep -qF "kept worktree $WTS1/locked (branch feat/locked): locked" run1.log \
      || fail "no kept/locked log line"
    grep -qF "kept worktree $WTS1/detached: detached HEAD" run1.log \
      || fail "no kept/detached log line"
    grep -qF "result-like symlink $WTS1/unsafe-result/result-unsafe targets outside /nix/store" run1.log \
      || fail "no kept/unsafe-result log line"
    [ -f "$WTS1/ignored-data/ignored-secret" ] \
      || fail "ignored non-Nix content was removed"
    grep -qF "ignored non-Nix content present: ignored-secret" run1.log \
      || fail "no kept/ignored-data log line"

    # 6. main is sacred
    [ -d "$WTS1/main" ] || fail "main worktree was deleted"
    has_branch main || fail "main branch was deleted"

    # 7. branches without worktrees: exact-tip merged branches delete
    # immediately; age alone never deletes an unmerged branch.
    if has_branch feat/branch-merged-old; then fail "feat/branch-merged-old survived"; fi
    grep -qF "deleted branch feat/branch-merged-old" run1.log \
      || fail "no deletion log line for branch-merged-old"
    if has_branch feat/branch-recent; then fail "feat/branch-recent survived"; fi
    grep -qF "deleted branch feat/branch-recent" run1.log \
      || fail "no deletion log line for branch-recent"
    has_branch feat/branch-unmerged || fail "feat/branch-unmerged was deleted"
    grep -qF "kept branch feat/branch-unmerged: no merged PR" run1.log \
      || fail "no kept log line for branch-unmerged"

    # 8. gh queried against the pinned repo slug
    grep -q -- "--repo jonathanmoregard/nixos-config" gh.log \
      || fail "gh was not queried with the pinned repo slug"

    # =====================================================================
    # Run 2: gh outage — age-only worktree cleanup continues, while PR
    # eligibility and every branch deletion fail closed.
    # =====================================================================
    mkfixture "$PWD/fix2"
    FIX2_ANCHOR="$PWD/fix2/nixos-config-worktrees/main"
    WTS2="$PWD/fix2/nixos-config-worktrees"

    GH_STUB_DOWN=1 \
    FIXTURE_ANCHOR="$FIX2_ANCHOR" \
    SWEEP_BARE_REPO="$FIX2_ANCHOR" \
    SWEEP_WORKTREES_DIR="$WTS2" \
    SWEEP_GH_BIN="$PWD/bin/gh" \
    SWEEP_EXTRA_LIVE_CWDS="$WTS2/live-cwd" \
      "$sweep" > run2.log 2>&1 || fail "sweep exited non-zero during gh outage"

    echo "=== run 2 (gh down) decisions ==="
    cat run2.log

    for wt in merged-old-clean gh-fails unmerged tip-mismatch; do
      [ ! -e "$WTS2/$wt" ] || fail "gh-down age cleanup kept old worktree $wt"
      grep -qF "deleted inactive worktree $WTS2/$wt; preserved branch feat/$wt" run2.log \
        || fail "gh-down run lacks age-only deletion log for $wt"
    done
    for wt in main dirty live-cwd merged-recent locked detached unsafe-result \
              escaped-result relative-result tracked-result ignored-data \
              nested-result hidden-untracked assume-unchanged z-shared-detached; do
      [ -d "$WTS2/$wt" ] || fail "gh-down run removed protected worktree $wt"
    done
    for b in main feat/merged-old-clean feat/dirty feat/live-cwd feat/gh-fails \
             feat/unmerged feat/merged-recent feat/tip-mismatch \
             feat/locked feat/detached feat/unsafe-result feat/escaped-result \
             feat/relative-result feat/tracked-result feat/ignored-data \
             feat/nested-result feat/hidden-untracked feat/assume-unchanged \
             feat/a-shared-anchor \
             feat/branch-merged-old feat/branch-unmerged feat/branch-recent; do
      git -C "$FIX2_ANCHOR" show-ref --verify -q "refs/heads/$b" \
        || fail "gh-down run deleted branch $b"
    done
    grep -q "gh auth unavailable.*age-only cleanup remains active" run2.log \
      || fail "gh-down run did not log the outage reason"

    # =====================================================================
    # Run 3: discovery mode — repos found from the roots, not named
    # =====================================================================
    # Three repos, each a normal checkout OUTSIDE the swept root with its
    # worktrees INSIDE it. That layout is the production one (~/.claude
    # and ~/worktrees) and is what keeps a repo's own checkout safe: it is
    # never a candidate because it never lives under a root.
    ROOT3="$PWD/fix3/roots"
    mkdir -p "$ROOT3"

    mkrepo3() {  # <name> <default-branch> <origin-url>
      local name="$1" defbranch="$2" url="$3"
      local seed="$PWD/fix3/seed-$name" repo="$PWD/fix3/$name"
      git init -q -b "$defbranch" "$seed"
      git -C "$seed" commit -q --allow-empty -m init
      git clone -q "$seed" "$repo"           # sets refs/remotes/origin/HEAD
      git -C "$repo" remote set-url origin "$url"
    }

    mkwt3() {  # <repo-name> <branch> <worktree-path> <commit-date>
      local repo="$PWD/fix3/$1" branch="$2" path="$3" date="$4"
      git -C "$repo" worktree add -q -b "$branch" "$path"
      echo "$branch" > "$path/file.txt"
      git -C "$path" add file.txt
      GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        git -C "$path" commit -qm "work on $branch"
    }

    # A standalone CLONE sitting under a root, checked out on a merged,
    # old, clean feature branch. ~/Repos/nixos-config-worktrees holds one
    # of these (scraper-microvm) — discovery resolves it to a repo whose
    # only "worktree" is itself, so without the own-checkout guard the
    # sweep would try to delete a full clone, objects and all. Its own
    # unpushed commits are invisible to `git status`, so this fails closed
    # regardless of the other predicates.
    mkstandalone3() {  # <path> <branch> <commit-date>
      local path="$1" branch="$2" date="$3" seed="$PWD/fix3/seed-standalone"
      git init -q -b main "$seed"
      git -C "$seed" commit -q --allow-empty -m init
      git clone -q "$seed" "$path"
      git -C "$path" remote set-url origin "git@github.com:jonathanmoregard/standalone.git"
      git -C "$path" checkout -q -b "$branch"
      echo standalone > "$path/file.txt"
      git -C "$path" add file.txt
      GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        git -C "$path" commit -qm "work on $branch"
    }

    # A worktree whose OWNER is a bare repo — the ~/Repos/nixos-config shape.
    # Discovery resolves a linked worktree through --git-common-dir to the bare
    # directory. `safe.bareRepository = explicit` rejects `git -C`, so the
    # sweeper must address this validated owner via explicit `--git-dir`.
    mkbare3() {  # <worktree-path> <branch> <commit-date>
      local wtpath="$1" branch="$2" date="$3"
      local seed="$PWD/fix3/seed-bare" bare="$PWD/fix3/bare-owner.git"
      git init -q -b main "$seed"
      git -C "$seed" commit -q --allow-empty -m init
      git clone -q --bare "$seed" "$bare"
      # GIT_DIR throughout: every one of these would be refused via `git -C`.
      GIT_DIR="$bare" git remote set-url origin \
        "git@github.com:jonathanmoregard/bare-owner.git"
      GIT_DIR="$bare" git worktree add -q -b "$branch" "$wtpath"
      echo bare > "$wtpath/file.txt"
      git -C "$wtpath" add file.txt
      GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        git -C "$wtpath" commit -qm "work on $branch"
    }

    mkrepo3 repoA main   "git@github.com:jonathanmoregard/nixos-config.git"
    mkrepo3 repoB master "https://github.com/jonathanmoregard/dotclaude.git"
    mkrepo3 repoC main   "$PWD/fix3/seed-repoC"   # not GitHub → no PR state
    mkrepo3 repoD main   "https://notgithub.com/org/repo.git"

    mkwt3 repoA feat/a-merged-old "$ROOT3/a-merged-old" "$OLD"
    mkwt3 repoA feat/a-outside    "$PWD/fix3/outside"   "$OLD"
    mkwt3 repoB feat/b-merged-old "$ROOT3/b-merged-old" "$OLD"
    mkwt3 repoC feat/c-merged-old "$ROOT3/c-merged-old" "$OLD"
    mkwt3 repoD feat/d-fake-github "$ROOT3/d-fake-github" "$OLD"
    mkstandalone3 "$ROOT3/standalone" feat/d-standalone "$OLD"
    mkbare3 "$ROOT3/bare-owned" feat/e-bare-owned "$OLD"

    FIXTURE_REPO_DIRS="$PWD/fix3/repoA:$PWD/fix3/repoB:$PWD/fix3/repoC:$PWD/fix3/repoD:$ROOT3/standalone:$PWD/fix3/bare-owner.git" \
    SWEEP_ROOTS="$ROOT3" \
    SWEEP_GH_BIN="$PWD/bin/gh" \
      "$sweep" > run3.log 2>&1 || fail "sweep exited non-zero on run 3"

    echo "=== run 3 (discovery) decisions ==="
    cat run3.log

    # 12. every repo owning a worktree under the root is swept in one run
    [ ! -e "$ROOT3/a-merged-old" ] || fail "repoA worktree survived discovery-mode sweep"
    [ ! -e "$ROOT3/b-merged-old" ] || fail "repoB worktree survived — only the first repo was swept?"
    if git -C "$PWD/fix3/repoA" show-ref --verify -q refs/heads/feat/a-merged-old
      then fail "repoA branch survived"; fi
    if git -C "$PWD/fix3/repoB" show-ref --verify -q refs/heads/feat/b-merged-old
      then fail "repoB branch survived"; fi

    # 13. per-repo slug derivation: repoB was queried under its OWN slug
    grep -q -- "--repo jonathanmoregard/dotclaude" gh.log \
      || fail "repoB was not queried with its derived slug"

    # 14. each repo's own checkout and default branch are untouched —
    #     repoB's default is master, which the old main-only guard missed
    for r in repoA repoB repoC repoD; do
      [ -d "$PWD/fix3/$r" ] || fail "$r checkout was deleted"
    done
    git -C "$PWD/fix3/repoB" show-ref --verify -q refs/heads/master \
      || fail "repoB's default branch (master) was deleted"
    git -C "$PWD/fix3/repoA" show-ref --verify -q refs/heads/main \
      || fail "repoA's default branch was deleted"

    # 15. non-GitHub origin → age-only worktree cleanup, branch preserved.
    # Missing PR state must not block safe space recovery or authorize
    # irreversible branch deletion.
    [ ! -e "$ROOT3/c-merged-old" ] \
      || fail "repoC old worktree survived age-only cleanup"
    git -C "$PWD/fix3/repoC" show-ref --verify -q refs/heads/feat/c-merged-old \
      || fail "repoC branch was deleted without GitHub PR state"
    grep -qF "deleted inactive worktree $ROOT3/c-merged-old; preserved branch feat/c-merged-old" run3.log \
      || fail "no age-only deletion log line for non-GitHub repo"
    grep -q "is not a GitHub repo.*age-only cleanup only" run3.log \
      || fail "no age-only capability log for the non-GitHub repo"

    # 16. A hostname merely containing github.com is not GitHub. It may get
    # age-only cleanup, but must never get PR-authorized branch deletion.
    [ ! -e "$ROOT3/d-fake-github" ] \
      || fail "fake-GitHub old worktree survived age-only cleanup"
    git -C "$PWD/fix3/repoD" show-ref --verify -q refs/heads/feat/d-fake-github \
      || fail "fake-GitHub origin authorized branch deletion"
    grep -qF "origin 'https://notgithub.com/org/repo.git' is not a GitHub repo" run3.log \
      || fail "fake-GitHub origin was accepted as GitHub"

    # 17. a standalone clone under a root is never its own deletion
    #     candidate, however merged/old/clean its branch looks
    [ -d "$ROOT3/standalone" ] || fail "standalone clone under the root was deleted"
    [ -f "$ROOT3/standalone/file.txt" ] || fail "standalone clone lost its content"
    git -C "$ROOT3/standalone" show-ref --verify -q refs/heads/feat/d-standalone \
      || fail "standalone clone's branch was deleted"
    grep -qF "the repo's own checkout" run3.log \
      || fail "no kept log line for the standalone clone"

    # 18. worktree outside every root → kept, logged
    [ -d "$PWD/fix3/outside" ] || fail "worktree outside the roots was deleted"
    grep -qF "outside the swept roots" run3.log \
      || fail "no kept log line for the out-of-root worktree"

    # 19. a bare-owned worktree is swept through explicit `--git-dir`, despite
    #     safe.bareRepository rejecting implicit `git -C` access.
    [ ! -e "$ROOT3/bare-owned" ] || fail "bare-owned worktree survived"
    if GIT_DIR="$PWD/fix3/bare-owner.git" git show-ref --verify -q \
      refs/heads/feat/e-bare-owned
      then fail "bare-owned merged branch survived"; fi
    grep -qF "deleted worktree $ROOT3/bare-owned + branch feat/e-bare-owned" run3.log \
      || fail "bare-owned repo was not swept through explicit --git-dir"
    GIT_DIR="$PWD/fix3/bare-owner.git" git remote get-url origin >/dev/null \
      || fail "fixture is wrong: bare-owner has no origin"

    echo "ok: merged-at-tip or old worktrees delete only when safe; age-only cleanup preserves branches; result links are validated; gh outage and non-GitHub repos still age-sweep; protected work remains"
    touch $out
  ''
