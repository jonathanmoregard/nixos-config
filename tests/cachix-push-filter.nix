# cachix-push-filter: runtime-invocation harness for the cachix
# post-build-hook (modules/nixos/cachix-push-hook.nix — the exact logic
# template cachix-push.nix instantiates for production, here
# instantiated with PATH-resolvable binary names and a 2s timeout so
# stubs and the hang case run in seconds).
#
# Simulates the 2026-07-07 incident class: the ~621 MiB
# *-microvm-store-disk.erofs (and any >256 MiB path) can never finish
# uploading inside the push timeout on a ~2.4 Mbit uplink, so every
# referencing derivation re-attempts the same blob — 30-50 min burned
# per VM-gate run, and once a livelocked uplink. The hook MUST:
#   - skip erofs-named and over-budget paths (logged, one line each)
#   - still push the small paths in a single cachix invocation
#   - preserve the timeout-vs-failure rc discrimination (PR #67 class)
#   - NEVER exit non-zero (post-build-hook failure fails builds)
#
# The production writeShellScript (exact deployed bytes, absolute
# /nix/store binary paths, agenix token path) is additionally smoked on
# the paths reachable without a token: empty OUT_PATHS and unreadable
# token must exit 0 silently, and the filter markers must be present in
# the deployed text.
#
# Run: nix build .#checks.x86_64-linux.cachix-push-filter -L
{ pkgs, prodHook }:

let
  script = import ../modules/nixos/cachix-push-hook.nix {
    cacheName = "testcache";
    pushTimeoutSeconds = 2;
    maxPathBytes = 256 * 1024 * 1024;
    # Shell-expanded at runtime by the script itself — each case below
    # exports TOKEN_FILE to point at a readable or missing token.
    tokenFile = "$TOKEN_FILE";
    # Bare names resolve via PATH: cachix hits the recording stub,
    # timeout/du/cut hit real coreutils (the 2s timeout genuinely
    # KILLs the hanging stub).
    cachixBin = "cachix";
    timeoutBin = "timeout";
    duBin = "du";
    cutBin = "cut";
  };
