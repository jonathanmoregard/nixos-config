# signal-expiry: runtime-invocation harness for overlays/signal-expiry.nix.
#
# Drives the EXACT deployed `check-signal-expiry` bytes (via its `--asar`
# form) against crafted app.asar fixtures. The flake-ref form can't run in
# a build sandbox — it shells out to `nix build` — but every line of the
# parsing and classification logic is shared, and that parsing is the part
# that can silently go wrong.
#
# What the 2026-08-08 incident taught, and what each case below pins:
#
#   - Signal embeds SEVERAL `buildExpiration` occurrences; the source
#     default is 0. Taking the first match yields a 1970 expiry, which
#     would make the update workflow open a bump PR every single week
#     forever. The real deadline is the MAX.
#   - An already-expired build must still MEASURE (exit 0, negative
#     days_left). That is precisely the state the tool exists to detect;
#     if it errored out there, the workflow would go silent at the exact
#     moment it matters.
#   - A genuinely unreadable expiry must FAIL LOUD (exit 1), never be
#     silently reported as 0 days — a false "expiring now" would trigger
#     an unnecessary whole-nixpkgs bump PR.
#
# Run: nix build .#checks.x86_64-linux.signal-expiry -L
{ pkgs, checkScript }:

pkgs.runCommand "signal-expiry-harness"
  {
    nativeBuildInputs = with pkgs; [ bash coreutils gnugrep ];
  } ''
    export PATH="${checkScript}/bin:$PATH"
    mkdir -p fixtures state

    now=$(date +%s)
    # +12h of slack on top of the 45 whole days: days_left is computed
    # from `date +%s` INSIDE the script, seconds-to-minutes after this
    # line, and integer division would otherwise report 44 the moment
    # any time at all elapses. The slack is far below one day, so the
    # asserted day count is still exactly 45.
    future_ms=$(( (now + 45 * 86400 + 43200) * 1000 ))   # 45 days of runway
    past_ms=$((   (now - 10 * 86400) * 1000 ))           # expired 10 days ago

    # Fixture shaped like the real asar: binary-ish blob with the config
    # JSON embedded, plus the decoy zero-defaults that appear in Signal's
    # own bundle alongside the real value. The decoys are written in the
    # SAME minified form the probe greps for (`"buildExpiration":0`) and
    # straddle the real value — before AND after. Before-only would let a
    # positional "take the last match" implementation pass without ever
    # comparing magnitudes; straddling means only a real max survives.
    mk_asar() { # <file> <expiration-json-fragment>
      {
        printf 'binary\0blob\0padding'
        printf '{"buildExpiration":0,"other":1}'
        printf 'someCode({"buildExpiration":0})'
        printf '%s' "$2"
        printf 'moreCode({"buildExpiration":0})'
        printf '\0trailing\0bytes'
      } > "$1"
    }

    mk_asar fixtures/normal.asar "{\"buildCreation\":1,\"buildExpiration\":$future_ms}"
    mk_asar fixtures/expired.asar "{\"buildExpiration\":$past_ms}"
    # Expired three hours ago — the truncate-toward-zero trap.
    mk_asar fixtures/just-expired.asar \
      "{\"buildExpiration\":$(( (now - 3 * 3600) * 1000 ))}"

    # Only the zero decoys — no real deadline anywhere.
    {
      printf '{"buildExpiration":0}'
      printf '{"buildExpiration":0}'
    } > fixtures/zero-only.asar

    printf 'no expiry field at all, just noise' > fixtures/absent.asar

    run() { # <case> <args...> ; captures stdout/stderr + rc
      local case="$1"; shift
      rc=0
      check-signal-expiry "$@" > "state/$case.out" 2> "state/$case.err" || rc=$?
      echo "$rc"
    }

    # --- case: healthy build → exit 0, max-selected expiry, ~45 days ---
    rc=$(run normal --asar fixtures/normal.asar)
    [ "$rc" -eq 0 ] || {
      cat state/normal.err
      echo "FAIL(normal): expected exit 0, got $rc"; exit 1; }
    days=$(grep '^days_left=' state/normal.out | cut -d= -f2)
    [ "$days" -eq 45 ] || {
      cat state/normal.out state/normal.err
      echo "FAIL(normal): expected days_left=45, got '$days' — the 0-valued decoys almost certainly won the max"; exit 1; }
    got_epoch=$(grep '^expiry_epoch=' state/normal.out | cut -d= -f2)
    [ "$got_epoch" -eq $(( future_ms / 1000 )) ] || {
      echo "FAIL(normal): expiry_epoch $got_epoch != $(( future_ms / 1000 ))"; exit 1; }

    # --- case: ALREADY EXPIRED → still exit 0, negative days_left ---
    # The 2026-08-08 state. Must measure, not error.
    rc=$(run expired --asar fixtures/expired.asar)
    [ "$rc" -eq 0 ] || {
      cat state/expired.err
      echo "FAIL(expired): an expired build must still measure (exit 0), got $rc — the workflow would go blind exactly when it matters"; exit 1; }
    days=$(grep '^days_left=' state/expired.out | cut -d= -f2)
    [ "$days" -lt 0 ] || {
      cat state/expired.out
      echo "FAIL(expired): expected negative days_left, got '$days'"; exit 1; }

    # --- case: expired only THREE HOURS ago → -1, never 0 ---
    # Bash divides toward zero, so a naive `secs_left / 86400` reports
    # "0 days left" for a client that is already refusing to connect —
    # indistinguishable from "expires later today".
    rc=$(run just-expired --asar fixtures/just-expired.asar)
    [ "$rc" -eq 0 ] || {
      cat state/just-expired.err
      echo "FAIL(just-expired): expected exit 0, got $rc"; exit 1; }
    days=$(grep '^days_left=' state/just-expired.out | cut -d= -f2)
    [ "$days" -eq -1 ] || {
      cat state/just-expired.out state/just-expired.err
      echo "FAIL(just-expired): expected days_left=-1, got '$days' — truncation toward zero is reporting an expired build as 0 days"; exit 1; }

    # --- case: only zero decoys → exit 1, no bogus days_left ---
    rc=$(run zero-only --asar fixtures/zero-only.asar)
    [ "$rc" -eq 1 ] || {
      cat state/zero-only.out state/zero-only.err
      echo "FAIL(zero-only): unreadable expiry must fail loud (exit 1), got $rc"; exit 1; }
    grep -q 'could not read buildExpiration' state/zero-only.err || {
      cat state/zero-only.err
      echo "FAIL(zero-only): missing diagnostic on stderr"; exit 1; }
    [ ! -s state/zero-only.out ] || {
      cat state/zero-only.out
      echo "FAIL(zero-only): emitted parseable output despite failing — CI would consume a bogus days_left"; exit 1; }

    # --- case: no expiry field at all → exit 1, WITH a diagnostic ---
    # Distinct from zero-only: there the grep matches and yields 0, here
    # it matches nothing. Under `set -o pipefail` an unguarded no-match
    # pipeline would abort the script before it could say why, leaving
    # the workflow with a bare rc=1 and no log line.
    rc=$(run absent --asar fixtures/absent.asar)
    [ "$rc" -eq 1 ] || {
      echo "FAIL(absent): expected exit 1, got $rc"; exit 1; }
    grep -q 'could not read buildExpiration' state/absent.err || {
      cat state/absent.err
      echo "FAIL(absent): exited 1 without saying why — pipefail almost certainly aborted the script early"; exit 1; }
    [ ! -s state/absent.out ] || {
      cat state/absent.out
      echo "FAIL(absent): emitted parseable output despite failing"; exit 1; }

    # --- case: nonexistent asar → exit 1 with the path named ---
    rc=$(run missing --asar fixtures/does-not-exist.asar)
    [ "$rc" -eq 1 ] || {
      echo "FAIL(missing): expected exit 1, got $rc"; exit 1; }
    grep -q 'no app.asar at' state/missing.err || {
      cat state/missing.err
      echo "FAIL(missing): missing diagnostic naming the path"; exit 1; }

    # --- case: --asar with no argument → exit 1, not a silent flake-ref build ---
    rc=$(run noarg --asar)
    [ "$rc" -eq 1 ] || {
      echo "FAIL(noarg): bare --asar must be rejected, got $rc"; exit 1; }

    echo "ok: max-selected expiry, expired builds still measured (floored negative), unreadable expiry fails loud"
    touch $out
  ''
