# crontab-drift: runtime-invocation harness for the PR-gated live-vs-
# declared crontab drift writer (home/crontab-drift-script.nix — the
# exact derivation the systemd user unit execs; asserted below via
# deployedExecStart, not a copy that can drift).
#
# The script pushes branches and opens PRs against the config repo that
# builds this machine, so it ships only behind this harness. Fixtures
# are real git repos in the sandbox (a bare "origin" plus a production-
# shaped bare working repo with remote-tracking refs); `gh`, `crontab`
# and `notify-send` are stubbed via the CRONDRIFT_* env overrides —
# writeShellApplication pins the real binaries ahead of PATH, so a PATH
# stub could not shadow them.
#
# Contract asserted here:
#
#   no drift                       → exit 0, no branch, no PR
#   live-only schedule entry       → branch crontab-drift/<hash> pushed,
#                                    exactly one PR opened, `main` on
#                                    origin never moves
#   Nix metacharacters in an entry → escaped before insertion (a crontab
#                                    line must not be able to inject Nix)
#   same drift, second run         → no second PR (idempotence)
#   branch exists but has no PR    → PR opened for the existing branch,
#                                    branch tip unchanged (crash recovery)
#   different drift                → different branch (one PR per drift)
#   declared-but-not-live          → exit 0, journal names it, critical
#                                    notification, nothing pushed
#   live-only non-schedule line    → never auto-filed, critical
#                                    notification, nothing pushed
#   no crontab installed at all    → exit 0 (empty live, not an error)
#   crontab binary missing         → LOUD (non-zero)
#   gh unauthenticated + drift     → LOUD (non-zero), nothing pushed
#   anchor missing from the config → LOUD (non-zero), nothing pushed
#
# Run: nix build .#checks.x86_64-linux.crontab-drift -L
{ pkgs, driftScript, deployedExecStart }:

pkgs.runCommand "crontab-drift-harness"
  {
    inherit deployedExecStart;
    check = "${driftScript}/bin/crontab-drift-check";
    nativeBuildInputs = with pkgs; [
      bash git jq coreutils gnugrep gnused glibcLocales
    ];
    localeArchive = "${pkgs.glibcLocales}/lib/locale/locale-archive";
  } ''
    fail() {
      echo "FAIL: $*"
      for f in run*.log gh.log notify.log pr-create.log; do
        if [ -f "$f" ]; then echo "=== $f ==="; cat "$f"; fi
      done
      exit 1
    }

    # --- drift gate ----------------------------------------------------
    # The dellan unit must exec exactly the derivation under test.
    [ "$deployedExecStart" = "$check" ] || \
      fail "dellan ExecStart ($deployedExecStart) != tested script ($check)"

    export HOME="$PWD/home"
    mkdir -p "$HOME"
    git config --global user.email "harness@example.invalid"
    git config --global user.name "harness"
    git config --global init.defaultBranch main

    export GH_LOG="$PWD/gh.log"
    export PR_CREATE_LOG="$PWD/pr-create.log"
    export PR_STATE_DIR="$PWD/pr-state"
    mkdir -p "$PR_STATE_DIR"
    : > "$GH_LOG"
    : > "$PR_CREATE_LOG"
    : > "$PWD/notify.log"
    export NOTIFY_LOG="$PWD/notify.log"

    ANCHOR="crontab-drift-check inserts newly-found live entries directly above this line"

    # Payloads built with printf escapes so this harness source contains
    # no literal Nix metacharacter sequence of its own.
    DOLLAR_BRACE=$(printf '\x24\x7b')
    QUOTE1=$(printf '\x27')
    QUOTE2=$(printf '\x27\x27')
    # ''\'  — the generic Nix escape applied to every single quote.
    QUOTE_ESC=$(printf '\x27\x27\x5c\x27')
    ESC_INTERP="$QUOTE2$DOLLAR_BRACE"

    # --- fixtures ------------------------------------------------------
    # <root>/origin  bare repo standing in for github
    # <root>/bare    production-shaped bare clone WITH remote-tracking
    #                refs (the real ~/Repos/nixos-config is configured
    #                exactly this way; `worktree add origin/main` needs it)
    mkfixture() {  # <root> <with-anchor:1|0> [extra-declared-entry]
      local root="$1" anchor="$2" extra="''${3:-}"
      mkdir -p "$root/seed/home"
      git init -q "$root/seed"
      {
        echo '{ config, pkgs, lib, ... }:'
        echo '{'
        echo '  home.file.".config/crontab".text = '"$QUOTE2"
        echo '    CRON_TZ=Europe/Stockholm'
        echo '    0 5 * * * /bin/declared-job'
        if [ -n "$extra" ]; then
          echo "    $extra"
        fi
        if [ "$anchor" = "1" ]; then
          echo "    # $ANCHOR"
        fi
        echo "  $QUOTE2;"
        echo '}'
      } > "$root/seed/home/jonathan-linux.nix"
      git -C "$root/seed" add -A
      git -C "$root/seed" commit -qm "seed"
      git clone -q --bare "$root/seed" "$root/origin"
      git clone -q --bare "$root/origin" "$root/bare"
      git -C "$root/bare" config remote.origin.fetch \
        '+refs/heads/*:refs/remotes/origin/*'
      git -C "$root/bare" fetch -q origin
    }

    # --- stubs ---------------------------------------------------------
    mkdir -p bin
    cat > bin/gh <<'STUB'
    #!/bin/sh
    echo "$*" >> "$GH_LOG"
    if [ "''${GH_STUB_DOWN:-0}" = "1" ]; then
      echo "gh: could not authenticate" >&2
      exit 1
    fi
    if [ "$1" = "auth" ]; then exit 0; fi
    head=""; prev=""
    for a in "$@"; do
      if [ "$prev" = "--head" ]; then head="$a"; fi
      prev="$a"
    done
    key=$(printf '%s' "$head" | tr '/' '_')
    case "$2" in
      list)
        if [ -f "$PR_STATE_DIR/$key.closed" ]; then
          echo '[{"number":42,"state":"CLOSED"}]'
        elif [ -f "$PR_STATE_DIR/$key.merged" ]; then
          echo '[{"number":42,"state":"MERGED"}]'
        elif [ -f "$PR_STATE_DIR/$key" ]; then
          echo '[{"number":42,"state":"OPEN"}]'
        else
          echo '[]'
        fi ;;
      create)
        : > "$PR_STATE_DIR/$key"
        echo "created $head" >> "$PR_CREATE_LOG"
        echo "https://github.com/jonathanmoregard/nixos-config/pull/42" ;;
      *)
        echo "unexpected gh invocation: $*" >&2
        exit 1 ;;
    esac
    STUB
    chmod +x bin/gh

    # `crontab -l` stub: prints $CRONTAB_FIXTURE, or reproduces vixie
    # cron's "no crontab for <user>" (rc 1) when the fixture is absent.
    cat > bin/crontab <<'STUB'
    #!/bin/sh
    if [ ! -f "''${CRONTAB_FIXTURE:-/nonexistent}" ]; then
      echo "no crontab for harness" >&2
      exit 1
    fi
    cat "$CRONTAB_FIXTURE"
    STUB
    chmod +x bin/crontab

    cat > bin/notify-send <<'STUB'
    #!/bin/sh
    echo "$*" >> "$NOTIFY_LOG"
    STUB
    chmod +x bin/notify-send

    export CRONDRIFT_GH_BIN="$PWD/bin/gh"
    export CRONDRIFT_CRONTAB_BIN="$PWD/bin/crontab"
    export CRONDRIFT_NOTIFY_BIN="$PWD/bin/notify-send"
    export CRONDRIFT_STATE_DIR="$PWD/state"

    # The declaration under comparison. Byte-identical to the crontab
    # block in the fixture .nix so a clean run really is clean.
    mk_declared() {
      {
        echo 'CRON_TZ=Europe/Stockholm'
        echo '0 5 * * * /bin/declared-job'
        echo "# $ANCHOR"
      } > "$1"
    }

    mkfixture "$PWD/fix" 1
    ORIGIN="$PWD/fix/origin"
    export CRONDRIFT_BARE_REPO="$PWD/fix/bare"
    mk_declared "$PWD/declared"
    export CRONDRIFT_DECLARED_FILE="$PWD/declared"

    MAIN_BEFORE=$(git -C "$ORIGIN" rev-parse refs/heads/main)

    remote_branches() {
      git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads \
        | grep -v '^main$' || true
    }
    pr_creates() { grep -c created "$PR_CREATE_LOG" || true; }

    # ===================================================================
    # 1. No drift — live matches the declaration exactly.
    # ===================================================================
    cp "$PWD/declared" "$PWD/live-clean"
    # cron's own banner must be ignored, not read as drift.
    sed -i '1i # DO NOT EDIT THIS FILE - edit the master and reinstall.' \
      "$PWD/live-clean"
    CRONTAB_FIXTURE="$PWD/live-clean" "$check" > run1.log 2>&1 \
      || fail "clean run exited non-zero"
    grep -q "matches the declaration" run1.log \
      || fail "clean run did not log the no-drift outcome"
    [ -z "$(remote_branches)" ] || fail "clean run pushed a branch: $(remote_branches)"
    [ "$(pr_creates)" = "0" ] || fail "clean run opened a PR"
    if grep -q "pr create" "$GH_LOG"; then fail "clean run called gh pr create"; fi
    echo "ok 1: no drift → silent, no branch, no PR"

    # ===================================================================
    # 2. Live-only entries — one carries Nix metacharacters.
    # ===================================================================
    # Two payloads. The second is the odd-quote-parity vector: escaping
    # only DOUBLED quotes leaves a lone quote in front of the escape the
    # interpolation gets, and Nix relexes that three-quote run as a
    # literal doubled quote followed by a LIVE interpolation. Verified
    # against the real evaluator — the escaped-only-doubled form of
    # `cmd 'DOLLARBRACE HOME}/y'` evaluates to "error: undefined
    # variable 'HOME'" instead of staying text. A quoted shell variable
    # is an ordinary crontab line, and home/jonathan-linux.nix has
    # config/pkgs/lib in scope, so this was arbitrary evaluation-time
    # code execution driven by the live crontab.
    INJECT="13 4 * * * /bin/inject $DOLLAR_BRACE""pkgs.hello} tail$QUOTE2"
    PARITY="21 4 * * * /bin/p $QUOTE1$DOLLAR_BRACE""HOME}/x$QUOTE1"
    cp "$PWD/declared" "$PWD/live-drift"
    {
      echo '7 7 * * * /bin/stray-job >> /tmp/stray.log 2>&1'
      echo "$INJECT"
      echo "$PARITY"
    } >> "$PWD/live-drift"
    CRONTAB_FIXTURE="$PWD/live-drift" "$check" > run2.log 2>&1 \
      || fail "drift run exited non-zero"
    BRANCH=$(remote_branches)
    case "$BRANCH" in
      crontab-drift/*) : ;;
      *) fail "expected one crontab-drift/<hash> branch, got '$BRANCH'" ;;
    esac
    [ "$(pr_creates)" = "1" ] || fail "expected exactly 1 PR, got $(pr_creates)"
    grep -q "stray: 7 7 \* \* \* /bin/stray-job" run2.log \
      || fail "stray entry not named in the log"

    # The pushed commit must carry BOTH entries, Nix-escaped.
    git -C "$ORIGIN" show "$BRANCH:home/jonathan-linux.nix" > committed.nix
    grep -qF '7 7 * * * /bin/stray-job' committed.nix \
      || fail "stray entry missing from the pushed config"
    # Golden escaped forms, not substring counting. Counting raw
    # interpolation openers against escaped ones cannot see the parity
    # bug at all: the injecting three-quote sequence CONTAINS the
    # escaped form as a substring, so the two counts matched while the
    # config happily interpolated live. Assert the exact bytes each
    # payload must become instead.
    grep -qF "/bin/inject $ESC_INTERP""pkgs.hello} tail$QUOTE_ESC$QUOTE_ESC" \
      committed.nix \
      || fail "interpolation/doubled-quote payload not escaped as expected"
    grep -qF "/bin/p $QUOTE_ESC$ESC_INTERP""HOME}/x$QUOTE_ESC" committed.nix \
      || fail "odd-quote-parity payload not escaped as expected (Nix injection)"
    # Belt: every single quote in the inserted lines must be part of an
    # escape, so no bare quote can pair with another to end the string.
    inserted=$(grep -F "/bin/p " committed.nix)
    stripped=''${inserted//"$QUOTE_ESC"/}
    stripped=''${stripped//"$ESC_INTERP"/}
    case "$stripped" in
      *"$QUOTE1"*) fail "unescaped single quote survives in the pushed config: $inserted" ;;
    esac
    # Provenance + review guidance must reach the human.
    git -C "$ORIGIN" log -1 --format=%B "$BRANCH" > commitmsg.txt
    grep -q "crontab-drift-check" commitmsg.txt \
      || fail "commit message does not name its author"
    grep -q "Pre-push checklist:" commitmsg.txt \
      || fail "commit message lacks the pre-push checklist trailer"
    echo "ok 2: drift → one branch, one PR, entries escaped for Nix"

    # ===================================================================
    # 3. Same drift again — must NOT open a second PR.
    # ===================================================================
    TIP_AFTER_PUSH=$(git -C "$ORIGIN" rev-parse "$BRANCH")
    CRONTAB_FIXTURE="$PWD/live-drift" "$check" > run3.log 2>&1 \
      || fail "repeat run exited non-zero"
    [ "$(pr_creates)" = "1" ] \
      || fail "repeat run opened a duplicate PR ($(pr_creates) total)"
    grep -q "already under review as PR #42" run3.log \
      || fail "repeat run did not report the existing PR"
    [ "$(git -C "$ORIGIN" rev-parse "$BRANCH")" = "$TIP_AFTER_PUSH" ] \
      || fail "repeat run moved the branch tip"
    echo "ok 3: same drift twice → still one PR"

    # ===================================================================
    # 4. Branch pushed but PR missing (previous run died mid-flight).
    # ===================================================================
    rm -f "$PR_STATE_DIR"/*
    CRONTAB_FIXTURE="$PWD/live-drift" "$check" > run4.log 2>&1 \
      || fail "recovery run exited non-zero"
    [ "$(pr_creates)" = "2" ] \
      || fail "recovery run did not open the missing PR"
    grep -q "carries no PR" run4.log \
      || fail "recovery run did not explain itself"
    [ "$(git -C "$ORIGIN" rev-parse "$BRANCH")" = "$TIP_AFTER_PUSH" ] \
      || fail "recovery run re-pushed instead of reusing the branch"
    echo "ok 4: pushed-but-unfiled branch → PR opened, no re-push"

    # ===================================================================
    # 5. Different drift — different branch (one PR per distinct drift).
    # ===================================================================
    cp "$PWD/declared" "$PWD/live-drift2"
    echo '9 9 * * * /bin/other-job' >> "$PWD/live-drift2"
    CRONTAB_FIXTURE="$PWD/live-drift2" "$check" > run5.log 2>&1 \
      || fail "second-drift run exited non-zero"
    [ "$(remote_branches | wc -l)" = "2" ] \
      || fail "expected 2 drift branches, got: $(remote_branches | tr '\n' ' ')"
    [ "$(pr_creates)" = "3" ] || fail "second drift did not get its own PR"
    echo "ok 5: distinct drift → distinct branch"

    # ===================================================================
    # 6. Declared but NOT live — surfaced, never pushed.
    # ===================================================================
    BRANCHES_BEFORE=$(remote_branches | wc -l)
    : > notify.log
    {
      echo 'CRON_TZ=Europe/Stockholm'
      echo "# $ANCHOR"
    } > "$PWD/live-missing"
    CRONTAB_FIXTURE="$PWD/live-missing" "$check" > run6.log 2>&1 \
      || fail "declared-but-not-live run exited non-zero"
    grep -q "missing-live: 0 5 \* \* \* /bin/declared-job" run6.log \
      || fail "missing-live entry not named in the log"
    grep -q "critical" notify.log \
      || fail "declared-but-not-live did not raise a critical notification"
    [ "$(remote_branches | wc -l)" = "$BRANCHES_BEFORE" ] \
      || fail "declared-but-not-live pushed a branch"
    # Second identical run: journal keeps reporting, the popup does not.
    : > notify.log
    CRONTAB_FIXTURE="$PWD/live-missing" "$check" > run6b.log 2>&1 \
      || fail "repeat declared-but-not-live run exited non-zero"
    grep -q "missing-live:" run6b.log \
      || fail "repeat run stopped journalling the finding"
    [ ! -s notify.log ] \
      || fail "unchanged finding re-notified (alarm fatigue): $(cat notify.log)"
    echo "ok 6: inverse drift → surfaced + deduped, nothing pushed"

    # ===================================================================
    # 7. Live-only line that is NOT a schedule entry — never auto-filed.
    #    A stale PATH= adopted into the declaration would silently change
    #    the environment of every job.
    # ===================================================================
    : > notify.log
    cp "$PWD/declared" "$PWD/live-env"
    echo 'PATH=/stale/path:/usr/bin' >> "$PWD/live-env"
    CRONTAB_FIXTURE="$PWD/live-env" "$check" > run7.log 2>&1 \
      || fail "unclassified-line run exited non-zero"
    grep -q "unclassified: PATH=/stale/path" run7.log \
      || fail "env assignment was not reported as unclassified"
    grep -q "critical" notify.log \
      || fail "unclassified live-only line did not raise a critical notification"
    [ "$(remote_branches | wc -l)" = "$BRANCHES_BEFORE" ] \
      || fail "unclassified line was pushed as a PR"
    echo "ok 7: env assignment → reported, never auto-filed"

    # ===================================================================
    # 8. No crontab installed at all — empty live, not an error.
    # ===================================================================
    CRONTAB_FIXTURE="/nonexistent" "$check" > run8.log 2>&1 \
      || fail "missing-crontab-for-user run exited non-zero"
    grep -q "live crontab is empty" run8.log \
      || fail "empty live crontab not recognised"
    echo "ok 8: no crontab installed → empty live, exit 0"

    # ===================================================================
    # 9. crontab BINARY missing — loud.
    # ===================================================================
    if CRONDRIFT_CRONTAB_BIN="$PWD/bin/does-not-exist" \
       CRONTAB_FIXTURE="$PWD/live-drift" "$check" > run9.log 2>&1; then
      fail "missing crontab binary exited 0 — silent blindness"
    fi
    grep -q "crontab binary not executable" run9.log \
      || fail "missing crontab binary did not say so"
    echo "ok 9: crontab binary absent → loud failure"

    # ===================================================================
    # 10. gh unauthenticated WITH drift — loud, nothing pushed.
    #     (No drift + no gh is NOT a failure: gh is only consulted when
    #     there is something to file.)
    # ===================================================================
    BRANCHES_BEFORE=$(remote_branches | wc -l)
    if GH_STUB_DOWN=1 CRONTAB_FIXTURE="$PWD/live-drift" "$check" \
         > run10.log 2>&1; then
      fail "unfilable drift exited 0 — this is the silence the unit exists to break"
    fi
    grep -q "gh is unavailable/unauthenticated" run10.log \
      || fail "gh outage was not named as the reason"
    [ "$(remote_branches | wc -l)" = "$BRANCHES_BEFORE" ] \
      || fail "gh outage still pushed a branch"
    GH_STUB_DOWN=1 CRONTAB_FIXTURE="$PWD/live-clean" "$check" > run10b.log 2>&1 \
      || fail "gh outage with NO drift must stay green"
    echo "ok 10: drift + no gh → loud; no drift + no gh → green"

    # ===================================================================
    # 11. Anchor missing from the config — loud, nothing pushed.
    # ===================================================================
    mkfixture "$PWD/fixnoanchor" 0
    NOANCHOR_ORIGIN="$PWD/fixnoanchor/origin"
    if CRONDRIFT_BARE_REPO="$PWD/fixnoanchor/bare" \
       CRONTAB_FIXTURE="$PWD/live-drift" "$check" > run11.log 2>&1; then
      fail "missing anchor exited 0 — the config would silently never gain the entry"
    fi
    grep -q "anchor" run11.log \
      || fail "missing anchor did not name the anchor"
    [ -z "$(git -C "$NOANCHOR_ORIGIN" for-each-ref --format='%(refname:short)' \
              refs/heads | grep -v '^main$' || true)" ] \
      || fail "missing-anchor run pushed a branch anyway"
    echo "ok 11: missing anchor → loud failure, nothing pushed"

    # ===================================================================
    # 12. PR merged, branch still on origin, host not yet rebuilt.
    #     The entry is in origin/main but still absent from the LIVE
    #     generation's declaration, so drift is still detected. Must not
    #     open a second PR for it.
    # ===================================================================
    PR_BEFORE=$(pr_creates)
    BRANCHES_BEFORE=$(remote_branches | wc -l)
    DRIFT_KEY=$(printf '%s' "$BRANCH" | tr '/' '_')
    : > "$PR_STATE_DIR/$DRIFT_KEY.merged"
    CRONTAB_FIXTURE="$PWD/live-drift" "$check" > run12.log 2>&1 \
      || fail "merged-PR run exited non-zero"
    grep -q "is merged" run12.log \
      || fail "merged-PR run did not recognise the merge"
    [ "$(pr_creates)" = "$PR_BEFORE" ] \
      || fail "merged-PR run opened a duplicate PR"
    rm -f "$PR_STATE_DIR/$DRIFT_KEY.merged"
    echo "ok 12: merged PR + stale generation → no duplicate PR"

    # ===================================================================
    # 13. PR closed WITHOUT merging, entries still live.
    #     Re-filing would nag; staying silent is how the four-month
    #     outage happened. Notify once, stay green, open nothing.
    # ===================================================================
    : > notify.log
    : > "$PR_STATE_DIR/$DRIFT_KEY.closed"
    CRONTAB_FIXTURE="$PWD/live-drift" "$check" > run13.log 2>&1 \
      || fail "closed-PR run exited non-zero"
    grep -q "closed without merging" run13.log \
      || fail "closed-PR run did not report the rejection"
    grep -q "critical" notify.log \
      || fail "rejected-but-still-live drift raised no critical notification"
    [ "$(pr_creates)" = "$PR_BEFORE" ] \
      || fail "closed-PR run re-filed the drift"
    [ "$(remote_branches | wc -l)" = "$BRANCHES_BEFORE" ] \
      || fail "closed-PR run pushed a branch"
    rm -f "$PR_STATE_DIR/$DRIFT_KEY.closed"
    echo "ok 13: rejected drift still live → notified once, never re-filed"

    # ===================================================================
    # 14. Entries already declared upstream, branch gone (GitHub's
    #     delete-branch-on-merge). ls-remote misses, so the run reaches
    #     the checkout — and must notice the entries are already there
    #     rather than opening a PR that duplicates them.
    # ===================================================================
    mkfixture "$PWD/fixdeclared" 1 '9 9 * * * /bin/other-job'
    DECL_ORIGIN="$PWD/fixdeclared/origin"
    PR_BEFORE=$(pr_creates)
    CRONDRIFT_BARE_REPO="$PWD/fixdeclared/bare" \
      CRONTAB_FIXTURE="$PWD/live-drift2" "$check" > run14.log 2>&1 \
      || fail "already-declared run exited non-zero"
    grep -q "already declared" run14.log \
      || fail "already-declared run did not recognise the upstream entry"
    [ "$(pr_creates)" = "$PR_BEFORE" ] \
      || fail "already-declared run opened a duplicate PR"
    [ -z "$(git -C "$DECL_ORIGIN" for-each-ref --format='%(refname:short)' \
              refs/heads | grep -v '^main$' || true)" ] \
      || fail "already-declared run pushed a branch"
    echo "ok 14: entry already in origin/main → no duplicate PR"

    # ===================================================================
    # 15. Runs correctly under a UTF-8 locale.
    #     Regression guard, found by the feature-VM smoke on 2026-08-08:
    #     the entry sets were sorted under C collation but `comm` ran
    #     under the ambient locale, and a systemd user session carries a
    #     UTF-8 one. UTF-8 collation ignores punctuation at the primary
    #     level, so `*/30 …` / `0 5 …` / `11 16 …` sort in a different
    #     order than under C — `comm` then bailed with "file 2 is not in
    #     sorted order" and the unit went red on a crontab with no drift
    #     at all. The script must pin its own collation.
    # ===================================================================
    export LOCALE_ARCHIVE="$localeArchive"
    # Prove the locale is really in effect, or this case is vacuous:
    # under UTF-8 collation the digit-leading line sorts first, under C
    # the asterisk (0x2A) does.
    first=$(printf '%s\n' '*/30 6-22 * * * /bin/a' '0 5 * * * /bin/b' \
      | LC_ALL=en_US.UTF-8 sort | head -1)
    case "$first" in
      "0 5 "*) : ;;
      *) fail "en_US.UTF-8 collation is not active in the sandbox — case 12 would be vacuous (got '$first')" ;;
    esac
    # The live side must be EMPTY. GNU comm only reports disorder once
    # it walks past an unpairable stretch; with a partly-pairable pair
    # of files it can finish before reaching the offending comparison
    # (an earlier version of this case passed vacuously for exactly
    # that reason). Empty-live is also precisely the VM repro: `crontab
    # -r`, declaration intact, drift entirely in the inverse direction —
    # and that path exits 0 without needing git or gh.
    {
      echo 'CRON_TZ=Europe/Stockholm'
      echo '*/30 6-22 * * * /bin/a'
      echo '0 5 * * * /bin/b'
      echo '11 16 * * * /bin/c'
      echo "# $ANCHOR"
    } > "$PWD/declared-utf8"
    LC_ALL=en_US.UTF-8 CRONDRIFT_DECLARED_FILE="$PWD/declared-utf8" \
      CRONTAB_FIXTURE="/nonexistent" "$check" > run12.log 2>&1 \
      || fail "run under en_US.UTF-8 exited non-zero"
    if grep -qi "not in sorted order" run12.log; then
      fail "collation mismatch between sort and comm under a UTF-8 locale"
    fi
    grep -q "missing-live: 11 16 \* \* \* /bin/c" run12.log \
      || fail "UTF-8-locale run did not compute the drift set correctly"
    echo "ok 15: pinned collation → drift computed correctly under a UTF-8 locale"

    # ===================================================================
    # 16. `main` on origin must never have moved. The declaration is the
    #     source of truth; this tool proposes, it does not decide.
    # ===================================================================
    MAIN_AFTER=$(git -C "$ORIGIN" rev-parse refs/heads/main)
    [ "$MAIN_BEFORE" = "$MAIN_AFTER" ] \
      || fail "origin/main moved ($MAIN_BEFORE -> $MAIN_AFTER)"
    if grep -q -- "--force" "$GH_LOG"; then fail "gh was called with --force"; fi
    echo "ok 16: origin/main untouched across every run"

    echo "ok: PR-gated writer files exactly one PR per distinct drift, escapes Nix metacharacters, goes loud on every path it cannot complete, and never writes main"
    touch $out
  ''