in
pkgs.runCommand "cachix-push-filter-harness"
  {
    inherit script;
    inherit prodHook;
    passAsFile = [ "script" ];
    nativeBuildInputs = with pkgs; [ bash coreutils gnugrep ];
  } ''
    mkdir -p bin state fake-store
    export STATE="$PWD/state"

    # cachix stub: record full argv per invocation; behavior selected
    # by CACHIX_MODE (ok = succeed, fail = exit 3, hang = block until
    # timeout KILLs us).
    cat > bin/cachix <<'STUB'
    #!/bin/sh
    echo "$@" >> "$STATE/cachix.log"
    case "''${CACHIX_MODE:-ok}" in
      fail) exit 3 ;;
      hang) exec sleep 60 ;;
    esac
    exit 0
    STUB
    chmod +x bin/cachix
    export PATH="$PWD/bin:$PATH"

    # Fixtures. big.bin is sparse; du -sb (apparent size) sees 300 MiB.
    SMALL1="$PWD/fake-store/aaaa-small-package"
    SMALL2="$PWD/fake-store/bbbb-small-dir"
    BIG="$PWD/fake-store/cccc-big-blob"
    EROFS="$PWD/fake-store/dddd-microvm-store-disk.erofs"
    MISSING="$PWD/fake-store/eeee-never-materialized"
    echo hello > "$SMALL1"
    mkdir -p "$SMALL2" && echo world > "$SMALL2/file"
    truncate -s 300M "$BIG"
    echo tiny-but-banned-by-name > "$EROFS"
    echo dummy-token > token
    export TOKEN_FILE="$PWD/token"

    run_hook() { # <case-name> <OUT_PATHS value>; CACHIX_MODE/TOKEN_FILE from env
      : > "$STATE/cachix.log"
      rc=0
      OUT_PATHS="$2" bash "$scriptPath" > "$STATE/$1.out" 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        cat "$STATE/$1.out"
        echo "FAIL($1): hook exited $rc — a post-build-hook failure FAILS the build; must always exit 0"
        exit 1
      fi
    }

    # --- case: empty OUT_PATHS → exit 0, no push attempted ---
    run_hook empty ""
    [ ! -s "$STATE/cachix.log" ] || {
      echo "FAIL(empty): cachix invoked with no OUT_PATHS"; exit 1; }

    # --- case: unreadable token → exit 0, no push attempted ---
    TOKEN_FILE="$PWD/no-such-token" run_hook no-token "$SMALL1"
    [ ! -s "$STATE/cachix.log" ] || {
      echo "FAIL(no-token): cachix invoked without a readable token"; exit 1; }

    # --- case: mixed batch → erofs + over-budget skipped (logged), small paths pushed in ONE invocation ---
    run_hook mixed "$SMALL1 $EROFS $BIG $SMALL2"
    grep -qF "cachix-push: skipping $EROFS (" "$STATE/mixed.out" || {
      cat "$STATE/mixed.out"
      echo "FAIL(mixed): erofs-named path not skipped/logged"; exit 1; }
    grep -qF "cachix-push: skipping $BIG (314572800 bytes): exceeds push budget" "$STATE/mixed.out" || {
      cat "$STATE/mixed.out"
      echo "FAIL(mixed): >256MiB path not skipped/logged with its size"; exit 1; }
    [ "$(grep -c "exceeds push budget" "$STATE/mixed.out")" -eq 2 ] || {
      cat "$STATE/mixed.out"
      echo "FAIL(mixed): expected exactly 2 skip lines"; exit 1; }
    grep -qxF "push testcache $SMALL1 $SMALL2" "$STATE/cachix.log" || {
      echo "--- cachix.log ---"; cat "$STATE/cachix.log"
      echo "FAIL(mixed): small paths not pushed as a single filtered batch"; exit 1; }
    [ "$(wc -l < "$STATE/cachix.log")" -eq 1 ] || {
      cat "$STATE/cachix.log"
      echo "FAIL(mixed): expected exactly one cachix invocation"; exit 1; }

    # --- case: everything filtered → no cachix invocation at all ---
    run_hook all-skipped "$EROFS $BIG"
    [ ! -s "$STATE/cachix.log" ] || {
      cat "$STATE/cachix.log"
      echo "FAIL(all-skipped): cachix invoked though every path was over budget"; exit 1; }

    # --- case: nonexistent path → defensively treated as size 0, still pushed, no crash ---
    run_hook missing-path "$MISSING"
    grep -qxF "push testcache $MISSING" "$STATE/cachix.log" || {
      cat "$STATE/missing-path.out"; cat "$STATE/cachix.log"
      echo "FAIL(missing-path): unmeasurable path crashed the hook or was dropped"; exit 1; }

    # --- case: cachix exits non-zero → rc preserved into the failure log line, hook still exits 0 ---
    CACHIX_MODE=fail run_hook push-fails "$SMALL1"
    grep -qF "cachix push failed with exit 3" "$STATE/push-fails.out" || {
      cat "$STATE/push-fails.out"
      echo "FAIL(push-fails): non-zero cachix rc not surfaced (PR #67 rc-capture regression)"; exit 1; }

    # --- case: cachix hangs → real timeout KILLs at 2s, timeout branch logged, hook still exits 0 ---
    start=$(date +%s)
    CACHIX_MODE=hang run_hook push-hangs "$SMALL1"
    elapsed=$(( $(date +%s) - start ))
    grep -qF "timed out after 2s pushing" "$STATE/push-hangs.out" || {
      cat "$STATE/push-hangs.out"
      echo "FAIL(push-hangs): timeout (rc 137/124) not discriminated from ordinary failure"; exit 1; }
    [ "$elapsed" -le 15 ] || {
      echo "FAIL(push-hangs): hook ran ''${elapsed}s — timeout did not cut the hang"; exit 1; }

    # --- production script (exact deployed bytes): token-less paths + filter markers ---
    rc=0; prod_out=$(OUT_PATHS="" "$prodHook" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && [ -z "$prod_out" ] || {
      echo "$prod_out"
      echo "FAIL(prod-empty): deployed hook must exit 0 silently on empty OUT_PATHS (got rc=$rc)"; exit 1; }
    rc=0; prod_out=$(OUT_PATHS="$SMALL1" "$prodHook" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && [ -z "$prod_out" ] || {
      echo "$prod_out"
      echo "FAIL(prod-no-token): deployed hook must exit 0 silently when the agenix token is absent (got rc=$rc)"; exit 1; }
    grep -qF -- "-microvm-store-disk.erofs" "$prodHook" && grep -qF "exceeds push budget" "$prodHook" || {
      echo "FAIL(prod-filter-markers): deployed hook text lacks the size/erofs filter"; exit 1; }

    echo "ok: filter skips erofs+oversize (logged), pushes the rest, rc discrimination intact, always exit 0"
    touch $out
  ''
